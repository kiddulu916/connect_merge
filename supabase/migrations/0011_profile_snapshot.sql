-- Durable profile snapshots live on the player's existing self-owned row.
-- `snapshot_revision` is the authoritative database-row counter; the JSON
-- payload's separate `schema_version` describes its client serialization.
-- `active_device_id` makes the latest claim the only device allowed to push,
-- preventing two restored installs from overwriting each other's progress.

alter table public.players
  add column profile_snapshot jsonb,
  add column snapshot_revision int not null default 0,
  add column snapshot_updated_at timestamptz,
  add column active_device_id uuid,
  add constraint players_profile_snapshot_size_check
    check (
      profile_snapshot is null
      or octet_length(profile_snapshot::text) <= 262144
    );

-- SECURITY INVOKER RPCs need table privileges in addition to the existing
-- self-only RLS policy. Newer Supabase stacks no longer provide these grants
-- implicitly, so keep them explicit in the migration.
grant select, insert, update on table public.players to authenticated;

drop function if exists public.claim_profile(uuid);
drop function if exists public.push_profile(uuid, jsonb);

create function public.claim_profile(p_device uuid)
returns table(profile_snapshot jsonb, snapshot_revision int)
language plpgsql volatile security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'unauthenticated';
  end if;
  if p_device is null then
    raise exception 'device is required';
  end if;

  -- Claim and fetch are deliberately one UPDATE ... RETURNING statement. A
  -- separate fetch would let the previously active device push in between.
  return query
  update public.players as player
  set active_device_id = p_device
  where player.id = auth.uid()
  returning player.profile_snapshot, player.snapshot_revision;
end;
$$;

revoke execute on function public.claim_profile(uuid) from public, anon;
grant execute on function public.claim_profile(uuid) to authenticated;

create function public.push_profile(p_device uuid, p_snapshot jsonb)
returns boolean
language plpgsql volatile security invoker
set search_path = public
as $$
declare
  v_pushed boolean := false;
begin
  if auth.uid() is null then
    raise exception 'unauthenticated';
  end if;
  if p_device is null then
    raise exception 'device is required';
  end if;
  if p_snapshot is null then
    raise exception 'snapshot is required';
  end if;

  -- The device guard and mutation are one atomic UPDATE ... RETURNING. A
  -- zero-row result is coerced to false for a superseded device.
  update public.players as player
  set profile_snapshot = p_snapshot,
      snapshot_revision = player.snapshot_revision + 1,
      snapshot_updated_at = now()
  where player.id = auth.uid()
    and player.active_device_id = p_device
  returning true into v_pushed;

  return coalesce(v_pushed, false);
end;
$$;

revoke execute on function public.push_profile(uuid, jsonb) from public, anon;
grant execute on function public.push_profile(uuid, jsonb) to authenticated;
