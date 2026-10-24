import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

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
      }

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
          if (data is Map &&
              data['status_code'] == '200' &&
              data['data'] is Map) {
            final streamUrls = (data['data'] as Map)['stream_urls'];
            if (streamUrls is List) {
              for (var i = 0; i < streamUrls.length; i++) {
                final u = streamUrls[i]?.toString() ?? '';
                if (u.isNotEmpty && seen.add(u)) {
                  streams.add(AddonStreamSource(
                    addonId: 'cinepro-direct-hls',
                    addonName: 'Direct HLS',
                    name: '⚡ [HLS] VidApi Server ${i + 1} 1080p',
                    title: '⚡ Instant Direct Stream',
                    url: u,
                    proxyHeaders: const {
                      'User-Agent': _defaultUserAgent,
                      'Referer': 'https://brightpathsignals.com/',
                      'Origin': 'https://brightpathsignals.com',
                    },
                  ));
                }
              }
            }
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[DirectHlsService] vidapi error: $e');
        }
      }();

      // Step 3: Query VixSrc
      final vixsrcFuture = () async {
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
              final playlistUrl = playlistMatch.group(1)!;
              final token = tokenMatch.group(1)!;
              final expires = expiresMatch.group(1)!;
              final sep = playlistUrl.contains('?') ? '&' : '?';
              final masterUrl = '$playlistUrl${sep}token=$token&expires=$expires&h=1';

              if (seen.add(masterUrl)) {
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
        } catch (e) {
          if (kDebugMode) debugPrint('[DirectHlsService] vixsrc error: $e');
        }
      }();

      await Future.wait([vidapiFuture, vixsrcFuture]);
    } catch (e) {
      if (kDebugMode) debugPrint('[DirectHlsService] overall error: $e');
    }

    return streams;
  }
}
