import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../application/engagement_cubit.dart';
import '../../widgets/streak_banner.dart';

/// Wraps [StreakBanner] with the [EngagementCubit] subscription and
/// visibility rule (hidden entirely when there's no active streak).
/// Extracted from tier_select_screen.dart.
class StreakSection extends StatelessWidget {
  final EngagementCubit engagement;
  final ValueListenable<bool> adBusy;

  /// Called with this widget's own [BuildContext] when the freeze CTA is
  /// tapped — matches `_watchFreezeAd(BuildContext)`'s signature so the
  /// parent can pass that method directly.
  final void Function(BuildContext context) onFreezePressed;

  const StreakSection({
    super.key,
    required this.engagement,
    required this.adBusy,
    required this.onFreezePressed,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<EngagementCubit, EngagementState>(
      bloc: engagement,
      builder: (context, eng) {
        if (eng.dailyActiveStreak <= 0) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ValueListenableBuilder<bool>(
            valueListenable: adBusy,
            builder: (context, busy, _) => StreakBanner(
              streak: eng.dailyActiveStreak,
              freezeTokens: eng.freezeTokens,
              busy: busy,
              onFreeze: () => onFreezePressed(context),
            ),
          ),
        );
      },
    );
  }
}
