import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/notification_service.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
  });

  // A fixed local zone for deterministic timing assertions.
  late tz.Location utc;
  setUp(() => utc = tz.getLocation('UTC'));

  group('planFor (pure scheduling logic)', () {
    tz.TZDateTime now() => tz.TZDateTime(utc, 2026, 6, 7, 9, 0); // 09:00 UTC

    test('disabled -> nothing scheduled', () {
      final plan = NotificationService.planFor(
        now: now(),
        reminderMinutes: 19 * 60,
        enabled: false,
        allTiersDoneToday: false,
        streakAtRisk: false,
      );
      expect(plan, isEmpty);
    });

    test('all tiers done today -> SUPPRESS the daily reminder', () {
      final plan = NotificationService.planFor(
        now: now(),
        reminderMinutes: 19 * 60,
        enabled: true,
        allTiersDoneToday: true,
        streakAtRisk: true, // even at risk, done = no nudge
      );
      expect(plan, isEmpty);
    });

    test('not done -> schedules the daily reminder at the chosen local time',
        () {
      final plan = NotificationService.planFor(
        now: now(),
        reminderMinutes: 19 * 60, // 19:00
        enabled: true,
        allTiersDoneToday: false,
        streakAtRisk: false,
      );
      final reminder = plan.firstWhere((n) => n.id == kDailyReminderId);
      expect(reminder.when.hour, 19);
      expect(reminder.when.minute, 0);
      // Same day since 19:00 is still ahead of 09:00.
      expect(reminder.when.day, 7);
    });

    test('reminder time already passed -> rolls to tomorrow', () {
      final plan = NotificationService.planFor(
        now: tz.TZDateTime(utc, 2026, 6, 7, 20, 0), // 20:00, past 19:00
        reminderMinutes: 19 * 60,
        enabled: true,
        allTiersDoneToday: false,
        streakAtRisk: false,
      );
      final reminder = plan.firstWhere((n) => n.id == kDailyReminderId);
      expect(reminder.when.day, 8);
    });

    test('streak at risk + not done -> also schedules an expiry warning', () {
      final plan = NotificationService.planFor(
        now: now(),
        reminderMinutes: 19 * 60,
        enabled: true,
        allTiersDoneToday: false,
        streakAtRisk: true,
      );
      expect(plan.any((n) => n.id == kStreakExpiryId), isTrue);
    });

    test('streak NOT at risk -> no expiry warning', () {
      final plan = NotificationService.planFor(
        now: now(),
        reminderMinutes: 19 * 60,
        enabled: true,
        allTiersDoneToday: false,
        streakAtRisk: false,
      );
      expect(plan.any((n) => n.id == kStreakExpiryId), isFalse);
    });

    group('Phase 1 staggered nudges', () {
      test(
          'not done + loot claimed -> midday nudge fires (and loot-ready does '
          'NOT, only one at the slot)', () {
        final plan = NotificationService.planFor(
          now: now(),
          reminderMinutes: 19 * 60,
          enabled: true,
          allTiersDoneToday: false,
          streakAtRisk: false,
          lootUnclaimed: false,
          middayMinutes: 12 * 60,
        );
        final midday = plan.firstWhere((n) => n.id == kMiddayId);
        expect(midday.when.hour, 12);
        // Exactly one notification occupies the midday slot.
        expect(plan.any((n) => n.id == kLootReadyId), isFalse);
      });

      test(
          'loot unclaimed -> ONLY the loot-ready nudge fires at the slot, the '
          'midday nudge is suppressed (no duplicate at the same instant)', () {
        final plan = NotificationService.planFor(
          now: now(),
          reminderMinutes: 19 * 60,
          enabled: true,
          allTiersDoneToday: false,
          streakAtRisk: false,
          lootUnclaimed: true,
          middayMinutes: 12 * 60,
        );
        expect(plan.any((n) => n.id == kLootReadyId), isTrue);
        expect(plan.any((n) => n.id == kMiddayId), isFalse);
      });

      test('all tiers done -> midday nudge suppressed', () {
        final plan = NotificationService.planFor(
          now: now(),
          reminderMinutes: 19 * 60,
          enabled: true,
          allTiersDoneToday: true,
          streakAtRisk: false,
          lootUnclaimed: true, // loot can still fire; midday cannot
        );
        expect(plan.any((n) => n.id == kMiddayId), isFalse);
      });

      test('loot unclaimed -> chest-ready nudge scheduled', () {
        final plan = NotificationService.planFor(
          now: now(),
          reminderMinutes: 19 * 60,
          enabled: true,
          allTiersDoneToday: false,
          streakAtRisk: false,
          lootUnclaimed: true,
        );
        expect(plan.any((n) => n.id == kLootReadyId), isTrue);
      });

      test('loot claimed -> chest-ready nudge suppressed', () {
        final plan = NotificationService.planFor(
          now: now(),
          reminderMinutes: 19 * 60,
          enabled: true,
          allTiersDoneToday: false,
          streakAtRisk: false,
          lootUnclaimed: false,
        );
        expect(plan.any((n) => n.id == kLootReadyId), isFalse);
      });
    });
  });

  group('reschedule (cancel + schedule via seams)', () {
    test('cancels stale ids not in the new plan, schedules the rest', () async {
      final scheduled = <int>[];
      final cancelled = <int>[];
      final svc = NotificationService.withSeams(
        schedule: (n) async => scheduled.add(n.id),
        cancel: (id) async => cancelled.add(id),
        requestPermission: () async => true,
      );

      await svc.reschedule(
        now: tz.TZDateTime(tz.getLocation('UTC'), 2026, 6, 7, 9, 0),
        reminderMinutes: 19 * 60,
        enabled: true,
        allTiersDoneToday: false,
        streakAtRisk: false,
      );

      // Daily reminder scheduled; expiry id cancelled (not in plan).
      expect(scheduled, contains(kDailyReminderId));
      expect(cancelled, contains(kStreakExpiryId));
    });

    test('when all tiers done, BOTH managed ids are cancelled, none scheduled',
        () async {
      final scheduled = <int>[];
      final cancelled = <int>[];
      final svc = NotificationService.withSeams(
        schedule: (n) async => scheduled.add(n.id),
        cancel: (id) async => cancelled.add(id),
        requestPermission: () async => true,
      );

      await svc.reschedule(
        now: tz.TZDateTime(tz.getLocation('UTC'), 2026, 6, 7, 9, 0),
        reminderMinutes: 19 * 60,
        enabled: true,
        allTiersDoneToday: true,
        streakAtRisk: true,
      );

      expect(scheduled, isEmpty);
      expect(cancelled, containsAll([kDailyReminderId, kStreakExpiryId]));
    });
  });

  test('cancelAll cancels all managed ids', () async {
    final cancelled = <int>[];
    final svc = NotificationService.withSeams(
      schedule: (_) async {},
      cancel: (id) async => cancelled.add(id),
      requestPermission: () async => true,
    );
    await svc.cancelAll();
    expect(cancelled,
        containsAll([kDailyReminderId, kStreakExpiryId, kMiddayId, kLootReadyId]));
  });

  test('requestPermission delegates to the seam', () async {
    final svc = NotificationService.withSeams(
      schedule: (_) async {},
      cancel: (_) async {},
      requestPermission: () async => true,
    );
    expect(await svc.requestPermission(), isTrue);
  });
}
