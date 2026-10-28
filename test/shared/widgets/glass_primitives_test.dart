import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/shared/widgets/artwork_overlay.dart';
import 'package:skystream/shared/widgets/empty_state.dart';
import 'package:skystream/shared/widgets/glass_action_button.dart';
import 'package:skystream/shared/widgets/glass_surface.dart';
import 'package:skystream/shared/widgets/section_header.dart';

/// The shared primitives the overhaul adds.
///
/// Each test here is about a promise the rest of the UI relies on: glass is
/// one implementation, the section heading is a real heading, a button is a
/// button at ten feet, and the progress line cannot paint outside its track.
void main() {
  Widget host(
    Widget child, {
    bool disableAnimations = false,
    Brightness brightness = Brightness.dark,
  }) {
    return MaterialApp(
      theme: brightness == Brightness.dark
          ? AppTheme.createDarkTheme(null)
          : AppTheme.createLightTheme(null),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(body: Center(child: child)),
      ),
    );
  }

  group('GlassSurface', () {
    testWidgets('paints its child through one blur layer', (tester) async {
      await tester.pumpWidget(host(const GlassSurface(child: Text('panel'))));

      expect(find.text('panel'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('a zero sigma is the same panel without a saveLayer', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const GlassSurface(blurSigma: 0, child: Text('flat'))),
      );

      expect(find.text('flat'), findsOneWidget);
      expect(
        find.byType(BackdropFilter),
        findsNothing,
        reason: 'callers must be able to opt out of blur on cheap hardware',
      );
    });

    testWidgets('reduced motion removes the blur, not the panel', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const GlassSurface(child: Text('calm')), disableAnimations: true),
      );

      expect(find.text('calm'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('a panel keeps its child above the fill', (tester) async {
      // The glass tint is translucent; text painted *under* it would be washed
      // out. This asserts the panel paints a tint, and the child is inside it.
      await tester.pumpWidget(
        host(const GlassSurface(child: Text('readable'))),
      );

      final tinted = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .map((decoration) => decoration.color)
          .whereType<Color>()
          .toList();
      expect(tinted, isNotEmpty, reason: 'the panel must paint a fill');
      expect(
        tinted.every((color) => color.a < 1),
        isTrue,
        reason: 'glass is a tint, not a slab',
      );
      expect(find.text('readable'), findsOneWidget);
    });
  });

  group('SectionHeader', () {
    testWidgets('is a heading to accessibility services', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(const SectionHeader(title: 'Continue watching')),
      );

      expect(
        tester.getSemantics(find.text('Continue watching')),
        isSemantics(label: 'Continue watching', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('carries a subtitle and a trailing action', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        host(
          SectionHeader(
            title: 'Trending now',
            subtitle: 'Films and series',
            action: SectionHeaderAction(
              label: 'See all',
              onPressed: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.text('Trending now'), findsOneWidget);
      expect(find.text('Films and series'), findsOneWidget);
      await tester.tap(find.text('See all'));
      expect(tapped, isTrue);
    });
  });

  group('GlassActionButton', () {
    testWidgets('is a button and fires on tap', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        host(
          GlassActionButton(
            label: 'Play',
            icon: Icons.play_arrow_rounded,
            primary: true,
            onPressed: () => taps++,
          ),
        ),
      );

      expect(
        tester.getSemantics(find.byType(InkWell)),
        isSemantics(label: 'Play', isButton: true, isEnabled: true),
      );
      await tester.tap(find.text('Play'));
      expect(taps, 1);
      handle.dispose();
    });

    testWidgets('meets the ten-foot minimum height', (tester) async {
      await tester.pumpWidget(
        host(GlassActionButton(label: 'Trailer', onPressed: () {})),
      );

      expect(
        tester.getSize(find.byType(GlassActionButton)).height,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('a disabled action does not fire', (tester) async {
      await tester.pumpWidget(
        host(const GlassActionButton(label: 'Play', onPressed: null)),
      );
      await tester.tap(find.text('Play'), warnIfMissed: false);
      expect(
        tester.widget<InkWell>(find.byType(InkWell)).onTap,
        isNull,
        reason: 'a disabled action must not carry a handler at all',
      );
    });

    testWidgets('takes keyboard activation', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          GlassActionButton(
            label: 'Play',
            autofocus: true,
            onPressed: () => taps++,
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1, reason: 'a remote sends Enter, not a tap');
    });
  });

  group('ProgressLine', () {
    testWidgets('clamps a nonsense fraction instead of overflowing', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 200,
            child: Column(
              children: [
                ProgressLine(value: 2, buffered: 3),
                ProgressLine(value: double.nan),
                ProgressLine(value: -1),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final fractions = tester
          .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .map((f) => f.widthFactor)
          .toList();
      expect(fractions, everyElement(inInclusiveRange(0, 1)));
    });
  });

  group('ArtworkOverlay', () {
    testWidgets('keeps the title on the world scrim', (tester) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 240,
            height: 360,
            child: Stack(
              children: [
                ColoredBox(color: Color(0xFF334455)),
                ArtworkOverlay(title: 'Dune', meta: '2021 · Film'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('2021 · Film'), findsOneWidget);
    });

    testWidgets('does not steal taps from the card underneath', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 240,
            height: 360,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => taps++,
                    child: const ColoredBox(color: Color(0xFF334455)),
                  ),
                ),
                const ArtworkOverlay(title: 'Dune'),
              ],
            ),
          ),
        ),
      );

      // The artwork is 240x360 centred in an 800x600 surface: (400, 150) is
      // inside the poster and above the overlay's own text.
      await tester.tapAt(const Offset(400, 150));
      expect(taps, 1);
    });
  });

  group('EmptyState', () {
    testWidgets('offers the one next action', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        host(
          EmptyState(
            icon: Icons.history_rounded,
            title: 'Nothing watched yet',
            message: 'Titles you play will show up here.',
            actionLabel: 'Browse',
            onAction: () => tapped = true,
          ),
        ),
      );

      expect(find.text('Nothing watched yet'), findsOneWidget);
      await tester.tap(find.text('Browse'));
      expect(tapped, isTrue);
    });
  });
}
