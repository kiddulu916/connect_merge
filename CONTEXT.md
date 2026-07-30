# Domain Context

Project domain glossary and vocabulary. See `README.md` for gameplay rules and
`CLAUDE.md` for architecture. Architecture-review terms (module, seam, depth,
adapter, leverage, locality) come from the `codebase-design` skill.

## Account & Sync Outcome Vocabulary

The account-linking / cloud-sync flow uses **five outcome types across three
abstraction levels**. They are intentionally distinct (not a single enum): each
level exposes only what its consumers need, and the lower levels' detail is
deliberately hidden from the higher ones (information hiding). Architecture
reviews should NOT collapse these into one type — doing so mixes levels, leaks
protocol detail up to the router, and loses the type safety that a routing
function returns only routes. (Candidate #6 of the 2026-07 review; declined.)

### Level 1 — Protocol results (`ProfileSyncService`, low-level)
- **`SnapshotOutcome`** — the raw result of a claim/restore operation against the
  cloud: `restored`, `missingPlayerRow`, `emptySnapshot`, `corrupt`, `oversized`,
  `newerVersion`, `superseded`, `pushFailed`.
- **`ProfilePushOutcome`** — the raw result of a push: `clean`, `pushed`,
  `failed`, `superseded`.

### Level 2 — Flow results (mid-level)
- **`BootstrapOutcome`** (`ProfileSyncService`) — the result of app-launch
  bootstrap, combining a protocol result with local-owner state: `ready`,
  `offlineReady`, `needsAuthGate`, `restored`, `emptySnapshot`,
  `missingPlayerRow`, `blockedRecovery`, `blockedInterruptedRestore`.
- **`GoogleFlowOutcome`** (`account_flow_controller`) — the UI-facing result of a
  Google sign-in/link flow, carrying collision/adopt semantics:
  `linkedNeedsDisplayName`, `linkedReady`, `collision`, `adoptedNeedsDisplayName`,
  `adoptedReady`, `blockedRecovery`.

### Level 3 — Route (high-level, `account_flow_controller`)
- **`InitialAccountRoute`** — the only four roots the app may expose: `ready`,
  `authGate`, `displayName`, `recovery`.

### Translation flow

```
push_profile RPC ──▶ ProfilePushOutcome
                        │  (claimAndPushLocal folds into a SnapshotOutcome:
                        │   pushed|clean→restored, superseded→superseded,
                        ▼   failed→pushFailed)
claim/restore  ──▶ SnapshotOutcome
                        │  (_bootstrapRestore maps to BootstrapOutcome:
                        │   restored→restored, emptySnapshot→emptySnapshot,
                        │   missingPlayerRow→missingPlayerRow,
                        ▼   everything else → blockedRecovery  ← detail hidden)
bootstrap()    ──▶ BootstrapOutcome ──┐
                                      │  initialAccountRoute(bootstrap,
Google flow    ──▶ GoogleFlowOutcome  │    needsDisplayName, hasGoogleIdentity)
                                      ▼
                              InitialAccountRoute
```

**The load-bearing routing rule** (`initialAccountRoute`, documented at the
function): a linked-Google user who crashed BEFORE choosing a name must resume
name creation (`displayName`), never return to the provider gate — otherwise
they could select a different Google account. `missingPlayerRow` means BOTH a
fresh guest AND a just-linked user, so the route disambiguates via
`hasGoogleIdentity`: only a committed Google identity bypasses the `authGate`.

**Why not collapse:** the `everything-else → blockedRecovery` mapping is
deliberate information hiding — the router does not need to know WHY recovery is
blocked (`corrupt` vs `oversized` vs `newerVersion`), only that it is. A single
mega-enum would force every consumer to handle protocol detail it should not see.
