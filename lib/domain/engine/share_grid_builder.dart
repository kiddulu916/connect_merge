import '../models/board_state.dart';

/// Builds a Wordle-style shareable result string from a final board.
class ShareGridBuilder {
  const ShareGridBuilder._();

  static String build({required String date, required BoardState board}) {
    final gs = board.gridSize;
    final best = board.highestTier;
    final sb = StringBuffer()
      ..writeln('Connect Merge $date')
      ..writeln(
          'Score ${board.score} · Best ${emojiForTier(best)}${1 << best} · ${board.movesMade} moves');

    for (var r = 0; r < gs; r++) {
      for (var c = 0; c < gs; c++) {
        final tile = board.cells[r * gs + c];
        sb.write(tile == null ? '⬛' : emojiForTier(tile.tier));
      }
      if (r < gs - 1) sb.write('\n');
    }
    return sb.toString();
  }

  /// Tier → color band: ⬛ empty → 🟦 low → 🟩 → 🟨 → 🟧 → 🟥 → 🟪 max.
  static String emojiForTier(int tier) {
    if (tier <= 0) return '⬛';
    if (tier <= 2) return '🟦';
    if (tier <= 4) return '🟩';
    if (tier <= 6) return '🟨';
    if (tier <= 8) return '🟧';
    if (tier <= 10) return '🟥';
    return '🟪';
  }
}
