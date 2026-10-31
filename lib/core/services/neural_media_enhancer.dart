import '../../../features/settings/presentation/ai_settings_provider.dart';

/// Generates neural MPV / libmpv property overrides, audio filter graphs,
/// and video shader chains based on SkyStream's active AI settings.
class NeuralMediaEnhancer {
  NeuralMediaEnhancer._();

  /// Audio filter chain (`af`) for dialogue isolation and speech intelligibility boost.
  ///
  /// Adds the center channel (c2) where there is one, at +6 dB of fold-down,
  /// and keeps the front pair at unity — a stereo track has no c2/c4/c5, so it
  /// passes through unchanged. The earlier `0.5*c0` front coefficients were a
  /// 5.1 downmix that ran on every source and measured 5.8 dB quieter on
  /// stereo. The limiter catches the sum when a real 5.1 track drives all
  /// three inputs at once.
  static String dialogueIsolationFilter() {
    return 'lavfi=[pan=stereo|c0=c0+0.707*c2+0.5*c4|c1=c1+0.707*c2+0.5*c5,alimiter=limit=0.95,highpass=f=200,equalizer=f=1200:t=q:w=1.5:g=5]';
  }

  /// Dynamic night-mode audio filter reducing explosive peaks and leveling whispers.
  static String nightModeAudioFilter() {
    return 'lavfi=[acompressor=threshold=-22dB:ratio=4:attack=20:release=250:makeup=2dB]';
  }

  /// Combines active audio filters into an mpv `af` flag.
  static String? buildAudioFilter(AiSettings settings) {
    if (!settings.aiEnabled) return null;
    final filters = <String>[];
    if (settings.dialogueIsolation) {
      filters.add(dialogueIsolationFilter());
    }
    if (settings.nightModeAudio) {
      filters.add(nightModeAudioFilter());
    }
    return filters.isEmpty ? null : filters.join(',');
  }

  /// mpv video options for HDR10 to SDR tone-mapping and neural color management.
  static Map<String, String> buildToneMappingOptions(AiSettings settings) {
    if (!settings.aiEnabled || !settings.hdrToneMapping) return const {};
    return const {
      'target-trc': 'auto',
      'tone-mapping': 'bt.2446a',
      'tone-mapping-mode': 'hybrid',
      'gamut-mapping-mode': 'perceptual',
    };
  }

  /// mpv options for anti-banding (smooth gradients, removes color banding in dark scenes).
  static Map<String, String> buildAntiBandingOptions(AiSettings settings) {
    if (!settings.aiEnabled || !settings.antiBanding) return const {};
    return const {
      'deband': 'yes',
      'deband-iterations': '2',
      'deband-threshold': '35',
      'deband-range': '16',
      'deband-grain': '5',
    };
  }

  /// mpv options for dynamic demuxer tuning (zero-lag high speed readahead).
  static Map<String, String> buildDemuxerTuningOptions(AiSettings settings) {
    if (!settings.aiEnabled || !settings.dynamicDemuxerTuning) return const {};
    return const {
      'demuxer-lavf-probesize': '1048576', // 1MB probe buffer (instant startup, avoids out of range without 4MB delay)
      'demuxer-lavf-analyzeduration':
          '500000', // 0.5s container analysis (fast time-to-first-frame)
      'hr-seek': 'yes',
      'hr-seek-framedrop':
          'yes', // Drop intermediate frames for instantaneous scrubbing
    };
  }
}
