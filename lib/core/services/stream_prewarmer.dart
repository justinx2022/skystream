import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../domain/entity/multimedia_item.dart';
import '../../features/player/domain/stream_resolver.dart';
import 'local_proxy_service.dart';

/// Speculative Background Pre-Warmer (Netflix-Style Warm Start).
///
/// Pre-resolves candidate streams, races healthy mirrors with 0-byte preflight,
/// and primes Chunk 0 into memory before the user presses "Play" or while
/// watching the preceding episode. Eliminates cold-start latency.
class StreamPrewarmer {
  StreamPrewarmer._();

  static final StreamPrewarmer instance = StreamPrewarmer._();

  final Map<String, ResolvedPlayback> _prewarmedStreams = {};
  final Set<String> _inFlight = {};

  /// Whether candidate streams have already been resolved and verified for [targetUrl].
  bool hasPrewarmed(String targetUrl) => _prewarmedStreams.containsKey(targetUrl);

  /// Retrieves the pre-warmed playback session if available.
  ResolvedPlayback? getPrewarmed(String targetUrl) => _prewarmedStreams[targetUrl];

  /// Silently pre-resolves [targetUrl] and primes initial media chunks in background.
  Future<void> prewarm({
    required MultimediaItem item,
    required String targetUrl,
    required ProviderReader read,
    Episode? episode,
  }) async {
    if (targetUrl.isEmpty || _inFlight.contains(targetUrl) || _prewarmedStreams.containsKey(targetUrl)) {
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
        _prewarmedStreams[targetUrl] = resolved;

        if (kDebugMode) {
          debugPrint(
            '[PREWARMER] Successfully prewarmed "$targetUrl" with ${resolved.streams.length} candidate mirrors (selected: ${resolved.selected.providerName})',
          );
        }

        // Prime the winning candidate through the local proxy
        unawaited(_primeChunk0(resolved.selected));
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PREWARMER] Error pre-warming $targetUrl: $e');
      }
    } finally {
      _inFlight.remove(targetUrl);
    }
  }

  /// Primes the first media chunk through the proxy into memory to guarantee instant playback.
  Future<void> _primeChunk0(StreamResult stream) async {
    try {
      final headers = playbackHeaders(stream);
      await LocalProxyService.instance.startServer();
      final proxyUrl = LocalProxyService.instance.getProxyUrl(
        stream.url,
        headers: headers,
      );

      final client = HttpClient()
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
      client.close();
    } catch (_) {
      // Ignore background priming errors; main player will fallback cleanly
    }
  }

  /// Clears cached pre-warmed streams when memory is reclaimed.
  void clear() {
    _prewarmedStreams.clear();
    _inFlight.clear();
  }
}
