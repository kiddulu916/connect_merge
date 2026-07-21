import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

const _mergeHighlightedTiles =
    CustomSemanticsAction(label: 'Merge highlighted tiles');

/// Modal coachmark chrome with a non-intercepting spotlight cutout.
class TutorialSpotlight extends StatelessWidget {
  final Rect? targetRect;
  final String stepLabel;
  final String title;
  final String body;
  final VoidCallback onSkip;
  final VoidCallback? onNext;
  final String nextLabel;
  final Key nextKey;
  final VoidCallback? onSemanticMerge;
  final bool waiting;
  final bool allowTargetInteraction;

  const TutorialSpotlight({
    super.key,
    required this.targetRect,
    required this.stepLabel,
    required this.title,
    required this.body,
    required this.onSkip,
    this.onNext,
    this.nextLabel = 'Next',
    this.nextKey = const Key('tutorial-next'),
    this.onSemanticMerge,
    this.waiting = false,
    this.allowTargetInteraction = false,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              key: const Key('tutorial-spotlight-cutout'),
              painter: _SpotlightPainter(targetRect),
            ),
          ),
        ),
        Positioned.fill(
          child: _SpotlightPointerBarrier(
            targetRect: targetRect,
            allowTargetInteraction: allowTargetInteraction,
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: TextButton(
                key: const Key('tutorial-skip'),
                onPressed: waiting ? null : onSkip,
                child:
                    const Text('Skip', style: TextStyle(color: Colors.white70)),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Semantics(
              key: onSemanticMerge == null
                  ? null
                  : const Key('tutorial-semantic-merge'),
              label: onSemanticMerge == null ? null : '$title. $body',
              customSemanticsActions: onSemanticMerge == null || waiting
                  ? null
                  : {_mergeHighlightedTiles: onSemanticMerge!},
              child: Container(
                key: Key('tutorial-$stepLabel'),
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E2230),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.amberAccent),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 20),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      stepLabel.replaceFirst('step-', 'Step '),
                      style: const TextStyle(
                        color: Colors.amberAccent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      body,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 15,
                        height: 1.35,
                      ),
                    ),
                    if (waiting) ...[
                      const SizedBox(height: 16),
                      const Center(child: CircularProgressIndicator()),
                    ] else if (onNext != null) ...[
                      const SizedBox(height: 16),
                      FilledButton(
                        key: nextKey,
                        onPressed: onNext,
                        child: Text(nextLabel),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SpotlightPointerBarrier extends StatelessWidget {
  final Rect? targetRect;
  final bool allowTargetInteraction;

  const _SpotlightPointerBarrier({
    required this.targetRect,
    required this.allowTargetInteraction,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final target = targetRect?.intersect(Offset.zero & constraints.biggest);
        if (!allowTargetInteraction || target == null || target.isEmpty) {
          return const AbsorbPointer(
            child: ColoredBox(color: Colors.transparent),
          );
        }

        return Stack(
          children: [
            _barrier(left: 0, top: 0, right: 0, height: target.top),
            _barrier(
              left: 0,
              top: target.top,
              width: target.left,
              height: target.height,
            ),
            _barrier(
              left: target.right,
              top: target.top,
              right: 0,
              height: target.height,
            ),
            _barrier(left: 0, top: target.bottom, right: 0, bottom: 0),
          ],
        );
      },
    );
  }

  Widget _barrier({
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
  }) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: const AbsorbPointer(
        child: ColoredBox(color: Colors.transparent),
      ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  final Rect? targetRect;

  const _SpotlightPainter(this.targetRect);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRect(Offset.zero & size);
    final target = targetRect;
    if (target != null) {
      path.addRRect(
        RRect.fromRectAndRadius(target.inflate(8), const Radius.circular(12)),
      );
      path.fillType = PathFillType.evenOdd;
    }
    canvas.drawPath(
        path, Paint()..color = Colors.black.withValues(alpha: 0.78));
  }

  @override
  bool shouldRepaint(_SpotlightPainter oldDelegate) =>
      oldDelegate.targetRect != targetRect;
}
