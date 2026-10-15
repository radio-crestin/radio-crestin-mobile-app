import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme.dart';

/// A station category's picture on a circle in its pastel hue.
///
/// [slug] null is "Toate stațiile". Every category with a hue in
/// [AppColors.stationGroupHues] has a picture in
/// `assets/icons/station_groups/` named after its slug; categories added
/// later get `fallback.svg` until they get both.
class StationGroupPicture extends StatelessWidget {
  const StationGroupPicture({super.key, required this.slug, this.size = 50});

  final String? slug;

  /// The circle's diameter; the picture fills about two thirds of it.
  final double size;

  String get _asset {
    final slug = this.slug;
    final name = switch (slug) {
      null => 'all',
      _ when AppColors.stationGroupHues.containsKey(slug) => slug,
      _ => 'fallback',
    };
    return 'assets/icons/station_groups/$name.svg';
  }

  Color get _hue {
    final slug = this.slug;
    if (slug == null) return AppColors.stationGroupAllHue;
    return AppColors.stationGroupHues[slug] ??
        AppColors.stationGroupFallbackHue;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pastel =
        Color.lerp(_hue, Colors.white, isDark ? 0.7 : 0.6) ?? _hue;
    final pictureSize = size * 0.64;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: pastel, shape: BoxShape.circle),
      child: SvgPicture.asset(
        _asset,
        width: pictureSize,
        height: pictureSize,
        excludeFromSemantics: true,
      ),
    );
  }
}
