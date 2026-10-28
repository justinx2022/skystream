import 'package:flutter/material.dart';

import '../../core/theme/app_world.dart';
import '../../core/theme/design_tokens.dart';
import 'glass_action_button.dart';
import 'glass_surface.dart';

/// A calm, centred explanation of why a collection is empty and what to do
/// about it.
///
/// Used instead of a bare sentence so an empty Downloads, an empty history or
/// a failed search all read as part of the product rather than as a gap. The
/// optional [actionLabel] is the one thing the viewer can do next; if there is
/// nothing to do, leave it out and the state stands on its own.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
    this.artwork,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// An illustration to sit above the title instead of the icon medallion.
  /// Used where the app already ships brand art (no search results).
  final Widget? artwork;

  /// Drops the icon medallion and tightens the spacing, for an empty rail that
  /// sits inside a screen that has other content.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppWorldTokens.colorsOf(context);

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (artwork != null) ...[
          artwork!,
          const SizedBox(height: AppSpace.lg),
        ] else if (!compact)
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.accent.withValues(
                alpha: colors.isDark ? 0.12 : 0.10,
              ),
              border: Border.all(color: colors.glassEdge),
            ),
            child: Icon(icon, size: 26, color: colors.accent),
          ),
        if (artwork == null && !compact) const SizedBox(height: AppSpace.lg),
        Text(
          title,
          textAlign: TextAlign.center,
          style:
              (compact
                      ? theme.textTheme.titleMedium
                      : theme.textTheme.titleLarge)
                  ?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
        ),
        if (message != null) ...[
          const SizedBox(height: AppSpace.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              message!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
                height: 1.45,
              ),
            ),
          ),
        ],
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: AppSpace.xl),
          GlassActionButton(
            label: actionLabel!,
            onPressed: onAction,
            primary: true,
          ),
        ],
      ],
    );

    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? AppSpace.md : AppSpace.xxl),
        child: compact
            ? content
            : GlassSurface(
                padding: const EdgeInsets.all(AppSpace.xxl),
                borderRadius: AppRadius.sheet,
                blurSigma: AppBlur.subtle,
                child: content,
              ),
      ),
    );
  }
}
