import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../infrastructure/ad_service.dart';

/// Persistent bottom banner area. The height is reserved up front (standard
/// 320×50 banner) so the layout never shifts when the ad loads.
class BannerSlot extends StatefulWidget {
  final AdService adService;
  const BannerSlot({super.key, required this.adService});

  @override
  State<BannerSlot> createState() => _BannerSlotState();
}

class _BannerSlotState extends State<BannerSlot> {
  BannerAd? _banner;

  @override
  void initState() {
    super.initState();
    _banner = widget.adService.createBanner();
  }

  @override
  void dispose() {
    _banner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banner = _banner;
    return SizedBox(
      height: 50,
      width: double.infinity,
      child: banner == null ? const SizedBox.shrink() : AdWidget(ad: banner),
    );
  }
}
