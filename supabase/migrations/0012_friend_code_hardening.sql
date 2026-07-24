-- Referral links are public input, so friend codes must have one canonical
-- shape before the client starts accepting them from install referrers.
do $$
declare
  v_invalid bigint;
begin
  select count(*) into v_invalid
  from public.players
  where friend_code is not null
    and friend_code !~ '^[A-Z2-7]{8}$';

  if v_invalid > 0 then
    raise notice 'Clearing % invalid friend codes for re-allocation', v_invalid;
    update public.players
    set friend_code = null
    where friend_code is not null
      and friend_code !~ '^[A-Z2-7]{8}$';
  end if;

  if exists (
    select 1
    from public.players
    where friend_code is not null
      and friend_code !~ '^[A-Z2-7]{8}$'
  ) then
    raise exception 'friend-code repair preflight failed';
  end if;
end;
$$;

alter table public.players
  add constraint players_friend_code_format
  check (friend_code ~ '^[A-Z2-7]{8}$');

-- Allocate only if this transaction wins the NULL -> code update. A concurrent
-- caller that won first is re-selected and returned instead of being overwritten.
create or replace function public.ensure_friend_code()
returns text
language plpgsql security invoker
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_existing text;
  v_code text;
  v_alphabet text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  i int;
  attempt int := 0;
begin
  if v_me is null then
    raise exception 'unauthenticated';
  end if;

  select friend_code into v_existing
  from public.players
  where id = v_me;

  if v_existing is not null then
    return v_existing;
  end if;

  loop
    attempt := attempt + 1;
    v_code := '';
    for i in 1..8 loop
      v_code := v_code ||
        substr(
          v_alphabet,
          1 + floor(random() * length(v_alphabet))::int,
          1
        );
    end loop;

    begin
      update public.players
      set friend_code = v_code
      where id = v_me
        and friend_code is null
      returning friend_code into v_existing;

      if found then
        return v_existing;
      end if;

      select friend_code into v_existing
      from public.players
      where id = v_me;

      if v_existing is not null then
        return v_existing;
      end if;

      raise exception 'player row not found';
    exception when unique_violation then
      if attempt > 10 then
        raise exception 'could not allocate friend code';
      end if;
    end;
  end loop;
end;
$$;
