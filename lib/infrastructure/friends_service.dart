import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/constants.dart';
import '../domain/models/difficulty.dart';
import '../domain/models/friend.dart';
import '../domain/models/leaderboard_entry.dart';
import 'contacts_hasher.dart';

/// Transport seams (mirror [LeaderboardService]). Defaults bind to a real
/// [SupabaseClient]; tests inject fakes to exercise payload-shaping logic
/// without the plugin.
typedef RpcResultFn = Future<dynamic> Function(
    String fn, Map<String, dynamic> params);
typedef InvokeMapFn = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> body);
typedef TableInsertFn = Future<void> Function(
    String table, List<Map<String, dynamic>> rows);
typedef TableDeleteFn = Future<void> Function(String table);
typedef TableSelectFn = Future<List<dynamic>> Function(String table);

/// Friend codes, redeeming, friends list, friends leaderboard, and the
/// privacy-first contacts opt-in + match flow. Isolates supabase_flutter so no
/// screen imports the plugin (mirrors [LeaderboardService]).
class FriendsService {
  final RpcResultFn _rpc;
  final InvokeMapFn _invoke;
  final TableInsertFn _insert;
  final TableDeleteFn _deleteMine;
  final TableSelectFn _selectMine;

  /// Production constructor: wires the seams to [client]. [client] is used for
  /// the current user id when creating contact-hash rows.
  FriendsService(SupabaseClient client)
      : _rpc = ((fn, params) async => client.rpc(fn, params: params)),
        _invoke = ((fn, body) async {
          final res = await client.functions.invoke(fn, body: body);
          final data = res.data;
          if (data is Map) return Map<String, dynamic>.from(data);
          return <String, dynamic>{};
        }),
        _insert = ((table, rows) async {
          await client.from(table).insert(rows);
        }),
        _deleteMine = ((table) async {
          final uid = client.auth.currentUser?.id;
          if (uid == null) return;
          await client.from(table).delete().eq('player_id', uid);
        }),
        _selectMine = ((table) async {
          final uid = client.auth.currentUser?.id;
          if (uid == null) return const [];
          final res = await client.from(table).select().eq('player_id', uid);
          return (res as List?) ?? const [];
        });

  /// Test constructor: inject seams directly.
  FriendsService.withSeams({
    required RpcResultFn rpc,
    required InvokeMapFn invoke,
    required TableInsertFn insert,
    required TableDeleteFn deleteMine,
    required TableSelectFn selectMine,
  })  : _rpc = rpc,
        _invoke = invoke,
        _insert = insert,
        _deleteMine = deleteMine,
        _selectMine = selectMine;

  /// Ensure the player has a friend code (lazily allocated server-side) and
  /// return it. Backed by the `ensure_friend_code` RPC.
  Future<String> myFriendCode() async {
    final res = await _rpc('ensure_friend_code', const {});
    if (res is String) return res;
    // Some clients wrap scalar RPC results in a single-element list.
    if (res is List && res.isNotEmpty) return res.first.toString();
    return res.toString();
  }

  /// Build the deep link a friend taps to add you.
  static String inviteLink(String code) => 'connectmerge://invite/$code';

  /// Build the https fallback invite link.
  static String inviteHttpsLink(String code) =>
      'https://connectmerge.app/invite/$code';

  /// Redeem a friend code (typed or from a deep link). Creates the mutual edge
  /// via the `redeem_code` RPC (rejects self-add; idempotent).
  Future<RedeemResult> redeemCode(String code) async {
    final res = await _rpc('redeem_code', {'p_code': code.trim()});
    if (res is Map) {
      return RedeemResult.fromJson(Map<String, dynamic>.from(res));
    }
    return const RedeemResult(RedeemStatus.error);
  }

  /// Fetch the friends leaderboard for a tier/day (self + friends who played),
  /// mapped to [LeaderboardEntry] so it can reuse the Phase 2 row widget.
  Future<List<LeaderboardEntry>> friendsLeaderboard({
    required Difficulty difficulty,
    required String date,
  }) async {
    final res = await _rpc('friends_leaderboard', {
      'p_date': date,
      'p_diff': difficulty.name,
      'p_season': kLeaderboardSeason,
    });
    final rows = (res as List?) ?? const [];
    return rows
        .map((e) =>
            LeaderboardEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Fetch a friends period board and map its total onto the shared score row.
  Future<List<LeaderboardEntry>> friendsLeaderboardPeriod({
    required Difficulty difficulty,
    required String from,
    required String to,
  }) async {
    final res = await _rpc('friends_leaderboard_period', {
      'p_diff': difficulty.name,
      'p_from': from,
      'p_to': to,
      'p_season': kLeaderboardSeason,
    });
    final rows = (res as List?) ?? const [];
    return rows.map((row) {
      final map = Map<String, dynamic>.from(row as Map);
      return LeaderboardEntry(
        rank: (map['rank'] as num).toInt(),
        displayName: map['display_name'] as String,
        score: (map['total'] as num).toInt(),
        isMe: (map['is_me'] as bool?) ?? false,
      );
    }).toList();
  }

  /// Opt in to contacts matching: store SHA256 hashes of the player's OWN
  /// normalized phone/email so other players can match them. Raw values are
  /// hashed by the caller via [ContactsHasher] before reaching this method —
  /// this method only ever sees hashes.
  ///
  /// [ownIdentifiers] are the player's raw phone/email; they are hashed here on
  /// device and only the hashes are stored.
  Future<void> optInContacts(List<String> ownIdentifiers) async {
    final hashes = ContactsHasher.hashAll(ownIdentifiers);
    if (hashes.isEmpty) return;
    await _insert(
      'contact_hashes',
      [
        for (final h in hashes) {'hash': h}
      ],
    );
  }

  /// Revoke contacts opt-in: delete the player's stored contact hashes.
  Future<void> revokeContacts() async {
    await _deleteMine('contact_hashes');
  }

  /// True when the player currently has stored contact hashes (opted in).
  Future<bool> isOptedInToContacts() async {
    final rows = await _selectMine('contact_hashes');
    return rows.isNotEmpty;
  }

  /// Match device contacts against opted-in players. Hashes [rawContacts] on
  /// device (raw values NEVER sent) and posts only hashes to `match-contacts`.
  /// Returns the matched opted-in players.
  Future<List<Friend>> matchContacts(List<String> rawContacts) async {
    final hashes = ContactsHasher.hashAll(rawContacts);
    if (hashes.isEmpty) return const [];
    final data = await _invoke('match-contacts', {'hashes': hashes});
    final matches = (data['matches'] as List?) ?? const [];
    return matches
        .map((e) => Friend.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
