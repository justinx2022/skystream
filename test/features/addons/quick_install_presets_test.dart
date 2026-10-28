import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/addons/presentation/widgets/addon_manage_view.dart';

/// The Quick Install row shows a short starter list and nothing else. Two of
/// the three are the official add-ons; Torrentio's direct-P2P entry is the
/// deliberate exception, and the rest of the community directory (MediaFusion,
/// Comet and ~95 others) lives one tab over on Discover.
void main() {
  test('quick install offers exactly the three starter add-ons', () {
    expect(kAddonPresets, hasLength(3));

    final byName = {for (final p in kAddonPresets) p.name: p.url};
    expect(byName, {
      'Cinemeta': 'https://v3-cinemeta.strem.io/manifest.json',
      'Torrentio (P2P)': 'https://torrentio.strem.fun/manifest.json',
      'OpenSubtitles v3': 'https://opensubtitles-v3.strem.io/manifest.json',
    });
  });

  test('preset URLs are unique and well-formed', () {
    final urls = kAddonPresets.map((p) => p.url).toList();
    expect(urls.toSet(), hasLength(urls.length));
    for (final url in urls) {
      expect(url, startsWith('https://'));
      expect(url, endsWith('/manifest.json'));
    }
  });
}
