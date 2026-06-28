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
