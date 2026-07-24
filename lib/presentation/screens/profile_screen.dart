import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../infrastructure/auth_service.dart';
import '../../infrastructure/storage_service.dart';
import '../theme/tokens.dart';

/// Player profile: avatar, display name, account actions, and delete-my-data.
///
/// The Player ID is the auth UUID — the credential accepted by the web form at
/// connectmerge.app/delete-my-data.html, so it's shown ONLY here (never on
/// shareable surfaces like the friends screen). Tap to copy.
///
/// Identity-changing callbacks are owned by the app shell, where retained
/// prize jobs, profile sync, auth, the local wipe, and owner rebind can be
/// serialized. A boolean account callback returns false only when the player
/// cancelled a warning, keeping this route open and interactive.
class ProfileScreen extends StatefulWidget {
  final AuthService auth;
  final StorageService storage;
  final Future<void> Function()? onDelete;
  final Future<bool> Function()? onSignOut;
  final Future<bool> Function()? onSaveProgress;
  final VoidCallback? onChangeName;

  const ProfileScreen({
    super.key,
    required this.auth,
    required this.storage,
    this.onDelete,
    this.onSignOut,
    this.onSaveProgress,
    this.onChangeName,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String? _name;
  String? _avatar;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.auth.profile();
      if (!mounted) return;
      setState(() {
        _name = p.name;
        _avatar = p.avatar;
      });
    } catch (_) {
      // Offline: the screen still shows the Player ID (available locally).
    }
  }

  Future<void> _copyPlayerId() async {
    final id = widget.auth.currentUserId;
    if (id == null) return;
    await Clipboard.setData(ClipboardData(text: id));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Player ID copied.')),
    );
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete all your data?'),
        content: const Text(
            'This permanently erases your account, scores, leaderboard '
            'entries, friends, and local progress. This cannot be undone.'),
        actions: [
          TextButton(
            key: const Key('delete-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child:
                const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.onDelete?.call();
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Could not delete your data. '
                'Check your connection and try again.')),
      );
    }
  }

  Future<void> _runAccountAction(Future<bool> Function()? action) async {
    if (action == null) return;
    setState(() => _busy = true);
    try {
      final completed = await action();
      if (!mounted) return;
      if (!completed) {
        setState(() => _busy = false);
        return;
      }
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not update your account. Try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final playerId = widget.auth.currentUserId ?? '—';
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        foregroundColor: Colors.white,
        title: const Text('Profile'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Text(_avatar ?? '🙂', style: const TextStyle(fontSize: 56)),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _name ?? '',
              key: const Key('profile-name'),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Player ID',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
                const SizedBox(height: 6),
                InkWell(
                  key: const Key('profile-player-id'),
                  onTap: _copyPlayerId,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(playerId,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontFamily: 'monospace')),
                      ),
                      const Icon(Icons.copy, color: Colors.white54, size: 18),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tap to copy. Use this ID on connectmerge.app/'
                  'delete-my-data.html to erase your data from the web. '
                  'Keep it private — anyone with it can delete your account.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          ListTile(
            key: const Key('profile-change-name'),
            tileColor: AppColors.surface,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            leading: const Icon(Icons.edit, color: Colors.white70),
            title: const Text('Change name'),
            onTap: _busy ? null : widget.onChangeName,
          ),
          const SizedBox(height: 12),
          ListTile(
            key: Key(widget.auth.hasGoogleIdentity
                ? 'profile-sign-out'
                : 'profile-save-progress'),
            tileColor: AppColors.surface,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            leading: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(widget.auth.hasGoogleIdentity
                    ? Icons.logout
                    : Icons.cloud_upload),
            title: Text(widget.auth.hasGoogleIdentity
                ? 'Sign out'
                : 'Save your progress — Sign in with Google'),
            onTap: _busy
                ? null
                : () => _runAccountAction(widget.auth.hasGoogleIdentity
                    ? widget.onSignOut
                    : widget.onSaveProgress),
          ),
          const SizedBox(height: 12),
          ListTile(
            key: const Key('profile-delete'),
            tileColor: AppColors.surface,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            leading: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.redAccent))
                : const Icon(Icons.delete_forever, color: Colors.redAccent),
            title: const Text('Delete my data',
                style: TextStyle(color: Colors.redAccent)),
            subtitle: const Text(
                'Permanently erase your account and all progress.',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            onTap: _busy ? null : _confirmDelete,
          ),
        ],
      ),
    );
  }
}
