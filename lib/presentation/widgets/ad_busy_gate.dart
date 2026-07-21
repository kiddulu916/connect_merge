import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AdBusyGate extends StatelessWidget {
  final ValueListenable<bool> busy;
  final VoidCallback? onPressed;
  final Widget Function(BuildContext context, VoidCallback? onPressed) builder;

  const AdBusyGate({
    super.key,
    required this.busy,
    required this.onPressed,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: busy,
        builder: (context, isBusy, _) =>
            builder(context, isBusy ? null : onPressed),
      );
}
