import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// First-run identity choice. All auth and ownership work stays in the app
/// shell; this screen only prevents double taps and reports a retryable error.
class AuthGateScreen extends StatefulWidget {
  final Future<bool> Function() onGoogle;
  final Future<bool> Function() onGuest;

  const AuthGateScreen({
    super.key,
    required this.onGoogle,
    required this.onGuest,
  });

  @override
  State<AuthGateScreen> createState() => _AuthGateScreenState();
}

class _AuthGateScreenState extends State<AuthGateScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<bool> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final completed = await action();
      if (!completed && mounted) setState(() => _busy = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not continue. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                const Icon(
                  Icons.hub_rounded,
                  color: Colors.deepPurpleAccent,
                  size: 72,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Keep your puzzle progress',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Sign in to restore your profile on another device, or play '
                  'as a guest on this one.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 15),
                ),
                const Spacer(),
                if (_error != null) ...[
                  Text(
                    _error!,
                    key: const Key('auth-gate-error'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  key: const Key('continue-google'),
                  onPressed: _busy ? null : () => _run(widget.onGoogle),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.account_circle),
                  label: const Text('Continue with Google'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: Colors.deepPurpleAccent,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const Key('play-guest'),
                  onPressed: _busy ? null : () => _run(widget.onGuest),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Play as guest'),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      );
}
