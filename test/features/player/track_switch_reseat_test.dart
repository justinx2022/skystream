import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_tracks_tab.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// Switching a track changes it in place, with no rebuffer behind it.
///
/// This file used to pin the opposite: re-issuing the current position after
/// the switch, so the newly chosen stream - which begins at the demuxer's read
/// point, a whole caching interval ahead of the picture - was flushed and
/// refilled together. That cost every stream a rebuffer, spinner included, for
/// a track the engine had already switched; it is gone, and these tests pin
/// what replaced it. A subtitle switch to Off still pays even less: nothing
/// has to be fetched to show nothing.
void main() {
  Future<VlcPlayerController> attach(FakeVlcEngine engine) async {
    engine.install();
    addTearDown(engine.dispose);
    return engine.attach();
  }

  Future<void> pumpTracksTab(
    WidgetTester tester, {
    required VlcPlayerController controller,
    required PlayerTrackKind kind,
    required List<VlcTrackDescription> tracks,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerTracksTab(
            controller: controller,
            kind: kind,
            tracks: tracks,
            trackInfo: const <VlcMediaTrackInfo>[],
            onTracksChanged: () {},
            onOpenPage: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A player a minute into a seekable film.
  FakeVlcEngine playingEngine() => FakeVlcEngine()
    ..audio = <Map<String, Object?>>[
      <String, Object?>{'id': 1, 'name': 'English', 'language': 'eng'},
      <String, Object?>{'id': 3, 'name': 'French', 'language': 'fra'},
    ]
    ..activeAudioId = 1;

  const tracks = <VlcTrackDescription>[
    VlcTrackDescription(id: 1, name: 'English', language: 'eng'),
    VlcTrackDescription(id: 3, name: 'French', language: 'fra'),
  ];

  testWidgets('choosing an audio track switches it without re-seating', (
    tester,
  ) async {
    final engine = playingEngine();
    final controller = await attach(engine);
    await engine.emit(<String, Object?>{
      'position': 60000,
      'duration': 600000,
    });
    await tester.pump(const Duration(milliseconds: 400));

    await pumpTracksTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.audio,
      tracks: tracks,
    );

    await tester.tap(find.text('French'));
    await tester.pumpAndSettle();

    expect(engine.methods, contains('setAudioTrack'));
    // Re-issuing the position would flush every stream and show a rebuffer in
    // exchange for a track that has already changed, so the switch is the
    // whole of the work.
    expect(
      engine.methods,
      isNot(contains('seekTo')),
      reason: 'the flush would rebuffer the whole stream for a track the '
          'engine has already switched',
    );

    controller.dispose();
  });

  testWidgets('turning subtitles off does not pay for a rebuffer', (
    tester,
  ) async {
    // Nothing has to be fetched to show nothing, so the flush would be a
    // spinner in exchange for no benefit at all.
    final engine = playingEngine()
      ..subtitle = <Map<String, Object?>>[
        <String, Object?>{'id': 5, 'name': 'English', 'language': 'eng'},
      ]
      ..activeSubtitleId = 5;
    final controller = await attach(engine);
    await engine.emit(<String, Object?>{
      'position': 60000,
      'duration': 600000,
    });
    await tester.pump(const Duration(milliseconds: 400));

    await pumpTracksTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.subtitle,
      tracks: const <VlcTrackDescription>[
        VlcTrackDescription(id: 5, name: 'English', language: 'eng'),
      ],
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.off));
    await tester.pumpAndSettle();

    expect(engine.methods, contains('disableSubtitle'));
    expect(engine.methods, isNot(contains('seekTo')));

    controller.dispose();
  });

  testWidgets('a live feed is never re-seated', (tester) async {
    // There is nowhere to seek to, and asking would fail the call.
    final engine = playingEngine();
    final controller = await attach(engine);
    await engine.emit(<String, Object?>{
      'position': 60000,
      'duration': 0,
      'isLive': true,
      'isSeekable': false,
    });
    await tester.pump(const Duration(milliseconds: 400));

    await pumpTracksTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.audio,
      tracks: tracks,
    );

    await tester.tap(find.text('French'));
    await tester.pumpAndSettle();

    expect(engine.methods, contains('setAudioTrack'));
    expect(engine.methods, isNot(contains('seekTo')));

    controller.dispose();
  });
}
