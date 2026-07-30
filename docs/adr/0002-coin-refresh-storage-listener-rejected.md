# ADR 0002: Coin-refresh stays as explicit pokes; storage-listener fan-out rejected

**Status:** Accepted (2026-07-30)
**Context:** Architecture-review candidate #5 ("a single 'coins moved' authority")

## Decision

Keep the current explicit coin-refresh calls (`LootCubit.load()` in
`game_session_factory`, `EngagementCubit.refreshWallet()` in `game_screen` /
`avatars_screen` / `cosmetics_screen`). **Do NOT** make `LootCubit` /
`EngagementCubit` subscribe to `StorageService`'s change-listener to
auto-refresh coins.

## Why

The review flagged the scattered "who to poke when coins change" knowledge as
friction, and a plan was drafted to have the two coin-caching cubits subscribe
to storage's existing `addChangeListener` and self-refresh. Adversarial review
(Codex, gpt-5.6-sol) surfaced that the fix is substantially more complex than
the friction it removes:

1. **Self-write intermediate emits.** `_notifyChanged()` fires *synchronously*
   during a cubit's own writes, so a purchase / prize payout / loot claim would
   emit coins-only *before* its real state (an observable intermediate flash,
   and it breaks the one-emission test). Avoiding this requires **deferred +
   coalesced** listener refreshes with timer teardown — in both cubits.
2. `EngagementCubit.close()` isn't called in production (only `loot` is
   disposed), so the listener would leak.
3. Post-`await` explicit emits in claim/purchase/prize need `isClosed` guards
   to avoid emit-after-close once more emit paths exist.
4. `loot.load()` at `game_session_factory` refreshes daily **claimability**,
   not just coins, so it must stay regardless — removing the main benefit.
5. `EngagementCubit` starts at zero coins; deleting the screen refreshes risks
   gating purchases against a stale/zero balance without seeding.

After #4 and #5, the change reduces to "delete three `initState`
`refreshWallet()` calls" at the cost of deferred-coalesced listener machinery
in two cubits. The deletion test inverts: the fix concentrates MORE complexity
than the friction. The explicit pokes are simple, correct, and cheap.

## Consequences

- Future architecture reviews should NOT re-suggest the storage-listener
  coin-refresh design.
- If a genuine "coins moved" authority is ever wanted, the better shape is a
  dedicated **`WalletCubit`** with explicit credit/spend ops (which sidesteps
  the broad-signal self-write-notify problem), NOT subscribing to the generic
  storage-change signal.
- A tiny optional hardening remains available independently: seed
  `EngagementCubit`'s initial `EngagementState.coins` from storage in its
  constructor (removes a zero-coin cold-start window). Not done here.
