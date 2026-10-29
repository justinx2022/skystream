/// How the player reads a subtitle file: from this device, or over the
/// network with the headers it came with.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/dio_client_provider.dart';
import '../../domain/side_car_subtitles.dart';

/// How long a subtitle file may take to arrive.
const Duration _kTimeout = Duration(seconds: 20);

/// The most of a subtitle file that is read. Files run to kilobytes, a large
/// SubStation Alpha script with styling to a few megabytes.
const int _kMaxBytes = 16 * 1024 * 1024;

/// The fetch [SideCarSubtitles] reads files with. A provider so a test can
/// serve files from memory.
final sideCarFetchProvider = Provider<SideCarFetch>((ref) {
  final dio = ref.watch(dioClientProvider);
  return (url, headers) => fetchSideCar(dio, url, headers);
});

/// Reads the subtitle file at [url] - a `file:` one from this device, an
/// `http(s):` one with [dio] and [headers] - or null when it cannot be had.
Future<List<int>?> fetchSideCar(
  Dio dio,
  Uri url,
  Map<String, String>? headers,
) async {
  if (url.scheme == 'file') {
    try {
      return await File.fromUri(url).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }
  if (!url.scheme.startsWith('http')) return null;

  final effectiveHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Accept': '*/*',
    ...?headers,
  };

  // Up to 2 attempts for resilience against temporary network blips
  for (var attempt = 0; attempt < 2; attempt++) {
    final cancel = CancelToken();
    try {
      final response = await dio.getUri<List<int>>(
        url,
        cancelToken: cancel,
        options: Options(
          headers: effectiveHeaders,
          responseType: ResponseType.bytes,
          receiveTimeout: _kTimeout,
          sendTimeout: _kTimeout,
        ),
        onReceiveProgress: (received, _) {
          if (received > _kMaxBytes) cancel.cancel();
        },
      );
      if (response.data != null && response.data!.isNotEmpty) {
        return response.data;
      }
    } catch (_) {
      if (attempt == 1) return null;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  return null;
}
