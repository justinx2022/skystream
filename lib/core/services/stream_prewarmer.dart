import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../domain/entity/multimedia_item.dart';
import '../../features/player/domain/stream_resolver.dart';
import '../../features/player/domain/hls_video_length.dart';
import 'local_proxy_service.dart';

/// Speculative Background Pre-Warmer (Netflix-Style Warm Start).
///
/// Pre-resolves candidate streams, races healthy mirrors with 0-byte preflight,
/// and primes Chunk 0 into memory before the user presses "Play" or while
/// watching the preceding episode. Eliminates cold-start latency.
class StreamPrewarmer {
  StreamPrewarmer._();

  static final StreamPrewarmer instance = StreamPrewarmer._();

  static const Duration _entryTtl = Duration(minutes: 3);
  static const int _maxEntries = 8;

  final Map<String, _PrewarmedEntry> _prewarmedStreams = {};
  final Set<String> _inFlight = {};

  /// Whether candidate streams have already been resolved and verified for [targetUrl].
  bool hasPrewarmed(String targetUrl) => getPrewarmed(targetUrl) != null;

  /// Retrieves the pre-warmed playback session if available.
  ResolvedPlayback? getPrewarmed(String targetUrl) {
    final entry = _prewarmedStreams[targetUrl];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.createdAt) >= _entryTtl) {
      _prewarmedStreams.remove(targetUrl);
      return null;
    }
    return entry.playback;
  }

  /// Silently pre-resolves [targetUrl] and primes initial media chunks in background.
  Future<void> prewarm({
    required MultimediaItem item,
    required String targetUrl,
    required ProviderReader read,
    Episode? episode,
  }) async {
    if (targetUrl.isEmpty ||
        _inFlight.contains(targetUrl) ||
        getPrewarmed(targetUrl) != null) {
      return;
    }

    _inFlight.add(targetUrl);

    try {
      final resolved = await resolvePlayback(
        read: read,
        item: item,
        videoUrl: targetUrl,
      );

      if (resolved.streams.isNotEmpty) {
        _pruneExpired();
        _prewarmedStreams[targetUrl] = _PrewarmedEntry(
          playback: resolved,
          createdAt: DateTime.now(),
        );
        while (_prewarmedStreams.length > _maxEntries) {
          _prewarmedStreams.remove(_prewarmedStreams.keys.first);
        }

        if (kDebugMode) {
          debugPrint(
            '[PREWARMER] Prewarmed ${resolved.streams.length} sources '
            'for ${resolved.selected.providerName}',
          );
        }

        // Only prime an explicitly named HLS playlist. Reading an unknown
        // endpoint through the proxy can download video bytes during browsing
        // and wastes bandwidth before the viewer presses Play.
        final uri = Uri.tryParse(resolved.selected.url);
        if (uri != null && looksLikeHls(uri)) {
          unawaited(_primeChunk0(resolved.selected));
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PREWARMER] Could not prewarm sources (${e.runtimeType})');
      }
    } finally {
      _inFlight.remove(targetUrl);
    }
  }

  void _pruneExpired() {
    final now = DateTime.now();
    _prewarmedStreams.removeWhere(
      (_, entry) => now.difference(entry.createdAt) >= _entryTtl,
    );
  }

  /// Primes the first media chunk through the proxy into memory to guarantee instant playback.
  Future<void> _primeChunk0(StreamResult stream) async {
    HttpClient? client;
    try {
      final headers = playbackHeaders(stream);
      await LocalProxyService.instance.startServer();
      final proxyUrl = LocalProxyService.instance.getProxyUrl(
        stream.url,
        headers: headers,
      );

      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);

      final req = await client.getUrl(Uri.parse(proxyUrl));
      headers.forEach((k, v) {
        final lk = k.toLowerCase();
        if (lk != 'content-length' && lk != 'host' && lk != 'connection') {
          req.headers.set(k, v);
        }
      });
      // 0-byte or 64KB sniffer range to trigger proxy segment cache
      req.headers.set('Range', 'bytes=0-65535');

      final resp = await req.close().timeout(const Duration(seconds: 3));
      // Drain first chunk into proxy memory then close
      await resp.take(1).drain<void>().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Ignore background priming errors; main player will fallback cleanly
    } finally {
      client?.close(force: true);
    }
  }

  /// Clears cached pre-warmed streams when memory is reclaimed.
  void clear() {
    _prewarmedStreams.clear();
    _inFlight.clear();
  }
}

class _PrewarmedEntry {
  const _PrewarmedEntry({required this.playback, required this.createdAt});

  final ResolvedPlayback playback;
  final DateTime createdAt;
}
