import 'package:flutter/material.dart';

import '../../core/theme/app_world.dart';
import '../../core/theme/design_tokens.dart';
import '../focus/app_focus.dart';

/// The heading above a rail, a group of settings or a results section.
///
/// One component so the vertical rhythm is the same everywhere: a short accent
/// rule, the title, an optional subtitle, and an optional trailing action
/// aligned to the baseline. The rule is the world's accent - cool on SKY, warm
/// on GROUND - which is where the two worlds are most visible without shouting.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.padding = EdgeInsets.zero,
    this.compact = false,
    this.showRule = true,
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final EdgeInsetsGeometry padding;

  /// Tightens the title for a nested group (inside a panel, or under a hero).
  final bool compact;

  final bool showRule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppWorldTokens.colorsOf(context);
    final titleStyle =
        (compact ? theme.textTheme.titleMedium : theme.textTheme.titleLarge)
            ?.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            );

    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showRule) const SectionRule(),
                Semantics(
                  header: true,
                  child: Text(title, style: titleStyle, maxLines: 2),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: AppSpace.md), action!],
        ],
      ),
    );
  }
}

/// A "See all" style text action that sits beside a [SectionHeader].
///
/// Deliberately small and unadorned: the rail it belongs to is the content,
/// and the link should not compete with it. It is still a real focus target -
/// on a television this is reachable with the D-pad, and an unringed link
/// would be an invisible stop.
class SectionHeaderAction extends StatefulWidget {
  const SectionHeaderAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.chevron_right_rounded,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  State<SectionHeaderAction> createState() => _SectionHeaderActionState();
}

class _SectionHeaderActionState extends State<SectionHeaderAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppWorldTokens.colorsOf(context);
    final radius = BorderRadius.circular(AppRadius.xs);
    return Semantics(
      button: true,
      label: widget.label,
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: FocusRing(
          focused: _focused,
          borderRadius: radius,
          shadow: false,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: radius,
            focusColor: Colors.transparent,
            hoverColor: colors.textPrimary.withValues(alpha: 0.06),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.sm,
                vertical: AppSpace.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: Text(
                      widget.label,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (widget.icon != null)
                    Icon(widget.icon, size: 16, color: colors.textSecondary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
