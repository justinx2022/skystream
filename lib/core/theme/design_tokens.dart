import 'package:flutter/material.dart';

import 'app_world.dart';

/// The spacing scale. Every gap the overhaul introduces comes from here, so
/// density is a decision made once rather than per widget.
abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
  static const double huge = 64;

  /// Between a screen edge and its content, on a phone.
  static const double page = 20;

  /// The same, on a widescreen layout.
  static const double pageWide = 32;

  /// Between two rails on Home.
  static const double rail = 28;
}

/// Corner radii. Strings of pills are deliberately rare: a 28 px radius reads
/// as a panel, a 999 px radius reads as a toy, and this app wants the former.
abstract final class AppRadius {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;

  static BorderRadius get card => BorderRadius.circular(md);
  static BorderRadius get panel => BorderRadius.circular(lg);
  static BorderRadius get sheet => BorderRadius.circular(xl);
}

/// Motion. One fast duration for feedback, one for layout changes, one for a
/// full-surface transition. Anything longer than [slow] is an entrance, and
/// entrances stand down under reduced motion.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 320);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeOutQuart;

  /// What [showFocusIndicator] and every entrance animation must ask before
  /// running. The platform's own "reduce motion" switch is honoured rather
  /// than second-guessed.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Blur budgets. Glass is used on chrome, never on scrolling content - a
/// backdrop blur is a saveLayer, and on a television that is the difference
/// between 60 and 40 fps.
abstract final class AppBlur {
  static const double chrome = 18;
  static const double sheet = 24;
  static const double subtle = 10;
}

/// A small accent rule that sits above a section title. The pack's "restrained
/// gold line" idea, in both worlds.
class SectionRule extends StatelessWidget {
  const SectionRule({super.key, this.width = 18});

  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = AppWorldTokens.colorsOf(context);
    return Container(
      width: width,
      height: 2,
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}
