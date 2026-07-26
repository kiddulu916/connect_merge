import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../application/engagement_cubit.dart';
import '../../domain/models/avatar.dart';
import '../../domain/models/cosmetic.dart' show CosmeticUnlock;
import '../../infrastructure/auth_service.dart';
import '../theme/tokens.dart';
import '../widgets/coin_balance.dart';
import '../widgets/price_tag.dart';

/// Pick an emoji avatar. Unlocked avatars are selectable; purchasable ones show
/// a coin price. Selecting also writes through to the server so the avatar shows
/// on other players' leaderboards/friends lists. Mirrors [CosmeticsScreen].
class AvatarsScreen extends StatefulWidget {
  final EngagementCubit engagement;
  final AuthService auth;

  const AvatarsScreen({
    super.key,
    required this.engagement,
    required this.auth,
  });

  @override
  State<AvatarsScreen> createState() => _AvatarsScreenState();
}

class _AvatarsScreenState extends State<AvatarsScreen> {
  @override
  void initState() {
    super.initState();
    // Coins can be credited outside this cubit (golden tiles, loot); refresh so
    // purchase affordability is accurate.
    widget.engagement.refreshWallet();
    _syncSelectedFromServer();
  }

  /// The server row is the source of truth for the *currently worn* avatar
  /// (a local install may never have persisted a selection). Best-effort.
  Future<void> _syncSelectedFromServer() async {
    try {
      final profile = await widget.auth.profile();
      final emoji = profile.avatar;
      if (emoji != null) await widget.engagement.syncSelectedAvatar(emoji);
    } catch (_) {
      // Offline: keep the locally-cached selection.
    }
  }

  Future<void> _select(BuildContext context, Avatar a) async {
    await widget.engagement.selectAvatar(a);
    // Write through so other players see the new avatar; best-effort.
    try {
      await widget.auth.updateAvatar(a.emoji);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Saved locally — we'll sync when you're online.")),
        );
      }
    }
  }

  Future<void> _buy(BuildContext context, Avatar a) async {
    final ok = await widget.engagement.purchaseAvatar(a);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Avatar unlocked!' : 'Not enough coins.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<EngagementCubit, EngagementState>(
      bloc: widget.engagement,
      builder: (context, state) {
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.background,
            foregroundColor: Colors.white,
            title: const Text('Avatars'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(child: CoinBalance(coins: state.coins)),
              ),
            ],
          ),
          body: GridView.count(
            key: const Key('avatars-grid'),
            padding: const EdgeInsets.all(16),
            crossAxisCount: 4,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (final a in Avatar.values)
                _AvatarTile(
                  avatar: a,
                  selected: state.selectedAvatar == a.emoji,
                  unlocked: state.unlockedAvatars.contains(a),
                  affordable: state.coins >= a.price,
                  onSelect: () => _select(context, a),
                  onBuy: a.unlock == CosmeticUnlock.purchase
                      ? () => _buy(context, a)
                      : null,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _AvatarTile extends StatelessWidget {
  final Avatar avatar;
  final bool selected;
  final bool unlocked;
  final bool affordable;
  final VoidCallback onSelect;
  final VoidCallback? onBuy;

  const _AvatarTile({
    required this.avatar,
    required this.selected,
    required this.unlocked,
    required this.affordable,
    required this.onSelect,
    this.onBuy,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.deepPurpleAccent : AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: Key('avatar-${avatar.name}'),
        borderRadius: BorderRadius.circular(12),
        onTap: unlocked ? onSelect : onBuy,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: unlocked ? 1 : 0.35,
              child: Text(avatar.emoji, style: const TextStyle(fontSize: 30)),
            ),
            if (selected)
              const Positioned(
                top: 4,
                right: 4,
                child: Icon(Icons.check_circle,
                    color: Colors.greenAccent, size: 16),
              )
            else if (!unlocked && onBuy != null)
              Positioned(
                bottom: 4,
                child: PriceTag(
                  key: Key('avatar-buy-${avatar.name}'),
                  price: avatar.price,
                  affordable: affordable,
                  onBuy: onBuy!,
                ),
              )
            else if (!unlocked)
              const Positioned(
                top: 4,
                right: 4,
                child: Icon(Icons.lock_outline, color: Colors.white38, size: 16),
              ),
          ],
        ),
      ),
    );
  }
}
