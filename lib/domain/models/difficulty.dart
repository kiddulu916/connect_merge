/// Difficulty tiers for the daily puzzle.
///
/// [name] (`easy`/`medium`/`hard`/`legendary`) is the stable seed-key and
/// storage-key token — it must never be localized. Use [label] for display.
enum Difficulty {
  easy(gridSize: 8, startingFill: 40, label: 'Easy'),
  medium(gridSize: 7, startingFill: 25, label: 'Medium'),
  hard(gridSize: 6, startingFill: 20, label: 'Hard'),
  legendary(gridSize: 6, startingFill: 15, label: 'Legendary'),
  challenge(gridSize: 6, startingFill: 8, label: 'Challenge');

  const Difficulty({
    required this.gridSize,
    required this.startingFill,
    required this.label,
  });

  final int gridSize;
  final int startingFill;
  final String label;

  int get cellCount => gridSize * gridSize;
}
