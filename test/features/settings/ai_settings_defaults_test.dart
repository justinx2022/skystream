import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/settings/presentation/ai_settings_provider.dart';

/// The AI features are opt-in: a fresh install must not run shaders, the
/// audio filter, the scraper repair or the 403 header guesser before the
/// viewer has asked for any of it.
void main() {
  const List<bool Function(AiSettings)> aiFlags = <bool Function(AiSettings)>[
    _aiEnabled,
    _hdrToneMapping,
    _antiBanding,
    _dialogueIsolation,
    _selfHealingScrapers,
    _autoFixForbiddenHeaders,
  ];

  test('a fresh AiSettings has every AI feature off', () {
    const AiSettings settings = AiSettings();
    for (final bool Function(AiSettings) flag in aiFlags) {
      expect(flag(settings), isFalse);
    }
  });

  test('a saved map with the keys missing falls back to off', () {
    final AiSettings settings = AiSettings.fromMap(const <String, dynamic>{});
    for (final bool Function(AiSettings) flag in aiFlags) {
      expect(flag(settings), isFalse);
    }
  });

  test('a saved true is still honoured', () {
    final AiSettings settings = AiSettings.fromMap(const <String, dynamic>{
      'aiEnabled': true,
      'hdrToneMapping': true,
      'antiBanding': true,
      'dialogueIsolation': true,
      'selfHealingScrapers': true,
      'autoFixForbiddenHeaders': true,
    });
    for (final bool Function(AiSettings) flag in aiFlags) {
      expect(flag(settings), isTrue);
    }
  });
}

bool _aiEnabled(AiSettings s) => s.aiEnabled;
bool _hdrToneMapping(AiSettings s) => s.hdrToneMapping;
bool _antiBanding(AiSettings s) => s.antiBanding;
bool _dialogueIsolation(AiSettings s) => s.dialogueIsolation;
bool _selfHealingScrapers(AiSettings s) => s.selfHealingScrapers;
bool _autoFixForbiddenHeaders(AiSettings s) => s.autoFixForbiddenHeaders;