import 'package:flutter/material.dart';

/// The colour family the app's Material 3 scheme is generated from.
///
/// [dynamic] is the wallpaper - the scheme the platform reports - and is the
/// only palette that needs nothing chosen. The rest are seeds, so every role
/// the app reads (`primary`, `onSurfaceVariant`, the containers) moves with
/// them instead of only the buttons being tinted.
enum AppPalette {
  dynamic(null),
  blue(Color(0xFF448AFF)),
  emerald(Color(0xFF10B981)),
  coral(Color(0xFFC63523)),
  violet(Color(0xFF8B5CF6)),
  amber(Color(0xFFF59E0B));

  const AppPalette(this.seed);

  /// Null for [dynamic]: the caller passes the platform's scheme instead.
  final Color? seed;

  static AppPalette fromStorage(Object? raw) {
    for (final palette in values) {
      if (palette.name == raw) return palette;
    }
    return dynamic;
  }
}

/// What the app is painted on, underneath the content.
///
/// [automatic] is the pair the app shipped with before this choice existed -
/// pure black at night, warm paper in daylight - so a device that never opens
/// the picker looks exactly as it did. The rest are explicit.
enum AppSurfaceStyle {
  automatic,
  amoled,
  midnight,
  standard,
  paper;

  static AppSurfaceStyle fromStorage(Object? raw) {
    for (final style in values) {
      if (style.name == raw) return style;
    }
    return automatic;
  }
}

/// An optional ambient gradient behind the whole app.
///
/// Painted by `AppBackdropLayer` behind the navigator, and only when a scaffold
/// is transparent (which the theme arranges when one of these is selected).
/// Every stop is opaque: text is always drawn on a colour the theme knows, so
/// contrast stays a property of the palette rather than of whatever happens to
/// be behind the glass.
enum AppBackdrop {
  none,
  aurora,
  dusk,
  ember;

  static AppBackdrop fromStorage(Object? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return none;
  }

  /// The gradient for [base] at this brightness, or null when there is none.
  ///
  /// [seed] is the scheme's primary, so the ambience belongs to the chosen
  /// palette without the user having to place two separate choices in tune
  /// with each other.
  LinearGradient? gradientFor({
    required Brightness brightness,
    required Color base,
    required Color seed,
  }) {
    if (this == none) return null;
    final dark = brightness == Brightness.dark;
    // A tenth of a vivid hue on black is still black to the eye; a tenth on
    // cream would be a different page. The light values are half the dark
    // ones so both read as the same level of "there is something there".
    final strong = dark ? 0.14 : 0.07;
    final soft = dark ? 0.07 : 0.04;
    final Color a;
    final Color b;
    switch (this) {
      case none:
        return null;
      case aurora:
        a = const Color(0xFF2AA9A0);
        b = const Color(0xFF7C5CFF);
      case dusk:
        a = const Color(0xFFB14E8C);
        b = const Color(0xFF4A5BC4);
      case ember:
        a = const Color(0xFFD2691E);
        b = const Color(0xFFB23A2E);
    }
    Color mix(Color tint, double amount) =>
        Color.lerp(base, Color.lerp(tint, seed, 0.35), amount)!;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [mix(a, strong), mix(b, soft), base],
      stops: const [0.0, 0.55, 1.0],
    );
  }
}

/// The user's three appearance choices, as one value.
@immutable
class ThemeCustomization {
  const ThemeCustomization({
    this.palette = AppPalette.dynamic,
    this.surface = AppSurfaceStyle.automatic,
    this.backdrop = AppBackdrop.none,
  });

  final AppPalette palette;
  final AppSurfaceStyle surface;
  final AppBackdrop backdrop;

  ThemeCustomization copyWith({
    AppPalette? palette,
    AppSurfaceStyle? surface,
    AppBackdrop? backdrop,
  }) {
    return ThemeCustomization(
      palette: palette ?? this.palette,
      surface: surface ?? this.surface,
      backdrop: backdrop ?? this.backdrop,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ThemeCustomization &&
      other.palette == palette &&
      other.surface == surface &&
      other.backdrop == backdrop;

  @override
  int get hashCode => Object.hash(palette, surface, backdrop);
}

/// The resolved colours of one surface style, for one brightness.
@immutable
class AppSurfaceColors {
  const AppSurfaceColors({
    required this.scaffold,
    required this.surface,
    required this.card,
    required this.dialog,
    required this.sheet,
    required this.containerLow,
    required this.containerHigh,
    required this.containerHighest,
    required this.outline,
    required this.outlineVariant,
    required this.input,
    required this.divider,
  });

  final Color scaffold;
  final Color surface;
  final Color card;
  final Color dialog;
  final Color sheet;
  final Color containerLow;
  final Color containerHigh;
  final Color containerHighest;
  final Color outline;
  final Color outlineVariant;
  final Color input;
  final Color divider;
}

/// Resolves [style] against [brightness], with [scheme] supplying the
/// scheme-derived variant and every text role.
AppSurfaceColors resolveSurfaceColors({
  required AppSurfaceStyle style,
  required Brightness brightness,
  required ColorScheme scheme,
}) {
  final AppSurfaceStyle effective = style == AppSurfaceStyle.automatic
      ? (brightness == Brightness.dark
            ? AppSurfaceStyle.amoled
            : AppSurfaceStyle.paper)
      : style;

  if (brightness == Brightness.dark) {
    switch (effective) {
      case AppSurfaceStyle.amoled:
      case AppSurfaceStyle.automatic:
        return const AppSurfaceColors(
          scaffold: Color(0xFF000000),
          surface: Color(0xFF000000),
          card: Color(0xFF000000),
          dialog: Color(0xFF18181F),
          sheet: Color(0xFF18181F),
          containerLow: Color(0xFF0C0C11),
          containerHigh: Color(0xFF22222E),
          containerHighest: Color(0xFF2C2C36),
          outline: Color(0xFF3A3A46),
          outlineVariant: Color(0xFF22222E),
          input: Color(0xFF18181F),
          divider: Color(0xFF22222E),
        );
      case AppSurfaceStyle.midnight:
        return const AppSurfaceColors(
          scaffold: Color(0xFF070B14),
          surface: Color(0xFF070B14),
          card: Color(0xFF0D1320),
          dialog: Color(0xFF111827),
          sheet: Color(0xFF111827),
          containerLow: Color(0xFF0B111C),
          containerHigh: Color(0xFF182130),
          containerHighest: Color(0xFF1F2A3C),
          outline: Color(0xFF2C3A52),
          outlineVariant: Color(0xFF1B2436),
          input: Color(0xFF111827),
          divider: Color(0xFF1B2436),
        );
      case AppSurfaceStyle.paper:
        return const AppSurfaceColors(
          scaffold: Color(0xFF171310),
          surface: Color(0xFF171310),
          card: Color(0xFF1F1915),
          dialog: Color(0xFF241D18),
          sheet: Color(0xFF241D18),
          containerLow: Color(0xFF1B1612),
          containerHigh: Color(0xFF2A221C),
          containerHighest: Color(0xFF332A23),
          outline: Color(0xFF4A4038),
          outlineVariant: Color(0xFF332A23),
          input: Color(0xFF241D18),
          divider: Color(0xFF2A221C),
        );
      case AppSurfaceStyle.standard:
        return AppSurfaceColors(
          scaffold: scheme.surface,
          surface: scheme.surface,
          card: scheme.surfaceContainerLow,
          dialog: scheme.surfaceContainerLow,
          sheet: scheme.surfaceContainerLow,
          containerLow: scheme.surfaceContainerLowest,
          containerHigh: scheme.surfaceContainerHigh,
          containerHighest: scheme.surfaceContainerHighest,
          outline: scheme.outline,
          outlineVariant: scheme.outlineVariant,
          input: scheme.surfaceContainerHigh,
          divider: scheme.outlineVariant,
        );
    }
  }

  switch (effective) {
    case AppSurfaceStyle.amoled:
    case AppSurfaceStyle.automatic:
      return const AppSurfaceColors(
        scaffold: Color(0xFFFFFFFF),
        surface: Color(0xFFFFFFFF),
        card: Color(0xFFF6F6F8),
        dialog: Color(0xFFFFFFFF),
        sheet: Color(0xFFFFFFFF),
        containerLow: Color(0xFFF9F9FB),
        containerHigh: Color(0xFFEFEFF2),
        containerHighest: Color(0xFFE6E6EA),
        outline: Color(0xFFC7C7CF),
        outlineVariant: Color(0xFFDCDCE2),
        input: Color(0xFFEFEFF2),
        divider: Color(0xFFDCDCE2),
      );
    case AppSurfaceStyle.midnight:
      return const AppSurfaceColors(
        scaffold: Color(0xFFEDF1F7),
        surface: Color(0xFFEDF1F7),
        card: Color(0xFFF7F9FC),
        dialog: Color(0xFFFFFFFF),
        sheet: Color(0xFFFFFFFF),
        containerLow: Color(0xFFF2F5FA),
        containerHigh: Color(0xFFE2E8F2),
        containerHighest: Color(0xFFD6DEEA),
        outline: Color(0xFFA9B6C9),
        outlineVariant: Color(0xFFC3CEDE),
        input: Color(0xFFE2E8F2),
        divider: Color(0xFFC3CEDE),
      );
    case AppSurfaceStyle.paper:
      // The warm pair the light theme shipped with. Kept literal, because this
      // is what "the app as it was" means in daylight.
      return const AppSurfaceColors(
        scaffold: Color(0xFFF5F1EC),
        surface: Color(0xFFF5F1EC),
        card: Color(0xFFFAF8F5),
        dialog: Color(0xFFF5F1EC),
        sheet: Color(0xFFF5F1EC),
        containerLow: Color(0xFFF7F3EE),
        containerHigh: Color(0xFFE8E2D8),
        containerHighest: Color(0xFFE4D9C8),
        outline: Color(0xFFC9BBA6),
        outlineVariant: Color(0xFFD9C9AE),
        input: Color(0xFFE8E2D8),
        divider: Color(0xFFD9C9AE),
      );
    case AppSurfaceStyle.standard:
      return AppSurfaceColors(
        scaffold: scheme.surface,
        surface: scheme.surface,
        card: scheme.surfaceContainerLow,
        dialog: scheme.surfaceContainerHigh,
        sheet: scheme.surfaceContainerHigh,
        containerLow: scheme.surfaceContainerLowest,
        containerHigh: scheme.surfaceContainerHigh,
        containerHighest: scheme.surfaceContainerHighest,
        outline: scheme.outline,
        outlineVariant: scheme.outlineVariant,
        input: scheme.surfaceContainerHigh,
        divider: scheme.outlineVariant,
      );
  }
}

/// What the theme resolved to, for widgets that paint *behind* a transparent
/// scaffold - the ambient backdrop layer.
@immutable
class AppSurfaceTokens extends ThemeExtension<AppSurfaceTokens> {
  const AppSurfaceTokens({
    required this.style,
    required this.backdrop,
    required this.base,
  });

  final AppSurfaceStyle style;
  final AppBackdrop backdrop;

  /// The opaque colour the gradient is built from. It is also what the
  /// scaffold would be painted with if the backdrop were off.
  final Color base;

  @override
  AppSurfaceTokens copyWith({
    AppSurfaceStyle? style,
    AppBackdrop? backdrop,
    Color? base,
  }) {
    return AppSurfaceTokens(
      style: style ?? this.style,
      backdrop: backdrop ?? this.backdrop,
      base: base ?? this.base,
    );
  }

  @override
  AppSurfaceTokens lerp(covariant ThemeExtension<AppSurfaceTokens>? other, double t) {
    if (other is! AppSurfaceTokens) return this;
    return AppSurfaceTokens(
      style: t < 0.5 ? style : other.style,
      backdrop: t < 0.5 ? backdrop : other.backdrop,
      base: Color.lerp(base, other.base, t)!,
    );
  }
}
