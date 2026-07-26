import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Top app bar for [TierSelectScreen]: title left, secondary-nav icons right.
/// The title uses FittedBox(scaleDown) so it always stays on ONE line —
/// shrinking only if the (up to 5) compact action icons leave it too little
/// room — and never wraps. Extracted from tier_select_screen.dart.
class TierSelectAppBar extends StatelessWidget {
  final bool showFriends;
  final bool showProfile;
  final VoidCallback onAchievements;
  final VoidCallback onCosmetics;
  final VoidCallback onAlmanac;
  final VoidCallback onFriends;
  final VoidCallback onProfile;

  const TierSelectAppBar({
    super.key,
    required this.showFriends,
    required this.showProfile,
    required this.onAchievements,
    required this.onCosmetics,
    required this.onAlmanac,
    required this.onFriends,
    required this.onProfile,
  });

  /// A compact secondary-nav icon button for the top app bar. Tighter than the
  /// default 48px target (22px glyph, 40px hit area, no padding) so up to five
  /// fit alongside the title without forcing it to wrap.
  Widget _navIconButton({
    required Key iconKey,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: iconKey,
      tooltip: tooltip,
      icon: Icon(icon, color: AppColors.textSecondary),
      iconSize: 22,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text('Connect Merge',
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w900)),
          ),
        ),
        _navIconButton(
          iconKey: const Key('open-achievements'),
          tooltip: 'Achievements',
          icon: Icons.emoji_events,
          onPressed: onAchievements,
        ),
        _navIconButton(
          iconKey: const Key('open-cosmetics'),
          tooltip: 'Tile themes',
          icon: Icons.palette,
          onPressed: onCosmetics,
        ),
        _navIconButton(
          iconKey: const Key('open-almanac'),
          tooltip: 'Merge Almanac',
          icon: Icons.menu_book,
          onPressed: onAlmanac,
        ),
        if (showFriends)
          _navIconButton(
            iconKey: const Key('open-friends'),
            tooltip: 'Friends',
            icon: Icons.group,
            onPressed: onFriends,
          ),
        if (showProfile)
          _navIconButton(
            iconKey: const Key('open-profile'),
            tooltip: 'Profile',
            icon: Icons.person,
            onPressed: onProfile,
          ),
      ],
    );
  }
}
