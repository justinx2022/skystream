import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/core/theme/app_world.dart';
import 'package:skystream/core/theme/theme_presets.dart';

/// The two worlds, as tokens.
///
/// These are the pack's colours, and they are asserted literally: a design
/// system whose tokens can drift without a test is a mood board, not a system.
void main() {
  group('the tokens are the pack, verbatim', () {
    test('SKY at night', () {
      expect(kSkyDark.background, const Color(0xFF0B1220));
      expect(kSkyDark.elevated, const Color(0xFF172338));
      expect(kSkyDark.accent, const Color(0xFFA9C2E4));
      expect(kSkyDark.textPrimary, const Color(0xFFF4F6FA));
      expect(kSkyDark.textSecondary, const Color(0xFFAAB7C9));
      expect(kSkyDark.divider, const Color(0xFF2A384D));
    });

    test('GROUND at night', () {
      expect(kGroundDark.background, const Color(0xFF151614));
      expect(kGroundDark.elevated, const Color(0xFF232320));
      expect(kGroundDark.accent, const Color(0xFFC4A477));
      expect(kGroundDark.textPrimary, const Color(0xFFF1EDE5));
      expect(kGroundDark.textSecondary, const Color(0xFFAAA69D));
      expect(kGroundDark.divider, const Color(0xFF393832));
    });

    test('daylight keeps the family rather than turning grey', () {
      // SKY's daylight background is still blue, GROUND's still warm: the hue
      // is the identity, the lightness is the brightness mode.
      expect(kSkyLight.background.b, greaterThan(kSkyLight.background.r));
      expect(kGroundLight.background.r, greaterThan(kGroundLight.background.b));
      expect(kGroundLight.accent.r, greaterThan(kGroundLight.accent.b));
    });
  });

  group('which world a branch is', () {
    test('discovery is SKY', () {
      for (final index in [0, 1, 2]) {
        expect(AppWorld.forBranch(index), AppWorld.sky);
      }
    });

    test('the personal branches are GROUND', () {
      for (final index in [3, 4]) {
        expect(AppWorld.forBranch(index), AppWorld.ground);
      }
    });
  });

  group('contrast, computed rather than eyeballed', () {
    double luminance(Color c) {
      double channel(double v) => v <= 0.03928
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4) as double;
      return 0.2126 * channel(c.r) +
          0.7152 * channel(c.g) +
          0.0722 * channel(c.b);
    }

    double contrast(Color a, Color b) {
      final la = luminance(a);
      final lb = luminance(b);
      final hi = math.max(la, lb);
      final lo = math.min(la, lb);
      return (hi + 0.05) / (lo + 0.05);
    }

    final palettes = <String, AppWorldColors>{
      'SKY dark': kSkyDark,
      'SKY light': kSkyLight,
      'GROUND dark': kGroundDark,
      'GROUND light': kGroundLight,
    };

    palettes.forEach((name, palette) {
      group(name, () {
        test('secondary text clears WCAG AA on every surface', () {
          for (final (where, surface) in [
            ('background', palette.background),
            ('elevated', palette.elevated),
            ('elevatedHigh', palette.elevatedHigh),
          ]) {
            final ratio = contrast(palette.textSecondary, surface);
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason:
                  '$name secondary on $where is ${ratio.toStringAsFixed(2)}:1',
            );
          }
        });

        test('primary text is comfortably past AA', () {
          final ratio = contrast(palette.textPrimary, palette.background);
          expect(ratio, greaterThanOrEqualTo(7));
        });

        test('the accent is visible as a non-text UI colour', () {
          // WCAG 1.4.11 asks 3:1 of a control boundary or indicator.
          expect(
            contrast(palette.accent, palette.background),
            greaterThanOrEqualTo(3),
          );
        });

        test('text on an accent fill is readable', () {
          expect(
            contrast(palette.onAccent, palette.accent),
            greaterThanOrEqualTo(4.5),
          );
        });
      });
    });
  });

  group('the page wash', () {
    test('is opaque at both stops, so contrast is a property of the token', () {
      for (final palette in [kSkyDark, kSkyLight, kGroundDark, kGroundLight]) {
        for (final colour in palette.pageGradient.colors) {
          expect(colour.a, 1.0);
        }
      }
    });

    test('tints the top of the page with the world accent', () {
      final top = kSkyDark.pageGradient.colors.first;
      expect(
        top.b,
        greaterThan(top.r),
        reason: 'SKY has to stay blue at the top',
      );
      final warm = kGroundDark.pageGradient.colors.first;
      expect(
        warm.r,
        greaterThan(warm.b),
        reason: 'GROUND has to stay warm at the top',
      );
    });

    test('the artwork scrim ends fully opaque', () {
      expect(kSkyDark.artworkScrim.colors.last, kSkyDark.background);
      expect(kGroundDark.artworkScrim.colors.first.a, 0);
    });
  });

  group('the theme takes the world', () {
    test('the default dark theme is SKY, accent and all', () {
      final theme = AppTheme.createDarkTheme(null);

      expect(theme.scaffoldBackgroundColor, kSkyDark.background);
      expect(theme.colorScheme.primary, kSkyDark.accent);
      expect(theme.colorScheme.onPrimary, kSkyDark.onAccent);
      expect(theme.colorScheme.onSurface, kSkyDark.textPrimary);
      expect(theme.textTheme.bodySmall!.color, kSkyDark.textSecondary);
    });

    test('the default light theme is SKY daylight', () {
      final theme = AppTheme.createLightTheme(null);

      expect(theme.scaffoldBackgroundColor, kSkyLight.background);
      expect(theme.colorScheme.primary, kSkyLight.accent);
    });

    test('GROUND is warm all the way through', () {
      final theme = AppTheme.createDarkTheme(null, world: AppWorld.ground);

      expect(theme.scaffoldBackgroundColor, kGroundDark.background);
      expect(theme.colorScheme.primary, kGroundDark.accent);
      expect(theme.colorScheme.onSurface, kGroundDark.textPrimary);
      expect(theme.dividerColor, kGroundDark.divider);
      expect(theme.extension<AppWorldTokens>()!.world, AppWorld.ground);
    });

    test('a chosen palette still owns the accent', () {
      final theme = AppTheme.createDarkTheme(null, palette: AppPalette.violet);

      expect(theme.colorScheme.primary, isNot(kSkyDark.accent));
      expect(
        theme.scaffoldBackgroundColor,
        kSkyDark.background,
        reason: 'the world still owns the surface',
      );
    });

    test('an explicit surface style still owns the surface', () {
      final theme = AppTheme.createDarkTheme(
        null,
        surface: AppSurfaceStyle.amoled,
      );

      expect(theme.scaffoldBackgroundColor, const Color(0xFF000000));
      expect(
        theme.extension<AppWorldTokens>()!.colors,
        kSkyDark,
        reason: 'the world is still SKY; only the surface was overridden',
      );
    });
  });
}
