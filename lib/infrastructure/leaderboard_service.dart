import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/constants.dart';
import '../domain/models/difficulty.dart';
import '../domain/models/leaderboard_entry.dart';
import '../domain/models/move.dart';

/// Maps a raw Functions invocation outcome to the JSON map [SubmitResult.fromJson]
/// expects. A caught 422 [FunctionException] is treated the same as a normal
/// 2xx submit-score response — its decoded body lives on `.details` — since
/// `submit-score` always responds 422 for an application-level rejection, never
/// 200 with `valid:false`. Any other HTTP status (401, 403, 500, etc.) means the
/// exception is a transport/auth/server failure, not a submit-score verdict, and
/// is rethrown so callers can retry instead of misreading it as a rejection.
Future<Map<String, dynamic>> invokeSubmitScore(
  Future<FunctionResponse> Function() invoke,
) async {
  try {
    final res = await invoke();
    return asJsonMap(res.data);
  } on FunctionException catch (e) {
    if (e.status != 422) rethrow;
    return asJsonMap(e.details);
  }
}

/// Coerces a decoded response body to a JSON map, falling back to an explicit
/// `{'valid': false}` when the body isn't a map (matches [SubmitResult.fromJson]'s
/// existing safe-default behavior for a malformed response shape).
Map<String, dynamic> asJsonMap(dynamic data) {
  if (data is Map) return Map<String, dynamic>.from(data);
  return <String, dynamic>{'valid': false};
}

/// Result of a score submission (mirrors the Edge Function response).
class SubmitResult {
  final bool valid;
  final String? reason;
  final int score;
  final int highestTier;
  final int rank;

  const SubmitResult({
    required this.valid,
    this.reason,
    required this.score,
    required this.highestTier,
    required this.rank,
  });

  static SubmitResult fromJson(Map<String, dynamic> j) => SubmitResult(
        valid: (j['valid'] as bool?) ?? false,
        reason: j['reason'] as String?,
        score: (j['score'] as num?)?.toInt() ?? 0,
        highestTier: (j['highestTier'] as num?)?.toInt() ?? 0,
        rank: (j['rank'] as num?)?.toInt() ?? 0,
      );
}

/// Low-level transport seams. The defaults bind to a real [SupabaseClient];
/// tests inject fakes so the service's payload-shaping + response-mapping logic
/// can be exercised without the plugin.
typedef InvokeFn = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> body);
typedef RpcFn = Future<List<dynamic>> Function(
    String fn, Map<String, dynamic> params);

/// Submits replay-verified runs and fetches daily per-tier leaderboards.
///
/// The client NEVER submits a score number — only the move log. The
/// `submit-score` Edge Function replays it and computes the authoritative
/// score. Isolates supabase_flutter so callers depend on this service only.
class LeaderboardService {
  final InvokeFn _invoke;
  final RpcFn _rpc;

  /// Production constructor: wires the seams to [client].
  LeaderboardService(SupabaseClient client)
      : _invoke = ((fn, body) =>
            invokeSubmitScore(() => client.functions.invoke(fn, body: body))),
        _rpc = ((fn, params) async {
          final res = await client.rpc(fn, params: params);
          return (res as List?) ?? const [];
        });

  /// Test constructor: inject the transport seams directly.
  LeaderboardService.withSeams({required InvokeFn invoke, required RpcFn rpc})
      : _invoke = invoke,
        _rpc = rpc;

  /// Submit a completed run for verification. Sends the move log (and date +
  /// difficulty) to the `submit-score` function. Throws on transport errors so
  /// callers can queue + retry; returns an invalid [SubmitResult] when the
  /// server rejected the run.
  Future<SubmitResult> submitRun({
    required String date,
    required Difficulty difficulty,
    required List<MoveEvent> moveLog,
  }) async {
    final data = await _invoke('submit-score', {
      'date': date,
      'difficulty': difficulty.name,
      'moveLog': moveLog.map((e) => e.toJson()).toList(),
      'season': kLeaderboardSeason,
    });
    return SubmitResult.fromJson(data);
  }

  /// Fetch a tier's daily leaderboard (top [limit] + the caller's own row flag),
  /// via the `leaderboard` RPC.
  Future<List<LeaderboardEntry>> fetch({
    required Difficulty difficulty,
    required String date,
    int limit = 100,
  }) async {
    final rows = await _rpc('leaderboard', {
      'p_date': date,
      'p_diff': difficulty.name,
      'p_limit': limit,
      'p_season': kLeaderboardSeason,
    });
    return rows
        .map((e) =>
            LeaderboardEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Fetch an extended period leaderboard (weekly / monthly / all-time) for a
  /// tier via the read-only `leaderboard_period` RPC. The period total is the
  /// SUM of daily bests over `[from, to]`. The RPC returns a `total` column; it
  /// is mapped onto [LeaderboardEntry.score] so the UI row widget is reused.
  Future<List<LeaderboardEntry>> fetchPeriod({
    required Difficulty difficulty,
    required String from,
    required String to,
  }) async {
    final rows = await _rpc('leaderboard_period', {
      'p_diff': difficulty.name,
      'p_from': from,
      'p_to': to,
      'p_season': kLeaderboardSeason,
    });
    return rows
        .map((e) => LeaderboardEntry.fromPeriodJson(
            Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Fetch the caller's exact daily ranks over a bounded UTC date range.
  Future<Map<String, Map<Difficulty, int>>> myDailyRanks({
    required String from,
    required String to,
  }) async {
    final rows = await _rpc('my_daily_ranks', {
      'p_from': from,
      'p_to': to,
      'p_season': kLeaderboardSeason,
    });
    final ranks = <String, Map<Difficulty, int>>{};
    for (final row in rows) {
      final map = Map<String, dynamic>.from(row as Map);
      final date = map['utc_date'] as String;
      final difficulty = Difficulty.values.byName(map['difficulty'] as String);
      (ranks[date] ??= <Difficulty, int>{})[difficulty] =
          (map['rank'] as num).toInt();
    }
    return ranks;
  }

  /// Fetch the caller's exact per-tier ranks for one summed period.
  Future<Map<Difficulty, int>> myPeriodRanks({
    required String from,
    required String to,
  }) async {
    final rows = await _rpc('my_period_ranks', {
      'p_from': from,
      'p_to': to,
      'p_season': kLeaderboardSeason,
    });
    return {
      for (final row in rows)
        Difficulty.values.byName((row as Map)['difficulty'] as String):
            (row['rank'] as num).toInt(),
    };
  }
}
