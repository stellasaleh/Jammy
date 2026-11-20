-- ============================================================
--  JAMMY — SETUP, PART 2
--
--  Run this in the Supabase SQL Editor the same way as the first
--  file: New query, paste, Run, confirm the dialog.
--
--  It adds what messaging and matching need:
--    * the message list, built in one request instead of forty
--    * opening a conversation with someone you've matched with
--    * a band's group chat
--    * recording a swipe AND finding out whether it matched
--
--  Nothing here changes anything you already have. Safe to run
--  more than once.
-- ============================================================



-- ############################################################
-- ##  08_chat.sql
-- ############################################################

-- ============================================================
--  JAMMY — 08_chat.sql
--  THE CONVERSATION LIST. Run this after 01–07.
--
--  The app's message list needs, for every conversation: who it
--  is with, their photo, the last thing said, when, and how many
--  messages you haven't read.
--
--  Done naively that is one query for the list and then four
--  more per row — forty queries to draw ten conversations, every
--  time the screen opens. This does it in one.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. Everything the message list needs, in one round trip
-- ------------------------------------------------------------
create or replace function my_conversations()
returns table (
  conversation_id uuid,
  kind            text,
  band_id         uuid,
  other_id        uuid,
  other_name      text,
  other_handle    text,
  other_city      text,
  other_photo     text,
  band_name       text,
  last_body       text,
  last_clip_label text,
  last_duration_ms int,
  last_sender_id  uuid,
  last_at         timestamptz,
  unread          int
)
language sql stable security definer set search_path = public as $$
  with me as (select (select auth.uid()) as uid),
  mine as (
    select cm.conversation_id, cm.last_read_at, c.kind, c.band_id
    from conversation_members cm
    join conversations c on c.id = cm.conversation_id
    cross join me
    where cm.user_id = me.uid
  ),
  -- the other person in a DM. band chats have no single "other".
  partner as (
    select m.conversation_id, cm.user_id as other_id
    from mine m
    join conversation_members cm
      on cm.conversation_id = m.conversation_id
    cross join me
    where m.kind = 'dm' and cm.user_id <> me.uid
  ),
  -- one last message per conversation, without scanning the whole table
  last_msg as (
    select distinct on (msg.conversation_id)
           msg.conversation_id, msg.body, msg.clip_label,
           msg.clip_duration_ms, msg.sender_id, msg.created_at
    from messages msg
    where msg.conversation_id in (select conversation_id from mine)
    order by msg.conversation_id, msg.created_at desc
  ),
  unread_counts as (
    select msg.conversation_id, count(*)::int as n
    from messages msg
    join mine m on m.conversation_id = msg.conversation_id
    cross join me
    where msg.created_at > m.last_read_at
      and msg.sender_id is distinct from me.uid
    group by msg.conversation_id
  )
  select
    m.conversation_id,
    m.kind,
    m.band_id,
    p.other_id,
    prof.display_name,
    prof.handle,
    prof.city,
    prof.photo_path,
    b.name,
    lm.body,
    lm.clip_label,
    lm.clip_duration_ms,
    lm.sender_id,
    lm.created_at,
    coalesce(u.n, 0)
  from mine m
  left join partner       p    on p.conversation_id = m.conversation_id
  left join profiles      prof on prof.id = p.other_id
  left join bands         b    on b.id = m.band_id
  left join last_msg      lm   on lm.conversation_id = m.conversation_id
  left join unread_counts u    on u.conversation_id = m.conversation_id
  -- a blocked person's conversation drops out of the list entirely
  where p.other_id is null or not exists (
    select 1 from blocks
    where (blocker_id = p.other_id and blocked_id = (select auth.uid()))
       or (blocker_id = (select auth.uid()) and blocked_id = p.other_id)
  )
  order by lm.created_at desc nulls last;
$$;

-- ------------------------------------------------------------
--  2. Open a DM with someone
--
--  A mutual match already creates the conversation automatically.
--  This is the safety net: it finds the existing one, or makes it
--  if it somehow doesn't exist.
--
--  It runs with elevated rights because the app is deliberately
--  not allowed to create conversations directly — otherwise
--  anyone could open a channel to a stranger. So this checks the
--  one thing that matters first: that you two are connected.
-- ------------------------------------------------------------
create or replace function dm_with(other uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me   uuid := (select auth.uid());
  lo   uuid;
  hi   uuid;
  conv uuid;
begin
  if me is null then
    raise exception 'not signed in';
  end if;
  if other is null or other = me then
    raise exception 'no such person';
  end if;

  -- blocked either way: no conversation, no hints
  if exists (
    select 1 from blocks
    where (blocker_id = me and blocked_id = other)
       or (blocker_id = other and blocked_id = me)
  ) then
    raise exception 'unavailable';
  end if;

  lo := least(me, other);
  hi := greatest(me, other);

  -- you must already be connected. this is the gate.
  if not exists (select 1 from connections where a_id = lo and b_id = hi) then
    raise exception 'you are not connected to this person';
  end if;

  select c.id into conv
  from conversations c
  join conversation_members m1 on m1.conversation_id = c.id and m1.user_id = lo
  join conversation_members m2 on m2.conversation_id = c.id and m2.user_id = hi
  where c.kind = 'dm'
  limit 1;

  if conv is null then
    insert into conversations (kind) values ('dm') returning id into conv;
    insert into conversation_members (conversation_id, user_id)
      values (conv, lo), (conv, hi);
  end if;

  return conv;
end $$;

-- ------------------------------------------------------------
--  3. The band's group chat
--
--  Every band gets one conversation. Joining the band puts you
--  in it; this hands back its id and makes sure you're a member.
-- ------------------------------------------------------------
create or replace function band_conversation(band uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me   uuid := (select auth.uid());
  conv uuid;
begin
  if me is null then
    raise exception 'not signed in';
  end if;
  if not is_band_member(band) then
    raise exception 'you are not in this band';
  end if;

  select id into conv from conversations
  where kind = 'band' and band_id = band limit 1;

  if conv is null then
    insert into conversations (kind, band_id) values ('band', band) returning id into conv;
  end if;

  -- every current member belongs in it, including anyone who
  -- joined before the chat existed
  insert into conversation_members (conversation_id, user_id)
  select conv, bm.user_id from band_members bm where bm.band_id = band
  on conflict do nothing;

  return conv;
end $$;

-- ------------------------------------------------------------
--  4. Senders, for a band chat
--
--  A band thread shows who said what. One query for the roster
--  beats one query per message.
-- ------------------------------------------------------------
create or replace function conversation_people(convo uuid)
returns table (id uuid, display_name text, handle text, photo_path text)
language sql stable security definer set search_path = public as $$
  select p.id, p.display_name, p.handle, p.photo_path
  from conversation_members cm
  join profiles p on p.id = cm.user_id
  where cm.conversation_id = convo
    and in_conversation(convo);     -- you must be in it to ask
$$;

-- ------------------------------------------------------------
--  5. Speed
-- ------------------------------------------------------------
create index if not exists messages_convo_time_idx
  on messages (conversation_id, created_at desc);
create index if not exists conv_members_user_convo_idx
  on conversation_members (user_id, conversation_id);

-- ------------------------------------------------------------
--  6. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('my_conversations','dm_with','band_conversation','conversation_people');
  if n = 4 then
    raise notice 'Jammy: messaging functions are in place.';
  else
    raise exception 'Jammy: expected 4 messaging functions, found %', n;
  end if;
end $$;


-- ############################################################
-- ##  09_swipe.sql
-- ############################################################

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
language plpgsql security definer set search_path = public as $$
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
language sql stable security definer set search_path = public as $$
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
