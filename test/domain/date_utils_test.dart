import 'package:connect_merge/domain/date_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseUtcDate', () {
    test('parses canonical date components in UTC', () {
      final date = parseUtcDate('2026-07-18');

      expect(date, DateTime.utc(2026, 7, 18));
      expect(date.isUtc, isTrue);
    });
  });

  group('previousUtcDay', () {
    test('previousUtcDay crosses a year boundary', () {
      expect(previousUtcDay('2026-01-01'), '2025-12-31');
    });

    test('previousUtcDay returns leap day', () {
      expect(previousUtcDay('2024-03-01'), '2024-02-29');
    });

    test('previousUtcDay crosses Cairo spring-forward', () {
      expect(previousUtcDay('2025-04-26'), '2025-04-25');
    });
  });

  group('mondayOfWeek', () {
    test('returns the same Monday for every weekday in an ISO week', () {
      for (final date in [
        '2025-04-21',
        '2025-04-22',
        '2025-04-23',
        '2025-04-24',
        '2025-04-25',
        '2025-04-26',
        '2025-04-27',
      ]) {
        expect(mondayOfWeek(date), '2025-04-21', reason: date);
      }
    });

    test('crosses a month boundary', () {
      expect(mondayOfWeek('2025-05-03'), '2025-04-28');
    });

    test('crosses a year boundary', () {
      expect(mondayOfWeek('2026-01-01'), '2025-12-29');
    });

    test('finds Monday after Cairo spring-forward', () {
      expect(mondayOfWeek('2025-04-26'), '2025-04-21');
    });
  });
}
