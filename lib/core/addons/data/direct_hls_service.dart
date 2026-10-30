import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../logger/playback_trace.dart';
import '../../utils/stream_quality_sorter.dart';
import '../../../features/settings/presentation/player_settings_provider.dart';
import '../models/addon_stream_source.dart';

class DirectHlsService {
  final Dio _dio;
  DirectHlsService([Dio? dio]) : _dio = dio ?? Dio();

  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// Until when the embed host is known to be refusing.
  ///
  /// VixSrc's embed answers `410 Gone` for whole catalogues while its API
  /// still hands out `src` paths, so every sheet paid a round trip to find
  /// that out on the way to playback. A 4xx arms this for a few minutes and
  /// the leg is skipped instead of re-asked; a later 2xx clears it.
  static DateTime? _vixsrcDownUntil;
  static const Duration _vixsrcCooldown = Duration(minutes: 10);

  /// Forgets the cooldown, so a test starts from a clean cache.
  @visibleForTesting
  static void resetVixSrcCooldown() => _vixsrcDownUntil = null;

  Future<List<AddonStreamSource>> resolveDirectStreams({
    required String? imdbId,
    required String type,
    int? season,
    int? episode,
    String? title,
    CancelToken? cancelToken,
    QualityPreference preference = QualityPreference.any,
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
              final read =
                  urls.length > 1 || preference != QualityPreference.any;
              final masters = read
                  ? await Future.wait(urls.map(_readMaster))
                  : List<_Master?>.filled(urls.length, null);
              final encodes = <String>{};
              for (var i = 0; i < urls.length; i++) {
                final master = masters[i];
                final key = master?.key ?? urls[i];
                if (!encodes.add(key)) continue;
                if (!seen.add(urls[i])) continue;
                final rendition = master?.pick(preference);
                final height = rendition?.height ?? master?.largestHeight;
                added++;
                streams.add(AddonStreamSource(
                  addonId: 'cinepro-direct-hls',
                  addonName: 'Direct HLS',
                  name: '⚡ [HLS] VidApi Server ${i + 1}'
                      '${height == null ? '' : ' ${qualityBadgeForHeight(height)}'}',
                  title: '⚡ Instant Direct Stream',
                  url: rendition?.uri ?? urls[i],
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
          final downUntil = _vixsrcDownUntil;
          if (downUntil != null && DateTime.now().isBefore(downUntil)) {
            trace.lap('vixsrc', 'skipped until ${downUntil.toIso8601String()}');
            return;
          }
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
                  name: '⚡ [HLS] VixSrc Multi-Audio',
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
          if (e is DioException &&
              e.type != DioExceptionType.cancel &&
              (e.response?.statusCode ?? 0) >= 400 &&
              (e.response?.statusCode ?? 0) < 500) {
            _vixsrcDownUntil = DateTime.now().add(_vixsrcCooldown);
            trace.warn('vixsrc', 'refused ${e.response?.statusCode}');
          }
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
  Future<_Master?> _readMaster(String url) async {
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
      final lines = (res.data ?? '').split('\n');
      final base = Uri.tryParse(url);
      final variants = <String>[];
      final renditions = <_Rendition>[];
      var hasAlternates = false;
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        final upper = line.toUpperCase();
        if (upper.startsWith('#EXT-X-MEDIA:')) hasAlternates = true;
        if (!upper.startsWith('#EXT-X-STREAM-INF:')) continue;
        variants.add(line);
        final uri = _variantUri(lines, i + 1, base);
        if (uri == null) continue;
        renditions.add(_Rendition(
          uri,
          _heightOf(_attribute(line, 'RESOLUTION')),
          int.tryParse(_attribute(line, 'BANDWIDTH') ?? '') ?? 0,
        ));
      }
      if (variants.isEmpty) return null;
      variants.sort();
      return _Master(
        variants.join('|'),
        renditions,
        hasAlternates: hasAlternates,
      );
    } catch (_) {
      return null;
    }
  }

  String? _variantUri(List<String> lines, int from, Uri? base) {
    for (var i = from; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) return null;
      if (base == null) return line;
      return _absolute(base, line);
    }
    return null;
  }

  /// [ref] made absolute, carrying [base]'s query when it has none: these
  /// masters hold the token in the query and write the variants as paths.
  String _absolute(Uri base, String ref) {
    final uri = base.resolve(ref);
    if (uri.query.isNotEmpty || base.query.isEmpty) return uri.toString();
    return uri.replace(query: base.query).toString();
  }

  String? _attribute(String line, String name) {
    final match = RegExp(
      '(?:^|[:,])${RegExp.escape(name)}=\\s*([^,]*)',
      caseSensitive: false,
    ).firstMatch(line);
    final value = match?.group(1)?.trim();
    return value == null || value.isEmpty ? null : value.replaceAll('"', '');
  }

  int? _heightOf(String? resolution) {
    if (resolution == null) return null;
    final parts = resolution.toLowerCase().split('x');
    return parts.length == 2 ? int.tryParse(parts[1].trim()) : null;
  }
}
