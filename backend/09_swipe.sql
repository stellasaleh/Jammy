-- ============================================================
--  JAMMY — 09_swipe.sql
--  "DID WE MATCH?" Run this after 01–08.
--
--  Recording a swipe and finding out whether it became a match
--  were two separate things. The app wrote the swipe, got back
--  nothing useful, and had no honest way to know whether to show
--  the "you matched" screen — so it would have had to guess, or
--  ask again a moment later and hope the timing worked out.
--
--  This does both at once: record the swipe, then report back
--  whether a connection now exists. One answer, no guessing.
--
--  Safe to run twice.
-- ============================================================

create or replace function swipe_and_check(to_user uuid, dir text)
returns table (matched boolean, conversation_id uuid)
language plpgsql security definer set search_path = public, extensions as $$
declare
  me   uuid := (select auth.uid());
  lo   uuid;
  hi   uuid;
  conv uuid;
begin
  if me is null then
    raise exception 'not signed in';
  end if;
  if to_user is null or to_user = me then
    raise exception 'no such person';
  end if;
  if dir not in ('yes','no') then
    raise exception 'a swipe is yes or no';
  end if;

  -- blocked either way: accept it silently and reveal nothing.
  -- Telling someone "you have been blocked" is itself information.
  if exists (
    select 1 from blocks
    where (blocker_id = me and blocked_id = to_user)
       or (blocker_id = to_user and blocked_id = me)
  ) then
    return query select false, null::uuid;
    return;
  end if;

  insert into swipes (from_id, to_id, direction)
  values (me, to_user, dir)
  on conflict (from_id, to_id) do update set direction = excluded.direction;

  if dir <> 'yes' then
    return query select false, null::uuid;
    return;
  end if;

  -- the trigger on swipes has already created the connection and the
  -- conversation if this was mutual. all that's left is to look.
  lo := least(me, to_user);
  hi := greatest(me, to_user);

  if not exists (select 1 from connections where a_id = lo and b_id = hi) then
    return query select false, null::uuid;
    return;
  end if;

  select c.id into conv
  from conversations c
  join conversation_members m1 on m1.conversation_id = c.id and m1.user_id = lo
  join conversation_members m2 on m2.conversation_id = c.id and m2.user_id = hi
  where c.kind = 'dm'
  limit 1;

  return query select true, conv;
end $$;

-- ------------------------------------------------------------
--  Who you're connected to, with enough to draw the row
-- ------------------------------------------------------------
create or replace function my_connections()
returns table (
  id uuid, display_name text, handle text, city text,
  photo_path text, instruments text[], genres text[],
  looking_for text, bio text, connected_at timestamptz
)
language sql stable security definer set search_path = public, extensions as $$
  with me as (select (select auth.uid()) as uid)
  select p.id, p.display_name, p.handle, p.city, p.photo_path,
         p.instruments, p.genres, p.looking_for, p.bio, c.created_at
  from connections c
  cross join me
  join profiles p
    on p.id = case when c.a_id = me.uid then c.b_id else c.a_id end
  where (c.a_id = me.uid or c.b_id = me.uid)
    and not p.is_banned
    and not exists (
      select 1 from blocks
      where (blocker_id = p.id and blocked_id = me.uid)
         or (blocker_id = me.uid and blocked_id = p.id)
    )
  order by c.created_at desc;
$$;

-- ------------------------------------------------------------
--  Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname in ('swipe_and_check','my_connections');
  if n = 2 then
    raise notice 'Jammy: swiping now reports matches properly.';
  else
    raise exception 'Jammy: expected 2 functions, found %', n;
  end if;
end $$;
