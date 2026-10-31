import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../network/doh_resolver.dart';
import '../network/http_defaults.dart';
import 'local_proxy_service.dart';

/// In-memory cached media segment prefetched from upstream CDN.
class CachedSegment {
  final Uint8List bytes;
  final Map<String, String> headers;
  final int statusCode;

  CachedSegment({
    required this.bytes,
    required this.headers,
    this.statusCode = HttpStatus.ok,
  });
}

/// Multi-Connection HLS Segment Prefetcher & Speed Booster.
///
/// Accelerates HLS and VOD streams to Debrid-like saturation by prefetching
/// upcoming segments in parallel using a pool of persistent HTTP connections.
/// When the video player requests segment N, segments N+1 through N+4 are
/// fetched ahead into an in-memory sliding cache, resulting in 0ms local delivery
/// and eliminating buffering or buffer meter drops.
class SegmentPrefetchManager {
  SegmentPrefetchManager._();

  static final SegmentPrefetchManager _instance = SegmentPrefetchManager._();
  static SegmentPrefetchManager get instance => _instance;

  /// Whether the parallel segment prefetcher is enabled. Controlled via Settings.
  bool enabled = true;

  static const int _maxCachedSegments = 16;
  static const int _prefetchAheadCount = 4;
  static const int _maxSessions = 4;

  final Map<String, _HlsPrefetchSession> _sessions = {};
  final Map<String, CachedSegment> _cache = {};
  final Map<String, Completer<CachedSegment?>> _inFlight = {};
  final List<String> _cacheKeysOrder = [];

  static String _norm(String u) {
    try {
      return Uri.decodeFull(u).split('#')[0];
    } catch (_) {
      return u;
    }
  }

  /// Registers an M3U8 playlist with its ordered segment URLs.
  void registerPlaylist({
    required String playlistUrl,
    required List<String> segments,
    required bool isVod,
    required Map<String, String> stickyHeaders,
    ProxyOptions? options,
    HttpClient Function({required bool autoUncompress})? clientFactory,
  }) {
    if (!enabled || segments.isEmpty) return;

    // Prune oldest session if exceeding limit
    if (_sessions.length >= _maxSessions &&
        !_sessions.containsKey(playlistUrl)) {
      final oldestKey = _sessions.keys.first;
      _sessions.remove(oldestKey);
    }

    final session = _HlsPrefetchSession(
      playlistUrl: playlistUrl,
      segments: List.unmodifiable(segments),
      isVod: isVod,
      stickyHeaders: Map.unmodifiable(stickyHeaders),
      options: options,
      lastActive: DateTime.now(),
    );
    _sessions[playlistUrl] = session;

    if (kDebugMode) {
      debugPrint(
        '[PREFETCH-BOOSTER] Registered playlist with ${segments.length} segments (isVod: $isVod)',
      );
    }

    // Pre-cache segment 0 and 1 immediately so that when the demuxer requests them,
    // they are already warm in memory (0ms local retrieval).
    if (clientFactory != null) {
      final client = clientFactory(autoUncompress: false);
      final count = segments.length > 2 ? 2 : segments.length;
      for (int i = 0; i < count; i++) {
        final segUrl = segments[i];
        final normSeg = _norm(segUrl);
        if (!_cache.containsKey(normSeg) && !_inFlight.containsKey(normSeg)) {
          unawaited(
            _triggerPrefetch(url: segUrl, session: session, client: client),
          );
        }
      }
    }
  }

  /// Whether a segment is already available in the in-memory cache.
  bool hasCached(String segmentUrl) =>
      enabled && _cache.containsKey(_norm(segmentUrl));

  /// Retrieves a prefetched segment from the in-memory cache.
  CachedSegment? getCached(String segmentUrl) =>
      enabled ? _cache[_norm(segmentUrl)] : null;

  /// Whether a segment prefetch task is currently in flight.
  bool isInFlight(String segmentUrl) =>
      enabled && _inFlight.containsKey(_norm(segmentUrl));

  /// Awaits the in-flight prefetch task for [segmentUrl].
  Future<CachedSegment?> awaitInFlight(String segmentUrl) {
    final key = _norm(segmentUrl);
    final completer = _inFlight[key];
    if (completer != null) {
      return completer.future;
    }
    return Future.value(_cache[key]);
  }

  /// Triggered whenever VLC or the player requests a segment.
  ///
  /// Kicks off parallel prefetching for the next [_prefetchAheadCount] segments
  /// in the playlist session.
  void onSegmentRequested(
    String segmentUrl,
    HttpClient Function({required bool autoUncompress}) clientFor,
  ) {
    if (!enabled) return;

    // 1. Locate the playlist session containing this segment
    _HlsPrefetchSession? matchedSession;
    int segmentIndex = -1;
    final normReq = _norm(segmentUrl);

    for (final session in _sessions.values) {
      final idx = session.indexOf(normReq);
      if (idx != -1) {
        matchedSession = session;
        segmentIndex = idx;
        session.lastActive = DateTime.now();
        break;
      }
    }

    if (matchedSession == null || segmentIndex == -1) return;

    // 2. Compute lookahead window
    final lookAhead = matchedSession.isVod ? _prefetchAheadCount : 1;
    final startIndex = segmentIndex + 1;
    final endIndex = (startIndex + lookAhead).clamp(
      0,
      matchedSession.segments.length,
    );

    // 3. Trigger parallel background prefetching
    final client = clientFor(autoUncompress: false);
    for (int i = startIndex; i < endIndex; i++) {
      final nextUrl = matchedSession.segments[i];
      final normNext = _norm(nextUrl);
      if (!_cache.containsKey(normNext) && !_inFlight.containsKey(normNext)) {
        unawaited(
          _triggerPrefetch(
            url: nextUrl,
            session: matchedSession,
            client: client,
          ),
        );
      }
    }

    // 4. Prune old segments behind the playhead (keep 2 segments behind)
    _pruneOlderThan(matchedSession, segmentIndex - 2);
  }

  Future<void> _triggerPrefetch({
    required String url,
    required _HlsPrefetchSession session,
    required HttpClient client,
  }) async {
    final normKey = _norm(url);
    final completer = Completer<CachedSegment?>();
    _inFlight[normKey] = completer;

    try {
      final req = await DohResolver.instance.openUrl(
        client: client,
        method: 'GET',
        uri: Uri.parse(url),
      );

      // 1. Apply sticky headers (e.g. referer, auth)
      session.stickyHeaders.forEach((name, value) {
        final lower = name.toLowerCase();
        if (lower != 'cookie' &&
            lower != 'host' &&
            lower != 'content-length' &&
            lower != 'connection') {
          req.headers.set(name, value);
        }
      });

      // 2. Sanitize and apply default browser User-Agent
      if (req.headers.value(HttpHeaders.userAgentHeader) == null) {
        req.headers.set(HttpHeaders.userAgentHeader, kDefaultBrowserUserAgent);
      }

      // 3. Referer: only one the plugin supplied. Synthesizing `scheme://host/`
      // is what Cloudflare-fronted mirrors answer with 403; the proxy's own
      // header pass deliberately sends none in that case.
      if (req.headers.value(HttpHeaders.refererHeader) == null) {
        final optReferer = session.options?.referer;
        if (optReferer != null) {
          req.headers.set(HttpHeaders.refererHeader, optReferer);
        }
      }

      // 4. Accept-Encoding: identity to avoid CDN Range mismatches
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

      // 5. Cookies
      if (session.options != null && session.options!.keepCookies.isNotEmpty) {
        final cookies = session.stickyHeaders['cookie'] ?? '';
        final filtered = cookies
            .split(';')
            .map((s) => s.trim())
            .where(
              (s) => session.options!.keepCookies.contains(s.split('=')[0]),
            )
            .join('; ');
        if (filtered.isNotEmpty) {
          req.headers.set(HttpHeaders.cookieHeader, filtered);
        }
      }

      final res = await req.close();
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in res) {
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        final headers = <String, String>{};
        res.headers.forEach((name, values) {
          final lower = name.toLowerCase();
          if (lower != 'content-length' &&
              lower != 'content-encoding' &&
              lower != 'transfer-encoding' &&
              lower != 'access-control-allow-origin') {
            headers[name] = values.join(', ');
          }
        });
        headers[HttpHeaders.contentLengthHeader] = bytes.length.toString();

        // A CDN that serves a .ts chunk from an .html path as text/html with
        // nosniff leaves mpv unable to demux it. Only a 2xx body is cached
        // here, so a block page that arrives as a 200 is the one case this
        // cannot tell apart. Header names keep the casing they arrive in, so
        // both the lookup and the removal ignore case.
        String? contentTypeKey;
        for (final String key in headers.keys) {
          if (key.toLowerCase() == 'content-type') {
            contentTypeKey = key;
            break;
          }
        }
        final lowerUrl = url.toLowerCase();
        final segmentLike =
            !lowerUrl.contains('.m3u8') &&
            !lowerUrl.contains('.m3u') &&
            (lowerUrl.contains('.ts') ||
                lowerUrl.contains('.m4s') ||
                lowerUrl.contains('.aac') ||
                lowerUrl.contains('/segment') ||
                lowerUrl.contains('page-') ||
                lowerUrl.contains('.html'));
        final contentType = contentTypeKey == null
            ? ''
            : headers[contentTypeKey]!.toLowerCase();
        if (segmentLike &&
            contentTypeKey != null &&
            (contentType.contains('text/html') ||
                contentType.contains('text/plain'))) {
          headers[contentTypeKey] = 'video/mp2t';
          headers.removeWhere(
            (String key, _) => key.toLowerCase() == 'x-content-type-options',
          );
        }

        final cached = CachedSegment(
          bytes: bytes,
          headers: headers,
          statusCode: res.statusCode,
        );

        _putCache(normKey, cached);
        completer.complete(cached);
        if (kDebugMode) {
          debugPrint(
            '[PREFETCH-BOOSTER] Prefetched segment (${bytes.length} B, HTTP ${res.statusCode}): $url',
          );
        }
      } else {
        completer.complete(null);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PREFETCH-BOOSTER] Error prefetching $url: $e');
      }
      completer.complete(null);
    } finally {
      _inFlight.remove(normKey);
    }
  }

  void _putCache(String key, CachedSegment segment) {
    if (_cache.containsKey(key)) {
      _cacheKeysOrder.remove(key);
    }
    _cache[key] = segment;
    _cacheKeysOrder.add(key);

    while (_cacheKeysOrder.length > _maxCachedSegments) {
      final oldest = _cacheKeysOrder.removeAt(0);
      _cache.remove(oldest);
    }
  }

  void _pruneOlderThan(_HlsPrefetchSession session, int thresholdIndex) {
    if (thresholdIndex <= 0) return;
    for (int i = 0; i < thresholdIndex; i++) {
      if (i < session.segments.length) {
        // The cache is keyed by the normalized URL — pruning with the raw one
        // never matched, so old segments sat there until the cap evicted them.
        final key = _norm(session.segments[i]);
        if (_cache.remove(key) != null) {
          _cacheKeysOrder.remove(key);
        }
      }
    }
  }

  /// Clears all prefetch state and cached segment data.
  void clear() {
    _cache.clear();
    _cacheKeysOrder.clear();
    _inFlight.clear();
    _sessions.clear();
  }
}

class _HlsPrefetchSession {
  final String playlistUrl;
  final List<String> segments;
  final bool isVod;
  final Map<String, String> stickyHeaders;
  final ProxyOptions? options;
  DateTime lastActive;

  _HlsPrefetchSession({
    required this.playlistUrl,
    required this.segments,
    required this.isVod,
    required this.stickyHeaders,
    this.options,
    required this.lastActive,
  });

  /// Normalized segment URL → its index, built once when the playlist is
  /// registered. The player asks about every segment it requests, so decoding
  /// the whole list on each of those calls made a two-hour VOD hitch.
  late final Map<String, int> _index = () {
    final index = <String, int>{};
    for (var i = 0; i < segments.length; i++) {
      index.putIfAbsent(SegmentPrefetchManager._norm(segments[i]), () => i);
    }
    return index;
  }();

  int indexOf(String normalizedUrl) => _index[normalizedUrl] ?? -1;
}
