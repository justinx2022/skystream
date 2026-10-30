import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/storage/settings_repository.dart';

/// Configuration and toggles for SkyStream's in-app AI Neural Engine (Dahl).
class AiSettings {
  const AiSettings({
    this.aiEnabled = true,
    this.dahlApiKey = '',
    this.dahlModel = 'MiniMaxAI/MiniMax-M2.7',
    // 1. Playback & Network Acceleration
    this.intentPreFetch = true,
    this.multiCdnSharding = true,
    this.dynamicDemuxerTuning = true,
    this.seekKeyframePreCache = true,
    // 2. Video & Shaders
    this.neuralSuperResolution = false,
    this.hdrToneMapping = true,
    this.antiBanding = true,
    // 3. Audio Intelligence
    this.dialogueIsolation = true,
    this.nightModeAudio = false,
    this.multiAudioSync = true,
    // 4. Subtitles & X-Ray
    this.acousticSubSync = true,
    this.loreHud = false,
    this.realtimeTranslation = false,
    // 5. Self-Healing & Scrapers
    this.selfHealingScrapers = true,
    this.autoFixForbiddenHeaders = true,
    this.ghostLinkResurrection = true,
  });

  final bool aiEnabled;
  final String dahlApiKey;
  final String dahlModel;

  // Playback & Network
  final bool intentPreFetch;
  final bool multiCdnSharding;
  final bool dynamicDemuxerTuning;
  final bool seekKeyframePreCache;

  // Video & Shaders
  final bool neuralSuperResolution;
  final bool hdrToneMapping;
  final bool antiBanding;

  // Audio Intelligence
  final bool dialogueIsolation;
  final bool nightModeAudio;
  final bool multiAudioSync;

  // Subtitles & X-Ray
  final bool acousticSubSync;
  final bool loreHud;
  final bool realtimeTranslation;

  // Self-Healing
  final bool selfHealingScrapers;
  final bool autoFixForbiddenHeaders;
  final bool ghostLinkResurrection;

  AiSettings copyWith({
    bool? aiEnabled,
    String? dahlApiKey,
    String? dahlModel,
    bool? intentPreFetch,
    bool? multiCdnSharding,
    bool? dynamicDemuxerTuning,
    bool? seekKeyframePreCache,
    bool? neuralSuperResolution,
    bool? hdrToneMapping,
    bool? antiBanding,
    bool? dialogueIsolation,
    bool? nightModeAudio,
    bool? multiAudioSync,
    bool? acousticSubSync,
    bool? loreHud,
    bool? realtimeTranslation,
    bool? selfHealingScrapers,
    bool? autoFixForbiddenHeaders,
    bool? ghostLinkResurrection,
  }) {
    return AiSettings(
      aiEnabled: aiEnabled ?? this.aiEnabled,
      dahlApiKey: dahlApiKey ?? this.dahlApiKey,
      dahlModel: dahlModel ?? this.dahlModel,
      intentPreFetch: intentPreFetch ?? this.intentPreFetch,
      multiCdnSharding: multiCdnSharding ?? this.multiCdnSharding,
      dynamicDemuxerTuning: dynamicDemuxerTuning ?? this.dynamicDemuxerTuning,
      seekKeyframePreCache: seekKeyframePreCache ?? this.seekKeyframePreCache,
      neuralSuperResolution: neuralSuperResolution ?? this.neuralSuperResolution,
      hdrToneMapping: hdrToneMapping ?? this.hdrToneMapping,
      antiBanding: antiBanding ?? this.antiBanding,
      dialogueIsolation: dialogueIsolation ?? this.dialogueIsolation,
      nightModeAudio: nightModeAudio ?? this.nightModeAudio,
      multiAudioSync: multiAudioSync ?? this.multiAudioSync,
      acousticSubSync: acousticSubSync ?? this.acousticSubSync,
      loreHud: loreHud ?? this.loreHud,
      realtimeTranslation: realtimeTranslation ?? this.realtimeTranslation,
      selfHealingScrapers: selfHealingScrapers ?? this.selfHealingScrapers,
      autoFixForbiddenHeaders: autoFixForbiddenHeaders ?? this.autoFixForbiddenHeaders,
      ghostLinkResurrection: ghostLinkResurrection ?? this.ghostLinkResurrection,
    );
  }

  Map<String, dynamic> toMap() => {
        'aiEnabled': aiEnabled,
        'dahlApiKey': dahlApiKey,
        'dahlModel': dahlModel,
        'intentPreFetch': intentPreFetch,
        'multiCdnSharding': multiCdnSharding,
        'dynamicDemuxerTuning': dynamicDemuxerTuning,
        'seekKeyframePreCache': seekKeyframePreCache,
        'neuralSuperResolution': neuralSuperResolution,
        'hdrToneMapping': hdrToneMapping,
        'antiBanding': antiBanding,
        'dialogueIsolation': dialogueIsolation,
        'nightModeAudio': nightModeAudio,
        'multiAudioSync': multiAudioSync,
        'acousticSubSync': acousticSubSync,
        'loreHud': loreHud,
        'realtimeTranslation': realtimeTranslation,
        'selfHealingScrapers': selfHealingScrapers,
        'autoFixForbiddenHeaders': autoFixForbiddenHeaders,
        'ghostLinkResurrection': ghostLinkResurrection,
      };

  factory AiSettings.fromMap(Map<String, dynamic> map) => AiSettings(
        aiEnabled: map['aiEnabled'] as bool? ?? true,
        dahlApiKey: map['dahlApiKey'] as String? ?? '',
        dahlModel: map['dahlModel'] as String? ?? 'MiniMaxAI/MiniMax-M2.7',
        intentPreFetch: map['intentPreFetch'] as bool? ?? true,
        multiCdnSharding: map['multiCdnSharding'] as bool? ?? true,
        dynamicDemuxerTuning: map['dynamicDemuxerTuning'] as bool? ?? true,
        seekKeyframePreCache: map['seekKeyframePreCache'] as bool? ?? true,
        neuralSuperResolution: map['neuralSuperResolution'] as bool? ?? false,
        hdrToneMapping: map['hdrToneMapping'] as bool? ?? true,
        antiBanding: map['antiBanding'] as bool? ?? true,
        dialogueIsolation: map['dialogueIsolation'] as bool? ?? true,
        nightModeAudio: map['nightModeAudio'] as bool? ?? false,
        multiAudioSync: map['multiAudioSync'] as bool? ?? true,
        acousticSubSync: map['acousticSubSync'] as bool? ?? true,
        loreHud: map['loreHud'] as bool? ?? false,
        realtimeTranslation: map['realtimeTranslation'] as bool? ?? false,
        selfHealingScrapers: map['selfHealingScrapers'] as bool? ?? true,
        autoFixForbiddenHeaders: map['autoFixForbiddenHeaders'] as bool? ?? true,
        ghostLinkResurrection: map['ghostLinkResurrection'] as bool? ?? true,
      );
}

class AiSettingsNotifier extends StateNotifier<AsyncValue<AiSettings>> {
  AiSettingsNotifier(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  final Ref _ref;
  static const String keyName = 'skystream_ai_settings_json';

  void _load() {
    try {
      final repository = _ref.read(settingsRepositoryProvider);
      final raw = repository.getPlayerSetting<String>(keyName);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        state = AsyncValue.data(AiSettings.fromMap(map));
        return;
      }
      state = const AsyncValue.data(AiSettings());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> update(AiSettings Function(AiSettings) mutate) async {
    final current = state.asData?.value ?? const AiSettings();
    final updated = mutate(current);
    state = AsyncValue.data(updated);
    try {
      final repository = _ref.read(settingsRepositoryProvider);
      await repository.setPlayerSetting<String>(keyName, jsonEncode(updated.toMap()));
    } catch (_) {}
  }
}

final aiSettingsProvider =
    StateNotifierProvider<AiSettingsNotifier, AsyncValue<AiSettings>>((ref) {
  return AiSettingsNotifier(ref);
});
