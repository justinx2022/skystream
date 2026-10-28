import 'package:flutter/material.dart';

/// The two visual worlds the app is divided into.
///
/// SKY is discovery: Home, Search, Explore and every title page. GROUND is the
/// viewer's own life: Library, downloads, bookmarks, history and the Control
/// Room. The split is a *surface* split, not a second app - both worlds share
/// the same routing, cards, focus language and type ramp, and only the colours
/// underneath and the temperature of the glass change.
///
/// The world is derived from the branch that is on screen, so a viewer never
/// picks it and it can never disagree with where they are. The four surfaces
/// pushed above the shell (details, view-all) inherit SKY, which is what they
/// are.
enum AppWorld {
  sky,
  ground;

  /// Sky owns discovery: the three discovery branches. Ground owns the two
  /// personal ones.
  ///
  /// Index order is `StatefulShellRoute` branch order - home, search, explore,
  /// library, settings - so this has to move with `kShellBranchCount` in
  /// `app_router.dart` if a branch is ever added or reordered.
  static AppWorld forBranch(int index) => index >= 3 ? ground : sky;
}

/// One world's colours, for one brightness.
///
/// These are the pack's tokens, with daylight counterparts that are derived
/// rather than invented: a light world keeps the same hue family and moves the
/// contrast the other way, so switching the app to light does not silently
/// turn GROUND cool again.
@immutable
class AppWorldColors {
  const AppWorldColors({
    required this.background,
    required this.elevated,
    required this.elevatedHigh,
    required this.accent,
    required this.onAccent,
    required this.textPrimary,
    required this.textSecondary,
    required this.divider,
  });

  /// The opaque page colour. Everything translucent is composited against it.
  final Color background;

  /// The first raised surface: cards, panels, sheets.
  final Color elevated;

  /// The second raised surface: chips, pressed rows, the top of a glass panel.
  final Color elevatedHigh;

  /// The world's chrome accent - section rules, the active destination, the
  /// progress line. A viewer's own palette still owns buttons and selection;
  /// this is what makes SKY read cool and GROUND read warm before anything is
  /// pressed.
  final Color accent;

  final Color onAccent;
  final Color textPrimary;
  final Color textSecondary;
  final Color divider;

  Brightness get brightness =>
      textPrimary.computeLuminance() > background.computeLuminance()
      ? Brightness.dark
      : Brightness.light;

  bool get isDark => brightness == Brightness.dark;

  /// The fill behind a glass panel: the raised colour, translucent enough that
  /// the page's own gradient and artwork show through, opaque enough that text
  /// on it stays readable.
  Color get glassFill => elevated.withValues(alpha: isDark ? 0.62 : 0.74);

  /// The hairline that gives glass its edge. One bright side, no full outline:
  /// an even ring reads as a border, a top edge reads as a lit pane.
  Color get glassEdge => (isDark ? Colors.white : Colors.black).withValues(
    alpha: isDark ? 0.14 : 0.08,
  );

  /// A scrim for text laid over artwork. Opaque at the bottom so the last line
  /// of a title always sits on the page colour rather than on a poster.
  LinearGradient get artworkScrim => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      background.withValues(alpha: 0.0),
      background.withValues(alpha: 0.35),
      background.withValues(alpha: 0.82),
      background,
    ],
    stops: const [0.0, 0.55, 0.86, 1.0],
  );

  /// The page behind everything: a shallow vertical wash built from the world's
  /// own accent. Two stops, both opaque, so contrast is a property of the
  /// token and never of what happens to be behind the app.
  LinearGradient get pageGradient {
    final tint = Color.alphaBlend(
      accent.withValues(alpha: isDark ? 0.07 : 0.10),
      background,
    );
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [tint, background],
      stops: const [0.0, 0.62],
    );
  }
}

/// SKY at night: the pack's midnight-blue tokens, verbatim.
const AppWorldColors kSkyDark = AppWorldColors(
  background: Color(0xFF0B1220),
  elevated: Color(0xFF172338),
  elevatedHigh: Color(0xFF1F2E47),
  accent: Color(0xFFA9C2E4),
  onAccent: Color(0xFF0B1220),
  textPrimary: Color(0xFFF4F6FA),
  textSecondary: Color(0xFFAAB7C9),
  divider: Color(0xFF2A384D),
);

/// SKY in daylight: the same family, inverted for AA on paper.
const AppWorldColors kSkyLight = AppWorldColors(
  background: Color(0xFFF3F7FC),
  elevated: Color(0xFFFFFFFF),
  elevatedHigh: Color(0xFFE6EEF8),
  accent: Color(0xFF3C6FA8),
  onAccent: Color(0xFFFFFFFF),
  textPrimary: Color(0xFF0B1220),
  textSecondary: Color(0xFF53657B),
  divider: Color(0xFFD3DEEC),
);

/// GROUND at night: warm graphite, champagne accent.
const AppWorldColors kGroundDark = AppWorldColors(
  background: Color(0xFF151614),
  elevated: Color(0xFF232320),
  elevatedHigh: Color(0xFF2D2D29),
  accent: Color(0xFFC4A477),
  onAccent: Color(0xFF151614),
  textPrimary: Color(0xFFF1EDE5),
  textSecondary: Color(0xFFAAA69D),
  divider: Color(0xFF393832),
);

/// GROUND in daylight: warm paper, not a cool grey.
const AppWorldColors kGroundLight = AppWorldColors(
  background: Color(0xFFF6F1E8),
  elevated: Color(0xFFFFFDF8),
  elevatedHigh: Color(0xFFEDE4D6),
  accent: Color(0xFF8A6A3B),
  onAccent: Color(0xFFFFFFFF),
  textPrimary: Color(0xFF1A1917),
  textSecondary: Color(0xFF665F54),
  divider: Color(0xFFDFD5C4),
);

extension AppWorldPalette on AppWorld {
  AppWorldColors colorsFor(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    switch (this) {
      case AppWorld.sky:
        return dark ? kSkyDark : kSkyLight;
      case AppWorld.ground:
        return dark ? kGroundDark : kGroundLight;
    }
  }
}

/// The resolved world, as a [ThemeExtension], so a widget can read it from a
/// theme alone - including the themes tests build by hand.
@immutable
class AppWorldTokens extends ThemeExtension<AppWorldTokens> {
  const AppWorldTokens({required this.world, required this.colors});

  final AppWorld world;
  final AppWorldColors colors;

  static AppWorldTokens? maybeOf(BuildContext context) =>
      Theme.of(context).extension<AppWorldTokens>();

  /// The world's colours, falling back to the theme's own scheme when the
  /// extension is absent (a widget test pumping a bare [MaterialApp]).
  static AppWorldColors colorsOf(BuildContext context) {
    final tokens = Theme.of(context).extension<AppWorldTokens>();
    if (tokens != null) return tokens.colors;
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return dark ? kSkyDark : kSkyLight;
  }

  @override
  AppWorldTokens copyWith({AppWorld? world, AppWorldColors? colors}) {
    return AppWorldTokens(
      world: world ?? this.world,
      colors: colors ?? this.colors,
    );
  }

  @override
  AppWorldTokens lerp(
    covariant ThemeExtension<AppWorldTokens>? other,
    double t,
  ) {
    if (other is! AppWorldTokens) return this;
    return t < 0.5 ? this : other;
  }
}
