/// One row per encode, not per token.
///
/// The VidApi API lists its "servers" as separate links, and they are
/// routinely the same stream behind different tokens - measured on one film,
/// three URLs whose masters carried identical variant lines. Keeping all
/// three cost the viewer a silent-open watchdog each before failover could
/// reach a source that worked, so the rows are deduped on the master's
/// `#EXT-X-STREAM-INF` lines: the cheap place the shared encode shows.
///
/// When a master cannot be read the link keeps its own URL as the key -
/// dropping a distinct source because its playlist was slow would be worse
/// than keeping a duplicate.
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/direct_hls_service.dart';

const String _a = 'https://cdn.test/a.m3u8';
const String _b = 'https://cdn.test/b.m3u8';
const String _c = 'https://cdn.test/c.m3u8';

const String _encode1080 =
    '#EXT-X-STREAM-INF:BANDWIDTH=4629855,CODECS="mp4a.40.2,avc1.640028",'
    'RESOLUTION=1920x800,FRAME-RATE=24';
const String _encode720 =
    '#EXT-X-STREAM-INF:BANDWIDTH=2540758,CODECS="mp4a.40.2,avc1.64001f",'
    'RESOLUTION=1280x534,FRAME-RATE=24';

class _HlsCdn implements HttpClientAdapter {
  _HlsCdn({required this.masters});

  /// Master playlist per link URL. A link missing from here answers 404, the
  /// shape of a master that cannot be read.
  final Map<String, String> masters;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    if (url.startsWith('https://v3-cinemeta.strem.io')) {
      return _body(
        jsonEncode(<String, Object?>{
          'meta': <String, Object?>{'moviedb_id': 155},
        }),
        200,
        'application/json',
      );
    }
    if (url.startsWith('https://streamdata.vaplayer.ru')) {
      return _body(
        jsonEncode(<String, Object?>{
          'status_code': '200',
          'data': <String, Object?>{
            'stream_urls': <String>[_a, _b, _c],
          },
        }),
        200,
        'application/json',
      );
    }
    if (url.startsWith('https://vixsrc.to')) {
      // The embed is gone at the moment; a dead second source must not stop
      // the first one being deduped.
      return _body('<!DOCTYPE html>', 410, 'text/html; charset=UTF-8');
    }
    final body = masters[url];
    if (body == null) return _body('missing', 404, 'text/plain');
    return _body(body, 200, 'application/vnd.apple.mpegurl');
  }

  ResponseBody _body(String body, int status, String type) =>
      ResponseBody.fromString(
        body,
        status,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[type],
        },
      );

  @override
  void close({bool force = false}) {}
}

Future<List<String>> _urlsFor(HttpClientAdapter adapter) async {
  final dio = Dio()..httpClientAdapter = adapter;
  final sources = await DirectHlsService(dio).resolveDirectStreams(
    imdbId: 'tt0468569',
    type: 'movie',
  );
  return sources.map((s) => s.url).whereType<String>().toList(growable: false);
}

void main() {
  test('two tokens on one encode collapse to the first row', () async {
    final urls = await _urlsFor(
      _HlsCdn(
        masters: <String, String>{
          // Same renditions listed in a different order: still one encode.
          _a: '#EXTM3U\n$_encode1080\n$_encode720\n/pl/a\n/pl/b\n',
          _b: '#EXTM3U\n$_encode720\n$_encode1080\n/pl/c\n/pl/d\n',
          _c: '#EXTM3U\n$_encode720\n/pl/e\n',
        },
      ),
    );

    expect(urls, <String>[_a, _c]);
  });

  test('an unreadable master keeps its link', () async {
    final urls = await _urlsFor(_HlsCdn(masters: const <String, String>{}));

    expect(urls, <String>[_a, _b, _c]);
  });
}
