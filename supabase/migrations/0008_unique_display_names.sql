-- Display-name uniqueness (case-insensitive).
--
-- Names were originally non-unique (rank is by score), but unique names prevent
-- leaderboard impersonation. Enforced at the DB so the client upsert in
-- AuthService.setDisplayName is race-proof: the client catches the
-- unique-violation (23505) and shows "That name is already taken."
-- Case-insensitive via lower() so "Dave" blocks "dave"/"DAVE".
--
-- Prod was verified duplicate-free before this ships; if a duplicate ever
-- sneaks in first, this CREATE fails loudly rather than silently dropping rows.
create unique index if not exists players_display_name_lower_ux
  on players (lower(display_name));
