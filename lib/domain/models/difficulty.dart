/// Difficulty tiers for the daily puzzle.
///
/// Tile count is the ONLY difficulty lever — the move budget stays the same
/// (kMovesPerDay) for every tier. Fewer starting tiles means fewer guaranteed
/// merges and a tighter board, so legendary is the hardest.
///
/// [name] (`easy`/`medium`/`hard`/`legendary`) is the stable seed-key and
/// storage-key token — it must never be localized. Use [label] for display.
enum Difficulty {
  easy(startingFill: 10, label: 'Easy'),
  medium(startingFill: 8, label: 'Medium'),
  hard(startingFill: 6, label: 'Hard'),
  legendary(startingFill: 4, label: 'Legendary');

  const Difficulty({required this.startingFill, required this.label});

  /// Number of tiles placed on the board at the start of the day.
  final int startingFill;

  /// Human-readable label for the UI.
  final String label;
}
