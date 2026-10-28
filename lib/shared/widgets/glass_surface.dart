import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_world.dart';
import '../../core/theme/design_tokens.dart';

/// A translucent, tinted panel with one lit edge and a soft shadow.
///
/// This is the app's only glass. Everything that wants a translucent surface -
/// the sidebar dock, the phone navigation pill, player sheets, dialogs, the
/// details action bar - composes this rather than reaching for its own
/// [BackdropFilter], so the blur radius, tint, edge and radius cannot drift
/// apart, and so there is exactly one place to turn blur off if a low-end
/// device needs it.
///
/// Rules the pack sets, enforced here:
///  * glass is chrome, not content: never wrap a scrolling list or a card grid
///    in this, and never more than one blur layer deep;
///  * the tint comes from the active world, so a panel on GROUND is warm and a
///    panel on SKY is cool without the caller naming a colour;
///  * the edge is a hairline, not a border, and it is the same bright on every
///    panel;
///  * [blurSigma] of zero paints the same panel without a saveLayer, for
///    surfaces where the cost matters more than the depth.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.lg),
    this.borderRadius,
    this.blurSigma = AppBlur.chrome,
    this.fill,
    this.border,
    this.shadow = true,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;
  final double blurSigma;

  /// Overrides the world's glass fill. For the rare panel that needs to be
  /// darker or lighter than glass - a player scrim, for instance.
  final Color? fill;

  /// Overrides the hairline. Null keeps the world's lit edge.
  final BoxBorder? border;

  final bool shadow;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final colors = AppWorldTokens.colorsOf(context);
    final radius = borderRadius ?? AppRadius.panel;
    final reduce = AppMotion.reduced(context);

    Widget panel = DecoratedBox(
      decoration: BoxDecoration(
        color: fill ?? colors.glassFill,
        borderRadius: radius,
        border: border ?? Border.all(color: colors.glassEdge, width: 1),
      ),
      child: Padding(padding: padding, child: child),
    );

    if (blurSigma > 0 && !reduce) {
      panel = ClipRRect(
        borderRadius: radius,
        clipBehavior: clipBehavior,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: panel,
        ),
      );
    } else {
      panel = ClipRRect(
        borderRadius: radius,
        clipBehavior: clipBehavior,
        child: panel,
      );
    }

    if (!shadow) return panel;
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: colors.isDark ? 0.34 : 0.10),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: panel,
    );
  }
}

/// A glass panel that fills the width of its parent. The settings screens and
/// the details action bar use this shape repeatedly.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpace.lg,
      vertical: AppSpace.md,
    ),
    this.borderRadius,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      padding: padding,
      borderRadius: borderRadius ?? AppRadius.panel,
      blurSigma: AppBlur.subtle,
      child: child,
    );
  }
}
