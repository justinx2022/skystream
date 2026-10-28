import 'package:flutter/material.dart';

import 'app_world.dart';
import 'theme_presets.dart';

/// Paints the page colour - or the chosen ambient gradient - behind the shell.
///
/// Installed by `AppScaffold`, once, around the branch navigator. The tab
/// screens already lay themselves out on a transparent [Scaffold], so this is
/// what they are transparent *onto*: a single opaque base, washed with the
/// world's own gradient and, if the viewer picked one, their ambient backdrop
/// on top of that.
///
/// The world wash is shallow on purpose - a tinted top that settles into the
/// page colour - so it reads as depth rather than as decoration, and it is two
/// opaque stops rather than a blur, so it costs a gradient fill and nothing
/// else.
///
/// Deliberately not app-wide. Routes pushed above the shell - details, the
/// player - keep the theme's own opaque scaffold colour, so the fade
/// compositions inside them (the details hero blending into the page) keep
/// working and video is never drawn over a gradient.
class AppBackdropLayer extends StatelessWidget {
  const AppBackdropLayer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<AppSurfaceTokens>();
    // A theme without the extension is one a test built by hand; its scaffold
    // colour is the only honest answer.
    final base = tokens?.base ?? theme.scaffoldBackgroundColor;
    final world = theme.extension<AppWorldTokens>();
    final ambient = tokens == null || tokens.backdrop == AppBackdrop.none
        ? null
        : tokens.backdrop.gradientFor(
            brightness: theme.brightness,
            base: base,
            seed: theme.colorScheme.primary,
          );
    // The world wash sits underneath an ambient backdrop, so choosing one
    // deepens the page instead of replacing its identity.
    final gradient =
        ambient ??
        world?.colors.pageGradient ??
        LinearGradient(colors: [base, base]);

    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: child,
    );
  }
}
