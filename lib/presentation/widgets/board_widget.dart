import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/constants.dart';
import '../../domain/engine/game_engine.dart';
import '../../domain/models/board_state.dart';
import '../../domain/models/cosmetic.dart';
import 'grid_cell_widget.dart';

/// Renders the 5×5 board as a static slot grid with live tiles floating above
/// as AnimatedPositioned widgets keyed by tile id, so merges slide and drops
/// fall smoothly. Draw a connected path across matching tiles to chain-merge;
/// [onChain] is invoked with the ordered list of cell indices when the gesture
/// ends with a valid path (length >= 2).
class BoardWidget extends StatefulWidget {
  final BoardState board;
  final void Function(List<int> path) onChain;

  /// Selected tile theme. Defaults to classic.
  final Cosmetic cosmetic;

  /// When true, render colorblind-safe per-tier patterns on tiles (Phase 4).
  final bool colorblindMode;

  const BoardWidget({
    super.key,
    required this.board,
    required this.onChain,
    this.cosmetic = Cosmetic.classic,
    this.colorblindMode = false,
  });

  @override
  State<BoardWidget> createState() => _BoardWidgetState();
}

class _BoardWidgetState extends State<BoardWidget> {
  final List<int> _path = [];
  double _cell = 0;
  double _gap = 8;

  int? _cellAt(Offset local) {
    final step = _cell + _gap;
    final count = widget.board.cells.length;
    final gs = widget.board.gridSize;
    for (var i = 0; i < count; i++) {
      final row = i ~/ gs, col = i % gs;
      final rect = Rect.fromLTWH(
          _gap + col * step, _gap + row * step, _cell, _cell);
      if (rect.contains(local)) return i;
    }
    return null;
  }

  bool _canExtend(int idx) {
    if (widget.board.walls.contains(idx)) return false;
    final t = widget.board.cells[idx];
    if (t == null || t.tier >= kMaxTier) return false;
    if (_path.isEmpty) return true;
    if (_path.contains(idx)) return false;
    final lastTier = widget.board.cells[_path.last]!.tier;
    if (t.tier < lastTier || t.tier > lastTier + 1) return false;
    return GameEngine.areOrthogonallyAdjacent(_path.last, idx, widget.board.gridSize);
  }

  void _onStart(Offset local) {
    final idx = _cellAt(local);
    if (idx != null && _canExtend(idx)) {
      setState(() => _path
        ..clear()
        ..add(idx));
    }
  }

  void _onUpdate(Offset local) {
    final idx = _cellAt(local);
    if (idx == null) return;
    // Backtrack: dragging onto the previous cell un-picks the last.
    if (_path.length >= 2 && idx == _path[_path.length - 2]) {
      setState(() => _path.removeLast());
      return;
    }
    if (_canExtend(idx)) setState(() => _path.add(idx));
  }

  void _onEnd() {
    if (_path.length >= 2) {
      HapticFeedback.mediumImpact();
      widget.onChain(List<int>.of(_path));
    }
    setState(() => _path.clear());
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final boardSize = constraints.maxWidth;
        final gs = widget.board.gridSize;
        final cell = (boardSize - gap * (gs + 1)) / gs;

        // Store for hit-testing in gesture callbacks.
        _gap = gap;
        _cell = cell;

        Offset offsetFor(int index) {
          final row = index ~/ gs;
          final col = index % gs;
          return Offset(gap + col * (cell + gap), gap + row * (cell + gap));
        }

        final children = <Widget>[];

        // Backing slots: render walls distinctly.
        for (var i = 0; i < widget.board.cells.length; i++) {
          final pos = offsetFor(i);
          final isWall = widget.board.walls.contains(i);
          children.add(Positioned(
            left: pos.dx,
            top: pos.dy,
            child: isWall
                ? Container(
                    width: cell,
                    height: cell,
                    decoration: BoxDecoration(
                      color: const Color(0xFF3A3F52),
                      borderRadius: BorderRadius.circular(cell * 0.16),
                    ),
                    child: const Icon(Icons.block, color: Colors.white24),
                  )
                : GridCellWidget(
                    tile: null, size: cell, cosmetic: widget.cosmetic),
          ));
        }

        // Floating live tiles keyed by id (for AnimatedPositioned animations).
        // Cells in the current path get a glow highlight; a step that ascends
        // one tier above the previous path entry glows amber instead of white.
        final pathIndexOf = <int, int>{
          for (var p = 0; p < _path.length; p++) _path[p]: p,
        };
        for (var i = 0; i < widget.board.cells.length; i++) {
          final tile = widget.board.cells[i];
          if (tile == null) continue;
          final pos = offsetFor(i);
          final pathPos = pathIndexOf[i];
          final inPath = pathPos != null;
          final isAscend = inPath &&
              pathPos > 0 &&
              tile.tier == widget.board.cells[_path[pathPos - 1]]!.tier + 1;
          children.add(AnimatedPositioned(
            key: ValueKey(tile.id),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            left: pos.dx,
            top: pos.dy,
            width: cell,
            height: cell,
            child: inPath
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(cell * 0.16),
                      boxShadow: [
                        BoxShadow(
                          color: isAscend
                              ? Colors.amber.withValues(alpha: 0.6)
                              : Colors.white.withValues(alpha: 0.45),
                          blurRadius: cell * 0.25,
                          spreadRadius: cell * 0.06,
                        ),
                      ],
                    ),
                    child: GridCellWidget(
                      tile: tile,
                      size: cell,
                      cosmetic: widget.cosmetic,
                      colorblindMode: widget.colorblindMode,
                    ),
                  )
                : GridCellWidget(
                    tile: tile,
                    size: cell,
                    cosmetic: widget.cosmetic,
                    colorblindMode: widget.colorblindMode,
                  ),
          ));
        }

        return GestureDetector(
          onPanStart: (d) => _onStart(d.localPosition),
          onPanUpdate: (d) => _onUpdate(d.localPosition),
          onPanEnd: (_) => _onEnd(),
          child: SizedBox(
            width: boardSize,
            height: boardSize,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF1E2230),
                borderRadius: BorderRadius.circular(gap * 1.5),
              ),
              child: Stack(children: children),
            ),
          ),
        );
      },
    );
  }
}
