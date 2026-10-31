import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/services/neural_media_enhancer.dart';
import 'package:skystream/features/settings/presentation/ai_settings_provider.dart';

/// mpv takes `demuxer-lavf-analyzeduration` in seconds. `500000` is not a
/// half-second expressed in microseconds, it is five and a half days, and mpv
/// rejected it as out of range on every open.
void main() {
  test('analyzeduration is 0.5 seconds, not 500000', () {
    final Map<String, String> options =
        NeuralMediaEnhancer.buildDemuxerTuningOptions(
      const AiSettings(aiEnabled: true),
    );

    expect(options['demuxer-lavf-analyzeduration'], '0.5');
    expect(options.values, isNot(contains('500000')));
  });

  test('tuning stays empty while the AI master switch is off', () {
    expect(
      NeuralMediaEnhancer.buildDemuxerTuningOptions(const AiSettings()),
      isEmpty,
    );
  });

  test('the player sets the same value when it applies options directly', () {
    final String source = File(
      'lib/features/player/presentation/mediakit/mediakit_player_screen.dart',
    ).readAsStringSync();

    expect(
      RegExp(
        r"setProperty\(\s*'demuxer-lavf-analyzeduration',\s*'0\.5'\s*\)",
      ).allMatches(source),
      hasLength(2),
    );
    expect(source, isNot(contains("'500000'")));
  });
}