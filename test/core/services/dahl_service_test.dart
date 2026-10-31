import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/services/dahl_service.dart';
import 'package:skystream/features/settings/presentation/ai_settings_provider.dart';

/// Keeps [aiSettingsProvider] off the on-disk repository so the service sees
/// exactly the settings a test asks for.
class _FixedAiSettings extends AiSettingsNotifier {
  _FixedAiSettings(this._value);

  final AiSettings _value;

  @override
  AsyncValue<AiSettings> build() => AsyncValue.data(_value);
}

void main() {
  ProviderContainer containerWith(AiSettings settings) {
    return ProviderContainer(
      overrides: [
        aiSettingsProvider.overrideWith(() => _FixedAiSettings(settings)),
      ],
    );
  }

  test('an exception message is never sent to the model as a snippet', () async {
    final container = containerWith(
      const AiSettings(aiEnabled: true, selfHealingScrapers: true),
    );
    addTearDown(container.dispose);

    final String? repaired = await container
        .read(dahlServiceProvider)
        .repairBrokenScraper(
          rawSnippet: 'Exception: foo',
          streamHint: 'movie',
        );

    expect(repaired, isNull);
  });

  test('empty markup is rejected before any request', () async {
    final container = containerWith(
      const AiSettings(aiEnabled: true, selfHealingScrapers: true),
    );
    addTearDown(container.dispose);

    expect(
      await container.read(dahlServiceProvider).repairBrokenScraper(
            rawSnippet: '',
            streamHint: 'movie',
          ),
      isNull,
    );
  });

  test('repair stays off while the self-healing switch is off', () async {
    final container = containerWith(const AiSettings(aiEnabled: true));
    addTearDown(container.dispose);

    expect(
      await container.read(dahlServiceProvider).repairBrokenScraper(
            rawSnippet: '<html><body>src="x"</body></html>',
            streamHint: 'movie',
          ),
      isNull,
    );
  });
}