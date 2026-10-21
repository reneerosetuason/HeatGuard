import 'package:flutter/material.dart';

/// Shared artwork keeps the account screens and dashboard on the same brand.
class HeatGuardLogo extends StatelessWidget {
  const HeatGuardLogo({super.key, this.width = 180});
  final double width;

  static const asset = 'assets/branding/heatguard_logo.png';

  @override
  Widget build(BuildContext context) => Image.asset(
    asset,
    width: width,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.high,
    semanticLabel: 'HeatGuard',
  );
}

class HeatGuardMark extends StatelessWidget {
  const HeatGuardMark({super.key, this.size = 44});
  final double size;

  static const asset = 'assets/branding/heatguard_mark.png';

  @override
  Widget build(BuildContext context) => Image.asset(
    asset,
    width: size,
    height: size,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.high,
    excludeFromSemantics: true,
  );
}

/// Keep the two-color name readable in the dashboard's compact app bar.
class HeatGuardWordmark extends StatelessWidget {
  const HeatGuardWordmark({super.key, this.width = 170});
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: const FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'Heat',
              style: TextStyle(color: Color(0xFFD97840)),
            ),
            TextSpan(
              text: 'Guard',
              style: TextStyle(color: Color(0xFF6B5144)),
            ),
          ],
        ),
        maxLines: 1,
        style: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          letterSpacing: -1,
        ),
      ),
    ),
  );
}
