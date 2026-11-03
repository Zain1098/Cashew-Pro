import 'package:budget/colors.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

class ShimmerPlaceholder extends StatelessWidget {
  const ShimmerPlaceholder({
    super.key,
    this.width = double.infinity,
    required this.height,
    this.borderRadius = 15,
    this.margin = EdgeInsetsDirectional.zero,
  });

  final double width;
  final double height;
  final double borderRadius;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color baseColor = isDark
        ? Colors.white.withOpacity(0.07)
        : Colors.black.withOpacity(0.06);
    final Color highlightColor = isDark
        ? Colors.white.withOpacity(0.16)
        : Colors.black.withOpacity(0.13);
    return Padding(
      padding: margin,
      child: Shimmer.fromColors(
        baseColor: baseColor,
        highlightColor: highlightColor,
        period: const Duration(milliseconds: 1100),
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: getColor(context, "lightDarkAccentHeavyLight"),
            borderRadius: BorderRadiusDirectional.circular(borderRadius),
          ),
        ),
      ),
    );
  }
}
