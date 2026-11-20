-- ============================================================
--  JAMMY — 13_match_repair.sql
--  MATCHES THAT NEVER HAPPENED. Run after 01–12.
--
--  WHAT WENT WRONG
--  A mutual yes is supposed to create two things: a connection,
--  and the conversation that goes with it. A trigger did that,
--  and the trigger fired on INSERT.
--
--  But swiping is an upsert — swipe on the same person twice
--  and the second one UPDATES the existing row. An update is
--  not an insert, so the trigger stayed silent. Anyone who had
--  swiped before (every one of your test runs) could match and
--  have nothing created for it.
--
--  The app then looked connected while the database disagreed:
--  the connections list emptied on the next load, and sending a
--  message failed because there was no conversation to put it
--  in.
--
--  THE FIX, in three parts:
--    1. one function that makes a connection real, used by
--       everything, so there is one definition of what a match
--       creates rather than two that can drift apart
--    2. the trigger fires on update as well as insert
--    3. every mutual yes already sitting in the table gets the
--       connection it should have had
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. One place that knows what a match creates
-- ------------------------------------------------------------
create or replace function ensure_connection(a uuid, b uuid)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  lo uuid := least(a, b);
  hi uuid := greatest(a, b);
  conv uuid;
begin
  if a is null or b is null or a = b then return null; end if;

  insert into connections (a_id, b_id) values (lo, hi) on conflict do nothing;

  select c.id into conv
  from conversations c
  join conversation_members m1 on m1.conversation_id = c.id and m1.user_id = lo
  join conversation_members m2 on m2.conversation_id = c.id and m2.user_id = hi
  where c.kind = 'dm'
  limit 1;

  if conv is null then
    insert into conversations (kind) values ('dm') returning id into conv;
    insert into conversation_members (conversation_id, user_id)
      values (conv, lo), (conv, hi)
    on conflict do nothing;
  end if;

  return conv;
end $$;

-- ------------------------------------------------------------
--  2. Fire on an update too
-- ------------------------------------------------------------
create or replace function on_swipe() returns trigger as $$
begin
  if new.direction <> 'yes' then return new; end if;

  if not exists (
    select 1 from swipes
    where from_id = new.to_id and to_id = new.from_id and direction = 'yes'
  ) then return new; end if;

  perform ensure_connection(new.from_id, new.to_id);
  return new;
end $$ language plpgsql security definer set search_path = public, extensions;

drop trigger if exists swipe_match on swipes;
create trigger swipe_match
  after insert or update of direction on swipes
  for each row execute function on_swipe();

-- ------------------------------------------------------------
--  3. Don't depend on the trigger alone
--
--  swipe_and_check already looks to see whether a connection
--  exists. It now makes one if the other person has said yes,
--  rather than reporting "no match" because a trigger missed.
-- ------------------------------------------------------------
create or replace function swipe_and_check(to_user uuid, dir text)
returns table (matched boolean, conversation_id uuid)
language plpgsql security definer set search_path = public, extensions as $$
declare
  me   uuid := (select auth.uid());
  conv uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  if to_user is null or to_user = me then raise exception 'no such person'; end if;
  if dir not in ('yes','no') then raise exception 'a swipe is yes or no'; end if;

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

  -- do they want to as well?
  if not exists (
    select 1 from swipes
    where from_id = to_user and to_id = me and direction = 'yes'
  ) then
    return query select false, null::uuid;
    return;
  end if;

  conv := ensure_connection(me, to_user);
  return query select true, conv;
end $$;

-- ------------------------------------------------------------
--  4. Repair every match that was lost
--
--  Walks the swipes already in the table, finds every pair who
--  said yes to each other, and gives each one the connection
--  and conversation it should have had. Nothing is created
--  twice.
-- ------------------------------------------------------------
do $$
declare
  r record;
  made int := 0;
begin
  for r in
    select distinct least(s1.from_id, s1.to_id) as lo,
                    greatest(s1.from_id, s1.to_id) as hi
    from swipes s1
    join swipes s2
      on s2.from_id = s1.to_id
     and s2.to_id   = s1.from_id
     and s2.direction = 'yes'
    where s1.direction = 'yes'
  loop
    if not exists (select 1 from connections where a_id = r.lo and b_id = r.hi) then
      made := made + 1;
    end if;
    perform ensure_connection(r.lo, r.hi);
  end loop;

  raise notice 'Jammy: repaired % lost match(es). Matching and messaging now agree.', made;
end $$;
