-- ============================================================
--  25_live_and_leaving.sql
--
--  Two things the first real tester found in fifteen minutes that
--  nothing automated had caught in weeks.
--
--  1. MESSAGES DID NOT ARRIVE until the page was reloaded.
--
--     The app subscribes to new messages correctly and always has.
--     Supabase only broadcasts changes for tables that have been
--     added to its realtime publication, and `messages` never was.
--     post_comments and post_likes were added back in 04; messages
--     was missed. So the server simply never told anybody, and two
--     people having a conversation each had to pull to refresh.
--
--     No test caught it because every test fakes the server, and a
--     fake that calls the callback is not evidence that Postgres
--     would have.
--
--  2. THERE WAS NO WAY OUT OF A CONNECTION.
--
--     You could connect with somebody and never undo it. Blocking
--     existed, but blocking is for someone who frightens you. Most
--     people who want out of a connection just played together
--     once and it did not work, and making them block a person to
--     do that is a bad choice to force on anybody.
-- ============================================================

-- ------------------------------------------------------------
--  1. Let the server speak
-- ------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table messages;
exception when duplicate_object then null;
end $$;

--  The chat list shows the newest message under each name, so it
--  wants telling too.
do $$
begin
  alter publication supabase_realtime add table conversation_members;
exception when duplicate_object then null;
end $$;

-- ------------------------------------------------------------
--  2. Disconnecting
--
--  Quieter than a block and it goes both ways, because a
--  connection is a mutual thing and ending it one-sidedly would
--  leave the other person talking to somebody who is not there.
--
--  The conversation goes with it, for both people, the same way
--  unmatching works everywhere else — which is the model people
--  already carry in their heads. The first version of this left
--  conversation_members alone, which would have kept the chat
--  sitting in both lists while the connection was gone: the app
--  would have been promising something the database did not do.
--
--  The message rows themselves are not deleted. Nobody can reach
--  them, because reaching a conversation requires membership in
--  it, but they are not destroyed either: a safety report about
--  something said in that conversation still needs them to exist.
-- ------------------------------------------------------------
create or replace function disconnect_from(who uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  me  uuid := auth.uid();
  lo  uuid;
  hi  uuid;
begin
  if me is null then
    raise exception 'not signed in';
  end if;
  if who is null or who = me then
    raise exception 'pick somebody else';
  end if;

  --  connections stores the pair in a fixed order (a_id < b_id)
  lo := least(me, who);
  hi := greatest(me, who);

  delete from connections where a_id = lo and b_id = hi;

  --  Forget the swipes as well, in both directions. Without this
  --  the person stays filtered out of Discover for ever, so two
  --  people who drifted apart could never find each other again
  --  even if both wanted to. Clearing them puts each back in the
  --  other's deck. It also clears any pending request between
  --  them, because a request IS a one-sided swipe here — there is
  --  no separate table — so this leaves neither of them holding an
  --  invitation to a connection that no longer exists.
  delete from swipes
   where (from_id = me  and to_id = who)
      or (from_id = who and to_id = me);

  --  And take the direct conversation off both people's lists.
  --  my_conversations() reads conversation_members, so without this
  --  the chat would still be sitting there after the connection
  --  ended — which is precisely what the app tells them will not
  --  happen. Band conversations are untouched: leaving a band is a
  --  different thing and has its own door.
  delete from conversation_members cm
   using conversations c
   where c.id = cm.conversation_id
     and c.kind = 'dm'
     and cm.conversation_id in (
       select a.conversation_id
         from conversation_members a
         join conversation_members b on b.conversation_id = a.conversation_id
        where a.user_id = me and b.user_id = who
     );
end $$;

revoke all on function disconnect_from(uuid) from public;
grant execute on function disconnect_from(uuid) to authenticated;
