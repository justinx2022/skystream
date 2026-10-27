import 'package:flutter/material.dart';

import 'theme_presets.dart';

/// Paints the page colour - or the chosen ambient gradient - behind the shell.
///
/// Installed by `AppScaffold`, once, around the branch navigator. The tab
/// screens already lay themselves out on a transparent [Scaffold], so this is
/// what they are transparent *onto*: a single opaque base, optionally washed
/// with the backdrop the viewer picked.
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
    final gradient = tokens == null || tokens.backdrop == AppBackdrop.none
        ? null
        : tokens.backdrop.gradientFor(
            brightness: theme.brightness,
            base: base,
            seed: theme.colorScheme.primary,
          );

    return DecoratedBox(
      decoration: gradient == null
          ? BoxDecoration(color: base)
          : BoxDecoration(gradient: gradient),
      child: child,
    );
  }
}
