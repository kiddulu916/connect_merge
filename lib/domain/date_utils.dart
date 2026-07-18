// Canonical date utilities shared across domain, application, and presentation
// layers. Keeping these here (in domain) avoids the cross-layer import that
// would otherwise arise when domain models need date formatting.

/// Formats a [DateTime] as the canonical YYYY-MM-DD seeding key.
String formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The canonical UTC date string used for seeding and storage everywhere.
/// A single helper avoids local/UTC mixing (off-by-one near midnight).
String utcToday() => formatDate(DateTime.now().toUtc());

/// Parses a canonical YYYY-MM-DD date into a UTC [DateTime].
DateTime parseUtcDate(String yyyyMmDd) {
  final parts = yyyyMmDd.split('-').map(int.parse).toList();
  return DateTime.utc(parts[0], parts[1], parts[2]);
}

/// The UTC day before [date] (YYYY-MM-DD).
String previousUtcDay(String date) {
  final parsed = parseUtcDate(date);
  return formatDate(DateTime.utc(parsed.year, parsed.month, parsed.day - 1));
}

/// The Monday of the ISO week containing [date] (YYYY-MM-DD).
String mondayOfWeek(String date) {
  final parsed = parseUtcDate(date);
  final daysSinceMonday = (parsed.weekday - DateTime.monday) % 7;
  return formatDate(
    DateTime.utc(parsed.year, parsed.month, parsed.day - daysSinceMonday),
  );
}
