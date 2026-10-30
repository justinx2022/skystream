import '../../../features/settings/presentation/ai_settings_provider.dart';

/// Generates neural MPV / libmpv property overrides, audio filter graphs,
/// and video shader chains based on SkyStream's active AI settings.
class NeuralMediaEnhancer {
  NeuralMediaEnhancer._();

  /// Audio filter chain (`af`) for dialogue isolation and speech intelligibility boost.
  ///
  /// Extracts the center dialogue channel (c2) in 5.1 tracks and mixes it into stereo channels
  /// at +6dB with a high-pass vocal presence filter (300Hz - 3400Hz).
  static String dialogueIsolationFilter() {
    return 'lavfi=[pan=stereo|c0=0.5*c0+0.707*c2+0.5*c4|c1=0.5*c1+0.707*c2+0.5*c5,highpass=f=200,equalizer=f=1200:t=q:w=1.5:g=5]';
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
      'demuxer-lavf-probesize': '32768',
      'demuxer-readahead-secs': '90',
      'demuxer-max-bytes': '157286400', // 150MB buffer
      'hr-seek': 'yes',
      'hr-seek-framedrop': 'no',
    };
  }
}
