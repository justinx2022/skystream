import 'package:flutter/material.dart';

import '../../core/theme/app_world.dart';
import '../../core/theme/design_tokens.dart';
import '../focus/app_focus.dart';
import 'glass_surface.dart';

/// The primary action shape: a glass capsule with an icon and a label.
///
/// Used where a Material button would put a solid accent slab over artwork.
/// Two variants: [primary] paints the world's accent (one per screen at most -
/// Play, typically), everything else is glass.
///
/// Focus is the app's existing language, unchanged: a neutral ring drawn
/// outside the shape, plus the lift. It is composed from [FocusRing] rather
/// than reimplemented, so a D-pad sees the same affordance it sees on a card.
class GlassActionButton extends StatefulWidget {
  const GlassActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.primary = false,
    this.expanded = false,
    this.tooltip,
    this.autofocus = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  /// The world accent fill. Reserve for the one action a screen is about.
  final bool primary;

  final bool expanded;
  final String? tooltip;
  final bool autofocus;

  @override
  State<GlassActionButton> createState() => _GlassActionButtonState();
}

class _GlassActionButtonState extends State<GlassActionButton> {
  final FocusNode _node = FocusNode(debugLabel: 'GlassActionButton');
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocus);
  }

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    _node.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!mounted) return;
    setState(() => _focused = _node.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppWorldTokens.colorsOf(context);
    final enabled = widget.onPressed != null;
    final foreground = widget.primary ? colors.onAccent : colors.textPrimary;
    final radius = BorderRadius.circular(AppRadius.sm);

    // One label, not two. The Semantics node below names the action; without
    // this the InkWell's own label would be merged in and a screen reader (or
    // a television's voice guide) would say "Play, Play".
    final content = ExcludeSemantics(
      child: Row(
        mainAxisSize: widget.expanded ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 18, color: foreground),
            const SizedBox(width: AppSpace.sm),
          ],
          Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );

    final Widget base = widget.primary
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: colors.accent,
              borderRadius: radius,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.lg,
                vertical: AppSpace.md,
              ),
              child: content,
            ),
          )
        : GlassSurface(
            borderRadius: radius,
            blurSigma: AppBlur.subtle,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.lg,
              vertical: AppSpace.md,
            ),
            fill: colors.elevated.withValues(
              alpha: colors.isDark ? 0.72 : 0.86,
            ),
            child: content,
          );

    Widget button = Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          focusNode: _node,
          autofocus: widget.autofocus,
          onTap: widget.onPressed,
          borderRadius: radius,
          focusColor: Colors.transparent,
          hoverColor: colors.textPrimary.withValues(alpha: 0.04),
          splashColor: colors.accent.withValues(alpha: 0.16),
          child: widget.expanded
              ? SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: Center(child: base),
                )
              : SizedBox(
                  height: 44,
                  child: Center(widthFactor: 1, child: base),
                ),
        ),
      ),
    );

    button = FocusRing(
      focused: _focused,
      borderRadius: radius,
      child: Opacity(opacity: enabled ? 1 : 0.45, child: button),
    );

    if (widget.tooltip == null) return button;
    return Tooltip(message: widget.tooltip!, child: button);
  }
}
