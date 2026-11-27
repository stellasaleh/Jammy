-- ============================================================
--  27_my_blocks.sql — let people see who they blocked
--
--  A catch-22, and a neat one.
--
--  The "read profiles" policy hides anyone blocked in either
--  direction, which is right: a blocked person should not be able
--  to look you up, and you should not keep seeing them.
--
--  But it applies on the Blocked accounts screen too. So the app
--  asked for your blocks with a join to profiles, and the join
--  came back empty — you cannot read the profile of the person
--  you blocked, BECAUSE you blocked them. The screen had a row
--  with no name on it, which is exactly where a name is needed:
--  a list of people to choose between.
--
--  This returns the names, and only ever your own blocks.
--
--  What it deliberately does NOT do is say who has blocked YOU.
--  blocked_between() answers yes or no and nothing else, on
--  purpose, so that being blocked stays invisible. That property
--  is untouched here: the where clause is blocker_id = auth.uid(),
--  so this only ever tells you about an action you took yourself.
-- ============================================================

create or replace function my_blocks()
returns table (
  blocked_id   uuid,
  display_name text,
  handle       text,
  photo_path   text,
  city         text,
  created_at   timestamptz
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select b.blocked_id,
         p.display_name,
         p.handle,
         p.photo_path,
         p.city,
         b.created_at
    from blocks b
    --  left join: if the account has since been deleted there is no
    --  profile row, and the block should still be listed and still be
    --  undoable rather than quietly disappearing
    left join profiles p on p.id = b.blocked_id
   where b.blocker_id = (select auth.uid())
   order by b.created_at desc;
$$;

comment on function my_blocks is
  'Who I have blocked, with their names. Says nothing about who has blocked me.';

revoke all on function my_blocks() from public;
grant execute on function my_blocks() to authenticated;
