class PlayerSettings {
  final bool notificationsEnabled;
  final int reminderMinutes;
  final bool tutorialSeen;
  final bool colorblindMode;

  const PlayerSettings({
    this.notificationsEnabled = false,
    this.reminderMinutes = 19 * 60,
    this.tutorialSeen = false,
    this.colorblindMode = false,
  });

  PlayerSettings copyWith({
    bool? notificationsEnabled,
    int? reminderMinutes,
    bool? tutorialSeen,
    bool? colorblindMode,
  }) =>
      PlayerSettings(
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        reminderMinutes: reminderMinutes ?? this.reminderMinutes,
        tutorialSeen: tutorialSeen ?? this.tutorialSeen,
        colorblindMode: colorblindMode ?? this.colorblindMode,
      );
}
