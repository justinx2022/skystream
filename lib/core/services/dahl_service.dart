import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/settings/presentation/ai_settings_provider.dart';

/// Core Service interfacing SkyStream with the Dahl Neural Gateway.
///
/// Handles autonomous scraper repair, 403-forbidden header negotiation,
/// scene context generation, and dynamic audio/video filter recommendations.
class DahlService {
  DahlService(this._ref) {
    _dio = Dio(
      BaseOptions(
        baseUrl: 'https://inference.dahl.global/v1',
        connectTimeout: const Duration(milliseconds: 3500),
        receiveTimeout: const Duration(milliseconds: 6000),
        headers: <String, dynamic>{
          'Content-Type': 'application/json',
          'User-Agent': 'SkyStream-NeuralCore/2.0',
        },
      ),
    );
  }

  final Ref _ref;
  late final Dio _dio;

  AiSettings _getSettings() {
    final asyncVal = _ref.read<AsyncValue<AiSettings>>(aiSettingsProvider);
    return asyncVal.asData?.value ?? const AiSettings();
  }

  /// The token the viewer entered, or empty.
  ///
  /// There used to be a token baked into this file as a fallback for everyone
  /// who had not entered one. A credential in published source is a credential
  /// anyone can spend, so it is gone — and it must be revoked at the provider,
  /// because shipping it already exposed it.
  String get _apiKey => _getSettings().dahlApiKey.trim();

  String get _model {
    return _getSettings().dahlModel;
  }

  bool get _isEnabled {
    return _getSettings().aiEnabled;
  }

  /// Sends a low-latency prompt to Dahl.
  Future<String?> complete({
    required String prompt,
    int maxTokens = 500,
    double temperature = 0.2,
    String? overrideModel,
  }) async {
    if (!_isEnabled) return null;
    final apiKey = _apiKey;
    // Without a key the request could only come back 401 after the full
    // connect + receive timeout, which on the failure path is time spent not
    // showing the viewer the real error.
    if (apiKey.isEmpty) return null;
    try {
      final res = await _dio.post<dynamic>(
        '/chat/completions',
        options: Options(
          headers: <String, dynamic>{'Authorization': 'Bearer $apiKey'},
        ),
        data: <String, dynamic>{
          'model': overrideModel ?? _model,
          'messages': <Map<String, String>>[
            <String, String>{'role': 'user', 'content': prompt},
          ],
          'max_tokens': maxTokens,
          'temperature': temperature,
        },
      );
      if (res.statusCode == 200 && res.data != null) {
        final dynamic data = res.data is String
            ? jsonDecode(res.data as String)
            : res.data;
        if (data is Map) {
          final choices = data['choices'];
          if (choices is List && choices.isNotEmpty) {
            final first = choices.first;
            if (first is Map && first['message'] is Map) {
              return first['message']['content']?.toString().trim();
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[DahlService] Inference failed: $e');
    }
    return null;
  }

  /// Inspects a failing or disguised stream web page and extracts direct video links.
  Future<String?> repairBrokenScraper({
    required String rawSnippet,
    required String streamHint,
  }) async {
    final settings = _getSettings();
    if (!settings.selfHealingScrapers) return null;
    // The caller sometimes passes an exception message. There is nothing to
    // extract from that, so the model would only invent a link. Require real
    // markup before spending a request.
    if (!rawSnippet.contains('<')) return null;

    final prompt =
        'Extract the direct playable video link (HLS .m3u8, MP4, or worker direct link) '
        'from this HTML snippet. Target context: $streamHint.\n'
        'Snippet:\n${rawSnippet.substring(0, rawSnippet.length.clamp(0, 3000))}\n'
        'Reply ONLY with the absolute raw URL or NONE.';

    final out = await complete(prompt: prompt, maxTokens: 200);
    if (out == null) return null;
    final candidate = out.trim();
    final parsed = Uri.tryParse(candidate);
    final valid = parsed != null &&
        (parsed.scheme == 'http' || parsed.scheme == 'https') &&
        parsed.host.isNotEmpty &&
        !candidate.contains(RegExp(r'\s'));
    return valid ? candidate : null;
  }

  /// Evaluates 403 Forbidden errors and determines required bypass headers (Referer, Host, Origin).
  Future<Map<String, String>?> resolve403BypassHeaders({
    required String url,
    required Map<String, String> currentHeaders,
  }) async {
    final settings = _getSettings();
    if (!settings.autoFixForbiddenHeaders) return null;

    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final prompt =
        'A stream request to "$url" resulted in 403 Forbidden.\n'
        'Current headers: $currentHeaders\n'
        'What Referer, Origin, or User-Agent is needed by this CDN host (${uri.host})? '
        'Output as clean JSON {"HeaderName": "Value"}.';

    final out = await complete(prompt: prompt, maxTokens: 150);
    if (out != null) {
      try {
        final jsonStart = out.indexOf('{');
        final jsonEnd = out.lastIndexOf('}');
        if (jsonStart != -1 && jsonEnd != -1) {
          final decoded = jsonDecode(out.substring(jsonStart, jsonEnd + 1));
          if (decoded is Map) {
            return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
          }
        }
      } catch (_) {}
    }
    return null;
  }
}

final dahlServiceProvider = Provider<DahlService>((ref) {
  return DahlService(ref);
});
