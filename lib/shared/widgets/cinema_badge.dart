import 'package:flutter/material.dart';
import '../../core/theme/app_world.dart';

/// A refined micro glass pill for metadata badges (4K, HDR, Rating, Duration, Year).
/// Follows Apple-level restrained cinema typography and luminous rim lighting.
class CinemaBadge extends StatelessWidget {
  const CinemaBadge({
    super.key,
    required this.label,
    this.icon,
    this.isAccent = false,
    this.fontSize = 11,
  });

  final String label;
  final IconData? icon;
  final bool isAccent;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final colors = AppWorldTokens.colorsOf(context);

    final bg = isAccent
        ? colors.accent.withValues(alpha: 0.18)
        : (colors.isDark ? Colors.white : Colors.black).withValues(alpha: 0.08);

    final border = isAccent
        ? colors.accent.withValues(alpha: 0.45)
        : (colors.isDark ? Colors.white : Colors.black).withValues(alpha: 0.14);

    final textColor = isAccent ? colors.accent : colors.textPrimary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border, width: 0.75),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: fontSize + 1, color: textColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: textColor,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
