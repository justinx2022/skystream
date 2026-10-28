import 'package:flutter/material.dart';

import '../../../../core/theme/app_world.dart';
import '../../../../core/theme/design_tokens.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../shared/focus/app_focus.dart';

class SettingsGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  /// Whether the rows sit on a card of their own.
  ///
  /// True on the Settings page, where the card is what separates a group from
  /// the scaffold behind it. False inside a dialog: the card fills with the
  /// raised surface, which on a dialog's own surface reads as a box floating in
  /// a panel rather than as a group. The tiles keep their dividers either way,
  /// which is what actually groups them.
  final bool filled;

  const SettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    final world = AppWorldTokens.colorsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LayoutConstants.spacingMd,
            vertical: LayoutConstants.spacingSm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: world.textSecondary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(
            horizontal: LayoutConstants.spacingMd,
          ),
          decoration: filled
              ? BoxDecoration(
                  // Translucent warm elevated surface with fine luminous edge
                  color: world.elevated.withValues(
                    alpha: world.isDark ? 0.70 : 0.85,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(
                    color: (world.isDark ? Colors.white : Colors.black)
                        .withValues(alpha: world.isDark ? 0.08 : 0.06),
                    width: 0.75,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: world.isDark ? 0.18 : 0.04,
                      ),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                )
              : null,
          clipBehavior: filled ? Clip.antiAlias : Clip.none,
          child: Column(children: children),
        ),
      ],
    );
  }
}

class SettingsTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isLast;
  final bool isBeta;
  final FocusNode? focusNode;

  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.isLast = false,
    this.isBeta = false,
    this.focusNode,
  });

  @override
  State<SettingsTile> createState() => _SettingsTileState();
}

class _SettingsTileState extends State<SettingsTile> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final primary = AppWorldTokens.colorsOf(context).accent;
    final world = AppWorldTokens.colorsOf(context);
    final showFocus = showFocusIndicator(context, _isFocused);
    return Column(
      children: [
        Focus(
          // Passive observer — we want the inner ListTile's InkWell to remain
          // the actual focus target (it's what handles onTap when OK is
          // pressed). hasFocus on this node reflects "any descendant focused"
          // so onFocusChange still fires when the tile is reached.
          focusNode: widget.focusNode,
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (f) {
            setState(() => _isFocused = f);
            if (f) {
              // Center the focused setting row in the viewport.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final ctx = FocusManager.instance.primaryFocus?.context;
                final ro = ctx?.findRenderObject();
                if (ctx != null && ctx.mounted && ro != null) {
                  Scrollable.maybeOf(ctx)?.position.ensureVisible(
                    ro,
                    alignment: 0.5,
                    duration: const Duration(milliseconds: 380),
                    curve: Curves.fastOutSlowIn,
                  );
                }
              });
            }
          },
          child: AnimatedContainer(
            duration: AppFocus.duration,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              // A neutral wash and a neutral ring, and only for whoever is
              // driving the app without a pointer. What was here was a 22 %
              // accent fill and a 2 dp accent border that stayed on screen
              // after a tap on a phone, where nothing about the interaction
              // called for a focus indicator at all.
              color: AppFocus.rowTint(context, focused: showFocus),
              border:
                  AppFocus.border(context, focused: showFocus) ??
                  Border.all(
                    color: Colors.transparent,
                    width: AppFocus.ringWidth,
                  ),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: ListTile(
                focusColor: Colors.transparent,
                hoverColor: primary.withValues(alpha: 0.10),
                leading: Container(
                  padding: const EdgeInsets.all(LayoutConstants.spacingXs),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(widget.icon, color: primary, size: 20),
                ),
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        widget.title,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                    if (widget.isBeta) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: primary.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          "BETA",
                          style: TextStyle(
                            color: primary,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: widget.subtitle != null
                    ? Text(
                        widget.subtitle!,
                        style: TextStyle(
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      )
                    : null,
                trailing: widget.trailing != null
                    ? ExcludeFocus(
                        excluding: true,
                        child: showFocus
                            ? SwitchTheme(
                                data: SwitchThemeData(
                                  thumbIcon:
                                      WidgetStateProperty.resolveWith<Icon?>((
                                        states,
                                      ) {
                                        if (states.contains(
                                          WidgetState.selected,
                                        )) {
                                          return const Icon(
                                            Icons.check_rounded,
                                            size: 14,
                                          );
                                        } else {
                                          return const Icon(
                                            Icons.close_rounded,
                                            size: 14,
                                          );
                                        }
                                      }),
                                ),
                                child: widget.trailing!,
                              )
                            : widget.trailing!,
                      )
                    : const Icon(Icons.chevron_right_rounded, size: 20),
                onTap: widget.onTap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ),
        if (!widget.isLast && !showFocus)
          Divider(height: 1, indent: 56, endIndent: 16, color: world.divider),
      ],
    );
  }
}
