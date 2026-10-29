import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../logger/playback_trace.dart';
import '../models/addon_stream_source.dart';

class DirectHlsService {
  final Dio _dio;
  DirectHlsService([Dio? dio]) : _dio = dio ?? Dio();

  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  Future<List<AddonStreamSource>> resolveDirectStreams({
    required String? imdbId,
    required String type,
    int? season,
    int? episode,
    String? title,
    CancelToken? cancelToken,
  }) async {
    if (imdbId == null || imdbId.isEmpty) return const [];

    final streams = <AddonStreamSource>[];
    final seen = <String>{};
    final trace = PlaybackTrace('direct-hls');

    try {
      // Step 1: Resolve TMDB ID from Cinemeta meta if needed
      int? tmdbId;
      try {
        final metaResp = await _dio.get<dynamic>(
          'https://v3-cinemeta.strem.io/meta/$type/$imdbId.json',
          options: Options(
            receiveTimeout: const Duration(seconds: 8),
            sendTimeout: const Duration(seconds: 8),
            headers: const {'Accept': 'application/json'},
          ),
          cancelToken: cancelToken,
        );
        final data = metaResp.data;
        if (data is Map && data['meta'] is Map) {
          final meta = data['meta'] as Map;
          final rawId = meta['moviedb_id'] ?? meta['tmdb_id'];
          if (rawId != null) {
            tmdbId = int.tryParse(rawId.toString());
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[DirectHlsService] cinemeta meta error: $e');
        trace.warn('cinemeta', 'failed ${e.runtimeType}');
      }

      trace.lap('cinemeta', tmdbId == null ? 'no tmdb id' : 'tmdb=$tmdbId');
      if (tmdbId == null) return streams;

      // Step 2: Query VidApi (VAPlayer)
      final vidapiFuture = () async {
        try {
          final isMovie = type == 'movie';
          final s = season ?? 1;
          final ep = episode ?? 1;
          final tvQuery = isMovie ? '' : '&season=$s&episode=$ep';
          final apiUrl =
              'https://streamdata.vaplayer.ru/api.php?tmdb=$tmdbId&type=${isMovie ? 'movie' : 'tv'}$tvQuery';

          final res = await _dio.get<dynamic>(
            apiUrl,
            options: Options(
              receiveTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 10),
              headers: const {
                'User-Agent': _defaultUserAgent,
                'Referer': 'https://brightpathsignals.com/',
                'Origin': 'https://brightpathsignals.com',
                'Accept': 'application/json, text/plain, */*',
              },
            ),
            cancelToken: cancelToken,
          );

          final data = res.data;
          var added = 0;
          var offered = 0;
          if (data is Map &&
              data['status_code']?.toString() == '200' &&
              data['data'] is Map) {
            final streamUrls = (data['data'] as Map)['stream_urls'];
            if (streamUrls is List) {
              final urls = [
                for (final raw in streamUrls) raw?.toString() ?? '',
              ].where((u) => u.isNotEmpty).toList(growable: false);
              offered = urls.length;
              // The API's "servers" are routinely one encode behind several
              // tokens: the URLs differ, the playlist they point at does not.
              // Rows are keyed on the master's variant lines - the only cheap
              // place the shared encode shows - so failover cannot spend a
              // watchdog on the same dead stream three times.
              final keys = urls.length > 1
                  ? await Future.wait(urls.map(_encodeKey))
                  : List<String?>.filled(urls.length, null);
              final encodes = <String>{};
              for (var i = 0; i < urls.length; i++) {
                final key = keys[i] ?? urls[i];
                if (!encodes.add(key)) continue;
                if (!seen.add(urls[i])) continue;
                added++;
                streams.add(AddonStreamSource(
                  addonId: 'cinepro-direct-hls',
                  addonName: 'Direct HLS',
                  name: '⚡ [HLS] VidApi Server ${i + 1} 1080p',
                  title: '⚡ Instant Direct Stream',
                  url: urls[i],
                  proxyHeaders: const {
                    'User-Agent': _defaultUserAgent,
                  },
                ));
              }
            }
          }
          trace.lap('vidapi', 'links=$added of $offered');
        } catch (e) {
          if (kDebugMode) debugPrint('[DirectHlsService] vidapi error: $e');
          trace.warn('vidapi', 'failed ${e.runtimeType}');
        }
      }();

      // Step 3: Query VixSrc
      final vixsrcFuture = () async {
        var added = 0;
        try {
          final isMovie = type == 'movie';
          final s = season ?? 1;
          final ep = episode ?? 1;
          final apiPath = isMovie ? '/api/movie/$tmdbId' : '/api/tv/$tmdbId/$s/$ep';

          final res = await _dio.get<dynamic>(
            'https://vixsrc.to$apiPath',
            options: Options(
              receiveTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 10),
              headers: const {
                'User-Agent': _defaultUserAgent,
                'Referer': 'https://vixsrc.to',
                'Origin': 'https://vixsrc.to',
                'Accept': 'application/json, text/javascript, */*',
              },
            ),
            cancelToken: cancelToken,
          );

          final data = res.data;
          if (data is Map && data['src'] != null) {
            final embedSrc = data['src'].toString();
            final embedRes = await _dio.get<String>(
              'https://vixsrc.to$embedSrc',
              options: Options(
                receiveTimeout: const Duration(seconds: 10),
                sendTimeout: const Duration(seconds: 10),
                headers: const {
                  'User-Agent': _defaultUserAgent,
                  'Referer': 'https://vixsrc.to',
                },
              ),
              cancelToken: cancelToken,
            );

            final embedHtml = embedRes.data ?? '';
            final tokenMatch = RegExp(r'''token["']\s*:\s*["']([^"']+)''').firstMatch(embedHtml);
            final expiresMatch = RegExp(r'''expires["']\s*:\s*["']([^"']+)''').firstMatch(embedHtml);
            final playlistMatch = RegExp(r'''url\s*:\s*["']([^"']+)''').firstMatch(embedHtml);

            if (tokenMatch != null && expiresMatch != null && playlistMatch != null) {
              // The embed writes the playlist as a path as often as a whole
              // URL, and a token with "+" or "=" appended raw is read as a
              // space or a second separator - both arrive as a 403 that looks
              // like a dead link.
              final playlistUri = Uri.parse('https://vixsrc.to')
                  .resolve(playlistMatch.group(1)!);
              final masterUrl = playlistUri
                  .replace(queryParameters: <String, String>{
                    ...playlistUri.queryParameters,
                    'token': tokenMatch.group(1)!,
                    'expires': expiresMatch.group(1)!,
                    'h': '1',
                  })
                  .toString();

              if (seen.add(masterUrl)) {
                added = 1;
                streams.add(AddonStreamSource(
                  addonId: 'cinepro-direct-hls',
                  addonName: 'Direct HLS',
                  name: '⚡ [HLS] VixSrc Multi-Audio 1080p',
                  title: '⚡ Instant Direct Stream (Multi-Audio)',
                  url: masterUrl,
                  proxyHeaders: {
                    'User-Agent': _defaultUserAgent,
                    'Referer': 'https://vixsrc.to$embedSrc',
                    'Origin': 'https://vixsrc.to',
                  },
                ));
              }
            }
          }
          trace.lap('vixsrc', 'links=$added');
        } catch (e) {
          if (kDebugMode) debugPrint('[DirectHlsService] vixsrc error: $e');
          trace.warn('vixsrc', 'failed ${e.runtimeType}');
        }
      }();

      await Future.wait([vidapiFuture, vixsrcFuture]);
    } catch (e) {
      if (kDebugMode) debugPrint('[DirectHlsService] overall error: $e');
      trace.warn('done', 'failed ${e.runtimeType}');
    }

    trace.lap('done', 'links=${streams.length}');
    return streams;
  }

  /// What a VidApi link plays, as far as one small request can tell.
  ///
  /// The master's `#EXT-X-STREAM-INF` lines carry the bandwidth and
  /// resolution of every rendition, and two tokens handed out for the same
  /// encode answer with the same lines. Null when the master cannot be read;
  /// the caller then keeps the link on its URL alone.
  Future<String?> _encodeKey(String url) async {
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(
          receiveTimeout: const Duration(seconds: 6),
          sendTimeout: const Duration(seconds: 6),
          responseType: ResponseType.plain,
          headers: const {
            'User-Agent': _defaultUserAgent,
            'Referer': 'https://brightpathsignals.com/',
          },
        ),
      );
      final variants = <String>[
        for (final line in (res.data ?? '').split('\n'))
          if (line.trim().toUpperCase().startsWith('#EXT-X-STREAM-INF:'))
            line.trim(),
      ]..sort();
      if (variants.isEmpty) return null;
      return variants.join('|');
    } catch (_) {
      return null;
    }
  }
}
