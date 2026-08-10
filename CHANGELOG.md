# Changelog

## 1.2.0+7 (unreleased)

### New
- **Diagonal merges.** Chain tiles in all 8 directions now, not just up/down/left/right.
- **Chains add up.** Collapsing a chain now sums every tile's value and merges into the largest power-of-two that fits — long chains of the same tile (e.g. four 2's) combine cleanly into a much bigger tile, and mixed-value chains still merge, just with the leftover value discarded.
- Tiles can now grow past 2048 — there's no hard ceiling on how far a single tile can climb anymore.

### Notes
- This is a new scoring season: scores from before this update won't mix with scores after it on the leaderboard.
- Players on an older app version will have their runs rejected by the server until they update — this is expected during rollout.
