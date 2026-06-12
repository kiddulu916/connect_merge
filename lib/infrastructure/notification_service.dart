import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/constants.dart';

/// IDs are stable so a reschedule cancels + replaces the prior notification
/// rather than stacking duplicates.
const int kDailyReminderId = 1001;
const int kStreakExpiryId = 1002;

/// Phase 1 staggered return moments. [kLootReadyId] nudges that the Daily Loot
/// Chest is unclaimed; [kMiddayId] is a gentle midday "your boards are waiting".
const int kLootReadyId = 1003;
const int kMiddayId = 1004;

/// A single notification the service wants delivered at [when] (local time).
class ScheduledNotification {
  final int id;
  final String title;
  final String body;
  final tz.TZDateTime when;

  const ScheduledNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.when,
  });

  @override
  bool operator ==(Object other) =>
      other is ScheduledNotification &&
      other.id == id &&
      other.title == title &&
      other.body == body &&
      other.when == when;

  @override
  int get hashCode => Object.hash(id, title, body, when);

  @override
  String toString() =>
      'ScheduledNotification(id: $id, title: $title, when: $when)';
}

/// Transport seams over `flutter_local_notifications`. Tests inject fakes so the
/// scheduling/suppression LOGIC is verified without the platform plugin.
typedef ScheduleFn = Future<void> Function(ScheduledNotification n);
typedef CancelFn = Future<void> Function(int id);
typedef PermissionFn = Future<bool> Function();

/// Schedules local daily-reminder + streak-expiry notifications. Purely local
/// (no FCM, \$0). All timing decisions are pure given a "now" + the day's state,
/// so they are unit-tested via [planFor]; delivery goes through injectable seams.
///
/// The plugin is only touched when constructed via [NotificationService.plugin];
/// tests use [NotificationService.withSeams].
class NotificationService {
  final ScheduleFn _schedule;
  final CancelFn _cancel;
  final PermissionFn _requestPermission;

  NotificationService.withSeams({
    required ScheduleFn schedule,
    required CancelFn cancel,
    required PermissionFn requestPermission,
  })  : _schedule = schedule,
        _cancel = cancel,
        _requestPermission = requestPermission;

  /// Production constructor: binds the seams to the real plugin. [plugin] must be
  /// initialized (and timezone configured) by the caller before scheduling.
  factory NotificationService.plugin(
      FlutterLocalNotificationsPlugin plugin) {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'daily_reminder',
        'Daily Reminder',
        channelDescription: 'Reminds you to play your daily puzzles.',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: DarwinNotificationDetails(),
    );
    return NotificationService.withSeams(
      schedule: (n) => plugin.zonedSchedule(
        n.id,
        n.title,
        n.body,
        n.when,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      ),
      cancel: plugin.cancel,
      requestPermission: () async {
        final android = plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        if (android != null) {
          final granted = await android.requestNotificationsPermission();
          return granted ?? false;
        }
        final ios = plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        if (ios != null) {
          final granted = await ios.requestPermissions(
              alert: true, badge: true, sound: true);
          return granted ?? false;
        }
        return false;
      },
    );
  }

  /// Request OS permission contextually (call AFTER the first completion, never
  /// at cold launch). Returns whether permission is granted.
  Future<bool> requestPermission() => _requestPermission();

  /// Pure: decide which notifications should be live given the current state.
  ///
  ///  - [allTiersDoneToday]: SUPPRESS the daily reminder + midday nudge entirely
  ///    (nothing left to nudge for today).
  ///  - [streakAtRisk]: a streak will lapse if not played before the next UTC
  ///    reset -> schedule the expiry warning a few hours before midnight UTC.
  ///  - [lootUnclaimed] (Phase 1): the Daily Loot Chest is ready and unclaimed
  ///    -> schedule a chest-ready nudge; SUPPRESSED once claimed.
  ///  - [middayMinutes] (Phase 1): minutes-past-local-midnight for the midday
  ///    "your boards are waiting" nudge.
  ///
  /// Returns the notifications to (re)schedule. Anything NOT returned for a known
  /// id should be cancelled by the caller (see [reschedule]).
  static List<ScheduledNotification> planFor({
    required tz.TZDateTime now,
    required int reminderMinutes,
    required bool enabled,
    required bool allTiersDoneToday,
    required bool streakAtRisk,
    bool lootUnclaimed = false,
    int middayMinutes = kMiddayReminderMinutes,
  }) {
    if (!enabled) return const [];
    final out = <ScheduledNotification>[];

    // Daily reminder: suppressed when everything is already done today.
    if (!allTiersDoneToday) {
      out.add(ScheduledNotification(
        id: kDailyReminderId,
        title: 'Your daily puzzles await',
        body: 'Play today\'s boards before the 00:00 UTC reset.',
        when: _nextOccurrence(now, reminderMinutes),
      ));
    }

    // Midday nudge: a gentle "boards are waiting", also suppressed once done.
    if (!allTiersDoneToday) {
      out.add(ScheduledNotification(
        id: kMiddayId,
        title: 'Your boards are waiting',
        body: 'Take a quick break and merge a few tiles.',
        when: _nextOccurrence(now, middayMinutes),
      ));
    }

    // Loot-chest-ready nudge: only while the chest is genuinely unclaimed.
    if (lootUnclaimed) {
      out.add(ScheduledNotification(
        id: kLootReadyId,
        title: 'Your daily chest is ready',
        body: 'Open today\'s loot chest for a reward.',
        when: _nextOccurrence(now, middayMinutes),
      ));
    }

    // Streak-expiry warning: only when a streak is genuinely at risk and not yet
    // saved by completing today.
    if (streakAtRisk && !allTiersDoneToday) {
      out.add(ScheduledNotification(
        id: kStreakExpiryId,
        title: 'Don\'t lose your streak!',
        body: 'Complete a board today to keep your streak alive.',
        when: _beforeNextUtcReset(now),
      ));
    }
    return out;
  }

  /// Next local time-of-day [minutes]-past-midnight at or after [now] (today if
  /// still upcoming, else tomorrow).
  static tz.TZDateTime _nextOccurrence(tz.TZDateTime now, int minutes) {
    var when = tz.TZDateTime(
        now.location, now.year, now.month, now.day, minutes ~/ 60, minutes % 60);
    if (!when.isAfter(now)) {
      when = when.add(const Duration(days: 1));
    }
    return when;
  }

  /// A warning a few hours before the next 00:00 UTC reset, expressed in the
  /// local zone. Falls back to the next-occurrence default if that moment has
  /// already passed.
  static tz.TZDateTime _beforeNextUtcReset(tz.TZDateTime now) {
    final utcNow = now.toUtc();
    final nextResetUtc = DateTime.utc(utcNow.year, utcNow.month, utcNow.day)
        .add(const Duration(days: 1));
    // Warn 3 hours before reset.
    final warnUtc = nextResetUtc.subtract(const Duration(hours: 3));
    var when = tz.TZDateTime.from(warnUtc, now.location);
    if (!when.isAfter(now)) {
      // Already inside the warning window; warn ~30 min out (but still future).
      when = now.add(const Duration(minutes: 30));
    }
    return when;
  }

  /// Cancel the prior daily/expiry notifications and reschedule per [planFor].
  /// Call on completion / app-open. No-op delivery when [enabled] is false (the
  /// plan is empty), but it still cancels stale notifications.
  Future<void> reschedule({
    required tz.TZDateTime now,
    required int reminderMinutes,
    required bool enabled,
    required bool allTiersDoneToday,
    required bool streakAtRisk,
    bool lootUnclaimed = false,
    int middayMinutes = kMiddayReminderMinutes,
  }) async {
    final plan = planFor(
      now: now,
      reminderMinutes: reminderMinutes,
      enabled: enabled,
      allTiersDoneToday: allTiersDoneToday,
      streakAtRisk: streakAtRisk,
      lootUnclaimed: lootUnclaimed,
      middayMinutes: middayMinutes,
    );
    final keepIds = plan.map((n) => n.id).toSet();
    // Cancel any managed id that the new plan doesn't include.
    for (final id in _managedIds) {
      if (!keepIds.contains(id)) await _cancel(id);
    }
    for (final n in plan) {
      await _schedule(n);
    }
  }

  /// All notification ids this service owns (cancel + replace discipline).
  static const List<int> _managedIds = [
    kDailyReminderId,
    kStreakExpiryId,
    kMiddayId,
    kLootReadyId,
  ];

  /// Cancel everything this service manages.
  Future<void> cancelAll() async {
    for (final id in _managedIds) {
      await _cancel(id);
    }
  }
}
