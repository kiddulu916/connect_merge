-- Feedback left on the delete-my-data web form.
--
-- Privacy model: this table deliberately has NO user id / player id column.
-- The whole point of the flow is erasure, so the feedback row keeps no link to
-- the deleted account — just an optional free-text reason and a username
-- snapshot typed by the user (collected as context, never validated).
--
-- Trust model: RLS enabled with NO policies = clients can neither read nor
-- write. Only the delete-account Edge Function (service role) inserts; rows are
-- read manually in the Supabase dashboard.
create table if not exists deletion_feedback (
  id bigint generated always as identity primary key,
  username text check (char_length(username) <= 40),
  reason text check (char_length(reason) <= 2000),
  created_at timestamptz default now()
);

alter table deletion_feedback enable row level security;
