import 'package:flutter/material.dart';

import '../../core/theme/app_world.dart';
import '../../core/theme/design_tokens.dart';

/// The title treatment laid over artwork.
///
/// A poster is allowed to be any colour, so text on it has to bring its own
/// ground. This paints the world's scrim - fully opaque at the bottom - and
/// puts the title, an optional metadata line and an optional progress line on
/// it. The last line of text therefore always sits on the page colour, not on
/// whatever the poster happened to be.
///
/// It is a treatment, not a card: it has no tap target, no focus and no
/// gesture handling, so it can be dropped into an existing card without
/// changing how that card behaves.
class ArtworkOverlay extends StatelessWidget {
  const ArtworkOverlay({
    super.key,
    required this.title,
    this.meta,
    this.progress,
    this.buffered,
    this.alignment = Alignment.bottomLeft,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpace.md,
      AppSpace.xl,
      AppSpace.md,
      AppSpace.md,
    ),
    this.titleStyle,
    this.maxTitleLines = 2,
  });

  final String title;
  final String? meta;

  /// Watched fraction, 0..1. Null draws no line.
  final double? progress;

  /// Buffered fraction, 0..1. Only meaningful alongside [progress].
  final double? buffered;

  final Alignment alignment;
  final EdgeInsetsGeometry padding;
  final TextStyle? titleStyle;
  final int maxTitleLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppWorldTokens.colorsOf(context);
    final textStyle =
        titleStyle ??
        theme.textTheme.titleSmall?.copyWith(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
          height: 1.25,
        );

    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(gradient: colors.artworkScrim),
          child: Align(
            alignment: alignment,
            child: Padding(
              padding: padding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: maxTitleLines,
                    overflow: TextOverflow.ellipsis,
                    style: textStyle,
                  ),
                  if (meta != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      meta!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  if (progress != null) ...[
                    const SizedBox(height: AppSpace.sm),
                    ProgressLine(value: progress!, buffered: buffered),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A two-pixel watched/buffered line. Thin on purpose: it states how far in
/// the viewer is without becoming a second piece of furniture on the card.
class ProgressLine extends StatelessWidget {
  const ProgressLine({
    super.key,
    required this.value,
    this.buffered,
    this.height = 2.5,
    this.color,
  });

  final double value;
  final double? buffered;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = AppWorldTokens.colorsOf(context);
    final fraction = value.isFinite ? value.clamp(0.0, 1.0) : 0.0;
    final buffer = (buffered ?? 0).isFinite
        ? (buffered ?? 0).clamp(0.0, 1.0)
        : 0.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: colors.textPrimary.withValues(alpha: 0.16)),
            if (buffer > 0)
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: buffer,
                child: ColoredBox(
                  color: colors.textPrimary.withValues(alpha: 0.26),
                ),
              ),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fraction,
              child: ColoredBox(color: color ?? colors.accent),
            ),
          ],
        ),
      ),
    );
  }
}
