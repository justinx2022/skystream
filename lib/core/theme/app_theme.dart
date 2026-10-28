import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../shared/focus/app_focus.dart';
import 'app_world.dart';
import 'theme_presets.dart';

class AppTheme {
  /// The bundled application type family.
  ///
  /// The whole ramp used to come from the google_fonts package, which
  /// downloads the .ttf from fonts.gstatic.com on first launch: with no
  /// network the app rendered in a fallback face, and every first launch
  /// reached out to a third-party server before the user had done anything.
  /// The six weights the app uses are now declared in pubspec.yaml under
  /// `fonts:`.
  static const String fontFamily = 'Outfit';

  /// Fonts that ship as bundle assets are not registered with Flutter's
  /// licence registry the way a package's LICENSE file is, so the SIL Open
  /// Font License text that travels with Outfit is registered here. The
  /// package it replaced did the equivalent at runtime; the in-app licence
  /// page keeps showing the entry without it.
  static bool _fontLicenceRegistered = false;

  static void _registerFontLicence() {
    if (_fontLicenceRegistered) return;
    _fontLicenceRegistered = true;
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(const <String>[
        fontFamily,
      ], await rootBundle.loadString('assets/fonts/OFL.txt'));
    });
  }

  // Premium Colors. Kept because the SnackBar is the one surface the scheme
  // does not describe, and the dark defaults still name them.
  static const Color background = Color(0xFF0F0F13); // Deep dark blue-grey
  static const Color surface = Color(0xFF18181F);
  static const Color surfaceHighlight = Color(0xFF22222E);
  static const Color primary = Color(0xFF448AFF); // Blue Accent
  static const Color primaryVariant = Color(0xFF2962FF); // Blue Accent Darker
  static const Color secondary = Color(0xFF10B981); // Emerald
  static const Color error = Color(0xFFEF4444);
  static const Color onSurface = Color(0xFFE5E7EB);
  static const Color textSecondary = Color(0xFF9CA3AF);

  // Light Theme Colors
  static const Color lightBackground = Color(0xFFF5F1EC); // primary surface
  static const Color lightSurface = Color(0xFFFAF8F5); // surfaceContainerLowest
  static const Color lightSurfaceHighlight = Color(
    0xFFE8E2D8,
  ); // surfaceContainerHigh
  static const Color lightTextPrimary = Color(0xFF2C2521); // onSurface
  static const Color lightTextSecondary = Color(0xFF5C5C5C); // onSurfaceVariant
  static const Color lightCoral = Color(0xFFC63523); // Coral Accent

  static SnackBarThemeData snackBarThemeFor(ColorScheme colorScheme) {
    final isDark = colorScheme.brightness == Brightness.dark;
    return SnackBarThemeData(
      backgroundColor: isDark ? surface : colorScheme.surfaceContainerHigh,
      contentTextStyle: TextStyle(
        color: isDark ? onSurface : colorScheme.onSurface,
      ),
      actionTextColor: colorScheme.primary,
    );
  }

  /// Every Material control's focus indicator, in one place.
  ///
  /// Before this existed, a [FilledButton] in this app had no focus state that
  /// could be seen at all: Material 3 answers focus with an overlay of about
  /// a tenth of the foreground colour, which on an accent-filled pill is
  /// invisible on a phone and simply not there from a sofa. On a television
  /// that is not a cosmetic problem - a fresh install sends the viewer to
  /// Extensions -> Repositories -> Add Repository, and with nothing on screen
  /// telling them which button the remote is pointing at, the app reads as
  /// locked. This is the fix for that, and because it is a theme every button,
  /// tab and list row in the app gets it without being touched.
  ///
  /// Material reports [WidgetState.focused] for any button that holds focus,
  /// and a button can hold it under a thumb - autofocused for a remote, or
  /// handed focus back as a dialog closes - so the ring also asks
  /// [FocusVisibility], the one rule every focus indicator in the app follows.
  /// See `shared/focus/app_focus.dart`.
  static FilledButtonThemeData _filledButtonTheme(ColorScheme cs) =>
      FilledButtonThemeData(style: ButtonStyle(side: AppFocus.buttonSide(cs)));

  static ElevatedButtonThemeData _elevatedButtonTheme(ColorScheme cs) =>
      ElevatedButtonThemeData(
        style: ButtonStyle(side: AppFocus.buttonSide(cs)),
      );

  static TextButtonThemeData _textButtonTheme(ColorScheme cs) =>
      TextButtonThemeData(style: ButtonStyle(side: AppFocus.buttonSide(cs)));

  /// An outlined button already wears a border, so its resolver has to hand
  /// back that border in every state but focused.
  static OutlinedButtonThemeData _outlinedButtonTheme(ColorScheme cs) =>
      OutlinedButtonThemeData(
        style: ButtonStyle(
          side: AppFocus.buttonSide(
            cs,
            unfocused: BorderSide(color: cs.outline),
          ),
        ),
      );

  static IconButtonThemeData _iconButtonTheme(ColorScheme cs) =>
      IconButtonThemeData(style: ButtonStyle(side: AppFocus.buttonSide(cs)));

  /// Tabs and segmented buttons are ink responses rather than shaped buttons,
  /// so they take the wash instead of the ring.
  static TabBarThemeData _tabBarTheme(ColorScheme cs) =>
      TabBarThemeData(overlayColor: AppFocus.overlay(cs));

  static ThemeData createDarkTheme(
    ColorScheme? dynamicScheme, {
    AppPalette palette = AppPalette.dynamic,
    AppSurfaceStyle surface = AppSurfaceStyle.automatic,
    AppBackdrop backdrop = AppBackdrop.none,
    AppWorld world = AppWorld.sky,
  }) {
    return _build(
      brightness: Brightness.dark,
      dynamicScheme: dynamicScheme,
      palette: palette,
      surfaceStyle: surface,
      backdrop: backdrop,
      world: world,
    );
  }

  static ThemeData createLightTheme(
    ColorScheme? dynamicScheme, {
    AppPalette palette = AppPalette.dynamic,
    AppSurfaceStyle surface = AppSurfaceStyle.automatic,
    AppBackdrop backdrop = AppBackdrop.none,
    AppWorld world = AppWorld.sky,
  }) {
    return _build(
      brightness: Brightness.light,
      dynamicScheme: dynamicScheme,
      palette: palette,
      surfaceStyle: surface,
      backdrop: backdrop,
      world: world,
    );
  }

  /// The scheme every role is read from.
  ///
  /// The wallpaper is passed straight through when the palette is dynamic,
  /// because that scheme is the platform's answer and re-seeding it would
  /// only lose what it said. With no wallpaper - a desktop, a TV, a phone with
  /// dynamic colour off - dynamic now falls back to the *world's* accent:
  /// SKY's cool blue-white at night, GROUND's champagne. That is the one place
  /// the pack's accent tokens become the app's primary; a viewer who picks a
  /// palette, or a phone that reports one, still wins.
  static ColorScheme _schemeFor({
    required Brightness brightness,
    required ColorScheme? dynamicScheme,
    required AppPalette palette,
    required AppWorldColors world,
  }) {
    if (palette == AppPalette.dynamic) {
      if (dynamicScheme != null) {
        return dynamicScheme.copyWith(brightness: brightness);
      }
      return ColorScheme.fromSeed(
        seedColor: world.accent,
        brightness: brightness,
      ).copyWith(primary: world.accent, onPrimary: world.onAccent);
    }
    return ColorScheme.fromSeed(
      seedColor: palette.seed ?? primary,
      brightness: brightness,
    );
  }

  /// The type ramp, recoloured for [world].
  ///
  /// Only used when the world owns the text roles - the default palette with
  /// no wallpaper. An explicit palette keeps the scheme's own tinted type, as
  /// it always has.
  static TextTheme _worldTextTheme(TextTheme base, AppWorldColors world) {
    TextStyle? warm(TextStyle? style) =>
        style?.copyWith(color: world.textPrimary);
    TextStyle? cool(TextStyle? style) =>
        style?.copyWith(color: world.textSecondary);
    return base.copyWith(
      displayLarge: warm(base.displayLarge),
      displayMedium: warm(base.displayMedium),
      displaySmall: warm(base.displaySmall),
      headlineLarge: warm(base.headlineLarge),
      headlineMedium: warm(base.headlineMedium),
      headlineSmall: warm(base.headlineSmall),
      titleLarge: warm(base.titleLarge),
      titleMedium: warm(base.titleMedium),
      titleSmall: warm(base.titleSmall),
      bodyLarge: warm(base.bodyLarge),
      bodyMedium: cool(base.bodyMedium),
      bodySmall: cool(base.bodySmall),
      labelLarge: warm(base.labelLarge),
      labelMedium: cool(base.labelMedium),
      labelSmall: cool(base.labelSmall),
    );
  }

  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme? dynamicScheme,
    required AppPalette palette,
    required AppSurfaceStyle surfaceStyle,
    required AppBackdrop backdrop,
    required AppWorld world,
  }) {
    _registerFontLicence();
    final bool isDark = brightness == Brightness.dark;
    final worldColors = world.colorsFor(brightness);
    final ownsText = palette == AppPalette.dynamic && dynamicScheme == null;
    final baseScheme = _schemeFor(
      brightness: brightness,
      dynamicScheme: dynamicScheme,
      palette: palette,
      world: worldColors,
    );
    final surfaces = resolveSurfaceColors(
      style: surfaceStyle,
      brightness: brightness,
      scheme: baseScheme,
      world: worldColors,
    );

    // The surface roles move to the chosen surface style; every text role
    // stays the scheme's, which is what makes a palette change tint the type
    // and not only the buttons - unless the world owns the text roles, in
    // which case the pack's neutral ramp is what the viewer reads.
    final colorScheme = baseScheme.copyWith(
      surface: surfaces.surface,
      surfaceContainerLowest: surfaces.containerLow,
      surfaceContainerLow: surfaces.containerLow,
      surfaceContainer: surfaces.surface,
      surfaceContainerHigh: surfaces.containerHigh,
      surfaceContainerHighest: surfaces.containerHighest,
      surfaceDim: surfaces.surface,
      surfaceBright: surfaces.containerHigh,
      outline: surfaces.outline,
      outlineVariant: surfaces.outlineVariant,
      onSurface: ownsText ? worldColors.textPrimary : baseScheme.onSurface,
      onSurfaceVariant: ownsText
          ? worldColors.textSecondary
          : baseScheme.onSurfaceVariant,
    );

    final baseTextTheme =
        ThemeData(brightness: brightness, colorScheme: colorScheme).textTheme
            .apply(fontFamily: fontFamily)
            .copyWith(
              displayLarge: TextStyle(
                fontFamily: fontFamily,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.8,
                height: 1.1,
                color: colorScheme.onSurface,
              ),
              displayMedium: TextStyle(
                fontFamily: fontFamily,
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
                height: 1.12,
                color: colorScheme.onSurface,
              ),
              displaySmall: TextStyle(
                fontFamily: fontFamily,
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                height: 1.15,
                color: colorScheme.onSurface,
              ),
              headlineMedium: TextStyle(
                fontFamily: fontFamily,
                fontSize: 24,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
                color: colorScheme.onSurface,
              ),
              titleLarge: TextStyle(
                fontFamily: fontFamily,
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
              titleMedium: TextStyle(
                fontFamily: fontFamily,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
              bodyLarge: TextStyle(
                fontFamily: fontFamily,
                fontSize: 16,
                color: colorScheme.onSurface,
              ),
              bodyMedium: TextStyle(
                fontFamily: fontFamily,
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
              // Full-strength onSurfaceVariant, never a fraction of it. The old
              // light literal at 80% measured 3.81:1 and failed AA; the scheme
              // role at full strength clears every surface this theme paints.
              bodySmall: TextStyle(
                fontFamily: fontFamily,
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
              labelLarge: TextStyle(
                fontFamily: fontFamily,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
                color: colorScheme.onSurface,
              ),
            );

    final textTheme = ownsText
        ? _worldTextTheme(baseTextTheme, worldColors)
        : baseTextTheme;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: fontFamily,
      colorScheme: colorScheme,
      textTheme: textTheme,
      // The opaque base every screen paints on. The ambient backdrop is drawn
      // *inside the shell*, behind its transparent tab scaffolds (see
      // `AppBackdropLayer`), so the scaffold colour stays honest here: pushed
      // routes, dialogs and every widget that composites with this colour -
      // the details hero's fade into the page, for one - keep an opaque answer.
      scaffoldBackgroundColor: surfaces.scaffold,
      extensions: <ThemeExtension<dynamic>>[
        AppSurfaceTokens(
          style: surfaceStyle,
          backdrop: backdrop,
          base: surfaces.scaffold,
        ),
        AppWorldTokens(world: world, colors: worldColors),
      ],

      dialogTheme: DialogThemeData(
        backgroundColor: surfaces.dialog,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaces.sheet,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: surfaces.sheet,
      ),
      cardTheme: CardThemeData(
        color: surfaces.card,
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 0 : 1,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),

      appBarTheme: AppBarTheme(
        // Transparent so a shell backdrop reads behind the bar too. On a route
        // pushed above the shell the scaffold underneath is opaque, so the bar
        // still shows exactly the page colour it always did.
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
        titleTextStyle: TextStyle(
          color: colorScheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          fontFamily: fontFamily,
        ),
      ),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: surfaces.scaffold,
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        elevation: isDark ? 0 : 8,
        showSelectedLabels: false,
        showUnselectedLabels: false,
        landscapeLayout: BottomNavigationBarLandscapeLayout.spread,
      ),

      // Keep SnackBars consistent with the application instead of Material's
      // default inverse (light) surface.
      snackBarTheme: snackBarThemeFor(colorScheme),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaces.input,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(isDark ? 16 : 12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(isDark ? 16 : 12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(isDark ? 16 : 12),
          borderSide: BorderSide(
            color: colorScheme.primary,
            width: isDark ? 2 : 1.5,
          ),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: isDark ? 20 : 16,
          vertical: isDark ? 16 : 14,
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: surfaces.containerHigh,
        disabledColor: colorScheme.onSurface.withValues(alpha: 0.12),
        selectedColor: colorScheme.primary.withValues(alpha: 0.15),
        secondarySelectedColor: colorScheme.primary.withValues(alpha: 0.15),
        labelStyle: TextStyle(color: colorScheme.onSurface),
        secondaryLabelStyle: TextStyle(color: colorScheme.primary),
        checkmarkColor: colorScheme.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide.none,
        ),
      ),

      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith<Icon?>((states) {
          if ((states.contains(WidgetState.focused) &&
                  FocusVisibility.visible) ||
              states.contains(WidgetState.hovered)) {
            if (states.contains(WidgetState.selected)) {
              return const Icon(Icons.check_rounded, size: 14);
            } else {
              return const Icon(Icons.close_rounded, size: 14);
            }
          }
          return null;
        }),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.primary.withValues(alpha: 0.24),
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.12),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),

      splashColor: colorScheme.primary.withValues(alpha: 0.1),
      hoverColor: colorScheme.primary.withValues(alpha: 0.04),
      highlightColor: colorScheme.primary.withValues(alpha: 0.05),

      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colorScheme.primary,
        selectionColor: colorScheme.primary.withValues(alpha: 0.3),
        selectionHandleColor: colorScheme.primary,
      ),

      dividerColor: surfaces.divider,
      dividerTheme: DividerThemeData(
        thickness: 1,
        space: 1,
        color: surfaces.divider,
      ),

      // One focus indicator for every Material control. See
      // [_filledButtonTheme] for why this is a theme and not a widget.
      filledButtonTheme: _filledButtonTheme(colorScheme),
      elevatedButtonTheme: _elevatedButtonTheme(colorScheme),
      textButtonTheme: _textButtonTheme(colorScheme),
      outlinedButtonTheme: _outlinedButtonTheme(colorScheme),
      iconButtonTheme: _iconButtonTheme(colorScheme),
      tabBarTheme: _tabBarTheme(colorScheme),
      // Every bare [InkWell] and [ListTile] in the app reads this one, so a
      // row that is not a button still shows where the remote is.
      focusColor: colorScheme.onSurface.withValues(alpha: 0.16),
    );
  }
}
