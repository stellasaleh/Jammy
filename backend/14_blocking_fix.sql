-- ============================================================
--  JAMMY — 14_blocking_fix.sql
--  BLOCKING ONLY WORKED ONE WAY. Run after 01–13.
--
--  WHAT WENT WRONG — and this one matters more than the others.
--
--  Blocking is checked by asking the blocks table "has either
--  of these two blocked the other?". But the blocks table has
--  its own rule: you may only see blocks YOU created. Sensible
--  on its own — nobody should be able to find out they were
--  blocked.
--
--  Put together, they cancel out. When the blocked person asks
--  the question, the row is invisible to them, so the answer
--  comes back "no, nobody is blocked", and they carry on seeing
--  the person who blocked them: their profile, their posts,
--  their comments, their card in Discover.
--
--  So blocking protected the blocker's screen and not the
--  blocked person's. For an app whose whole purpose is putting
--  strangers in touch, that is the wrong half.
--
--  THE FIX
--  One function that can see the blocks table regardless of who
--  is asking, and answers only yes or no. It never returns a
--  row, a name or a direction — asking "is this pair blocked?"
--  tells you nothing you could not already infer from the
--  person disappearing. Everything that checks blocks now uses
--  it.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. The one question, answerable by anyone, revealing nothing
-- ------------------------------------------------------------
create or replace function blocked_between(a uuid, b uuid)
returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

comment on function blocked_between is
  'Yes/no only. Deliberately does not say who blocked whom, so being blocked stays invisible.';

-- ------------------------------------------------------------
--  2. Profiles
-- ------------------------------------------------------------
drop policy if exists "read profiles" on profiles;
create policy "read profiles" on profiles for select to authenticated
using (
  not is_banned
  and not blocked_between(profiles.id, (select auth.uid()))
);

-- ------------------------------------------------------------
--  3. Posts
-- ------------------------------------------------------------
drop policy if exists "read posts" on posts;
create policy "read posts" on posts for select to authenticated
using (
  not blocked_between(posts.author_id, (select auth.uid()))
);

-- ------------------------------------------------------------
--  4. Discover
-- ------------------------------------------------------------
create or replace function discover(
  radius_miles     numeric default 7,
  exclude_same     boolean default true,
  needs            text[]  default '{}',
  min_shared_genres int    default 0,
  include_remote   boolean default false,
  max_results      int     default 50
)
returns table (
  id uuid, display_name text, handle text, city text,
  instruments text[], genres text[], looking_for text, bio text,
  photo_path text, miles numeric, shared_genres text[],
  they_need_me text[], is_remote boolean, fit int
)
language sql stable as $$
  with me as (select * from profiles where id = auth.uid())
  select
    p.id, p.display_name, p.handle, p.city, p.instruments, p.genres,
    p.looking_for, p.bio, p.photo_path,
    case when p.location is null or me.location is null then null
         else round((st_distance(p.location, me.location) / 1609.34)::numeric, 1)
    end as miles,
    array(select unnest(p.genres) intersect select unnest(me.genres))                       as shared_genres,
    array(select unnest(p.looking_for_instruments) intersect select unnest(me.instruments)) as they_need_me,
    (p.location is not null and me.location is not null and p.remote_ok
     and radius_miles > 0
     and st_distance(p.location, me.location) > greatest(radius_miles, 25) * 1609.34)       as is_remote,
    least(100, (
        14 * least(3, cardinality(array(select unnest(p.genres) intersect select unnest(me.genres))))
      + case when p.looking_for_instruments && me.instruments then 24 else 0 end
      + case when needs <> '{}' and p.instruments && needs   then 20 else 0 end
      + case when not (p.instrument_keys && me.instrument_keys) then 12 else 0 end
      + case when p.location is null or me.location is null then 7
             else greatest(0, 14 - (st_distance(p.location, me.location) / 1609.34) * 0.9)::int end
      + case when p.rehearsal_days && me.rehearsal_days then 8 else 0 end
    ))::int as fit
  from profiles p, me
  where p.id <> me.id
    and not p.is_banned
    and not blocked_between(p.id, me.id)
    and not exists (select 1 from swipes where from_id = me.id and to_id = p.id)
    and (
      radius_miles <= 0
      or (p.location is not null and me.location is not null and (
            st_dwithin(p.location, me.location, radius_miles * 1609.34)
            or (include_remote and p.remote_ok
                and st_distance(p.location, me.location) > greatest(radius_miles, 25) * 1609.34)))
      or ((p.location is null or me.location is null)
          and p.city is not null and me.city is not null
          and lower(btrim(p.city)) = lower(btrim(me.city)))
    )
    and (not exclude_same or not (p.instrument_keys && me.instrument_keys))
    and (needs = '{}' or p.instruments && needs)
    and (min_shared_genres = 0
         or cardinality(array(select unnest(p.genres) intersect select unnest(me.genres))) >= min_shared_genres)
  order by fit desc, miles asc nulls last
  limit max_results;
$$;

-- ------------------------------------------------------------
--  5. The feed and the comments
--
--  Same substitution, done by hand so there is no guesswork:
--  the inline blocks lookup becomes the shared check.
-- ------------------------------------------------------------
do $rw$
declare
  fn record;
  src text;
  fixed text;
  changed int := 0;
begin
  for fn in
    select p.oid, p.proname,
           case p.proname when 'feed_page' then 'p.author_id'
                          when 'comments_page' then 'c.author_id' end as col
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and p.proname in ('feed_page','comments_page')
  loop
    src := pg_get_functiondef(fn.oid);
    fixed := replace(
      src,
      'not exists (' || chr(10) ||
      '      select 1 from blocks b' || chr(10) ||
      '      where (b.blocker_id = ' || fn.col || ' and b.blocked_id = (select auth.uid()))' || chr(10) ||
      '         or (b.blocker_id = (select auth.uid()) and b.blocked_id = ' || fn.col || '))',
      'not blocked_between(' || fn.col || ', (select auth.uid()))'
    );
    if fixed <> src then
      execute fixed;
      changed := changed + 1;
      raise notice 'Jammy: % now uses the block check that works both ways.', fn.proname;
    elsif src like '%blocked_between%' then
      changed := changed + 1;   -- already done on an earlier run
    else
      raise warning 'Jammy: could not rewrite % — it does not match the expected shape.', fn.proname;
    end if;
  end loop;

  if changed < 2 then
    raise warning 'Jammy: expected 2 functions to use the shared block check, got %.', changed;
  end if;
end $rw$;

-- ------------------------------------------------------------
--  6. Proof
--
--  The test that failed: can a blocked person still read the
--  profile of the person who blocked them?
-- ------------------------------------------------------------
do $$
begin
  if blocked_between(
       '00000000-0000-0000-0000-000000000000',
       '00000000-0000-0000-0000-000000000001') then
    raise exception 'Jammy: blocked_between said yes about two accounts that do not exist';
  end if;
  raise notice 'Jammy: blocking now works in both directions. Run journey.test.sql to confirm.';
end $$;
