import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../storage/settings_repository.dart';
import 'theme_presets.dart';

part 'theme_provider.g.dart';

@Riverpod(keepAlive: true)
class AppThemeMode extends _$AppThemeMode {
  late SettingsRepository _repository;

  @override
  ThemeMode build() {
    _repository = ref.watch(settingsRepositoryProvider);
    final saved = _repository.getThemeMode();
    // Dark is the app's default, not a per-device guess. This used to branch
    // on [deviceProfileProvider] - dark while it was still resolving, dark on
    // a television, system everywhere else - which meant the splash, which is
    // dark, handed over to a white first frame on a light-themed phone, and
    // the answer changed halfway through boot as the profile arrived.
    // System is still one click away in Settings; it is just no longer what
    // you get without asking.
    if (saved == null) return ThemeMode.dark;
    return _getThemeMode(saved);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    await _repository.saveThemeMode(mode.name);
  }

  ThemeMode _getThemeMode(String mode) {
    switch (mode) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      // 'dark', and anything no release ever wrote. Storage outlives
      // downgrades and hand-editing, so an unrecognised value is reachable; it
      // says no more than an absent one does, and lands in the same place.
      case 'dark':
      default:
        return ThemeMode.dark;
    }
  }
}

/// The three appearance choices that sit alongside light/dark: which palette
/// the Material scheme is generated from, what the app is painted on, and
/// whether an ambient gradient sits behind it.
///
/// A plain [NotifierProvider] rather than codegen: `theme_provider.g.dart` is
/// produced at build time, and this is small enough that a generated class buys
/// nothing.
final themeCustomizationProvider =
    NotifierProvider<ThemeCustomizationController, ThemeCustomization>(
      ThemeCustomizationController.new,
    );

class ThemeCustomizationController extends Notifier<ThemeCustomization> {
  late SettingsRepository _repository;

  @override
  ThemeCustomization build() {
    _repository = ref.watch(settingsRepositoryProvider);
    // `fromStorage` maps unknown values - a name a newer build wrote, or a
    // hand-edited box - back to today's defaults, so nothing here can leave the
    // app with no theme.
    return ThemeCustomization(
      palette: AppPalette.fromStorage(_repository.getThemePalette()),
      surface: AppSurfaceStyle.fromStorage(_repository.getThemeSurface()),
      backdrop: AppBackdrop.fromStorage(_repository.getThemeBackdrop()),
    );
  }

  Future<void> setPalette(AppPalette palette) async {
    if (palette == state.palette) return;
    state = state.copyWith(palette: palette);
    await _repository.saveThemePalette(palette.name);
  }

  Future<void> setSurface(AppSurfaceStyle surface) async {
    if (surface == state.surface) return;
    state = state.copyWith(surface: surface);
    await _repository.saveThemeSurface(surface.name);
  }

  Future<void> setBackdrop(AppBackdrop backdrop) async {
    if (backdrop == state.backdrop) return;
    state = state.copyWith(backdrop: backdrop);
    await _repository.saveThemeBackdrop(backdrop.name);
  }
}
