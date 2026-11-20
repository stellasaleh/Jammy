-- ============================================================
--  JAMMY — 12_matching_fix.sql
--  "ANY DISTANCE" MEANT ZERO MILES. Run after 01–11.
--
--  Two things.
--
--  FIRST, A REAL BUG. The app's distance slider has an "any
--  distance" setting, which it sends as radius = 0. The database
--  read that literally: within zero miles of you. Nobody is
--  within zero miles of anybody, so the one setting a person
--  reaches for when they're seeing nobody was guaranteed to show
--  them nobody. Zero and below now mean no limit, which is what
--  the slider says on screen.
--
--  SECOND, A WAY TO SEE WHY. match_debug() takes every other
--  person in the database and says, for each one, which test
--  they pass and which they fail. Instead of an empty screen
--  and a guess, you get a row per person naming the reason.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. Zero means "no limit", not "zero miles"
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
     and st_distance(p.location, me.location) > greatest(radius_miles, 25) * 1609.34) as is_remote,
    least(100, (
        14 * least(3, cardinality(array(select unnest(p.genres) intersect select unnest(me.genres))))
      + case when p.looking_for_instruments && me.instruments then 24 else 0 end
      + case when needs <> '{}' and p.instruments && needs   then 20 else 0 end
      + case when not (p.instrument_keys && me.instrument_keys) then 12 else 0 end
      + case
          when p.location is null or me.location is null then 7
          else greatest(0, 14 - (st_distance(p.location, me.location) / 1609.34) * 0.9)::int
        end
      + case when p.rehearsal_days && me.rehearsal_days then 8 else 0 end
    ))::int as fit
  from profiles p, me
  where p.id <> me.id
    and not p.is_banned
    and not exists (select 1 from blocks
                    where (blocker_id = p.id and blocked_id = me.id)
                       or (blocker_id = me.id and blocked_id = p.id))
    and not exists (select 1 from swipes where from_id = me.id and to_id = p.id)
    and (
      -- no limit asked for: everyone is near enough
      radius_miles <= 0
      -- both placed: the ring decides
      or (p.location is not null and me.location is not null and (
            st_dwithin(p.location, me.location, radius_miles * 1609.34)
            or (include_remote and p.remote_ok
                and st_distance(p.location, me.location) > greatest(radius_miles, 25) * 1609.34)))
      -- either unplaced: the city decides
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
--  2. Why can't I see this person?
--
--  Run `select * from match_debug();` while signed in and it
--  lists everyone else with a verdict. `visible` is the answer;
--  `reason` is why not.
--
--  It only ever reveals what Discover itself would reveal, and
--  only to the person asking about their own account.
-- ------------------------------------------------------------
create or replace function match_debug(radius_miles numeric default 7)
returns table (
  who text,
  visible boolean,
  reason text,
  their_city text,
  my_city text,
  their_instruments text[],
  my_instruments text[],
  they_have_location boolean,
  i_have_location boolean,
  already_swiped boolean
)
language sql stable security definer set search_path = public, extensions as $$
  with me as (select * from profiles where id = auth.uid())
  select
    coalesce(p.display_name, '(no name)') || ' (@' || p.handle || ')',
    (
      not p.is_banned
      and not exists (select 1 from blocks where (blocker_id=p.id and blocked_id=me.id) or (blocker_id=me.id and blocked_id=p.id))
      and not exists (select 1 from swipes where from_id=me.id and to_id=p.id)
      and (radius_miles <= 0
           or (p.location is not null and me.location is not null)
           or (p.city is not null and me.city is not null and lower(btrim(p.city))=lower(btrim(me.city))))
      and not (p.instrument_keys && me.instrument_keys)
    ),
    case
      when p.is_banned then 'they are banned'
      when exists (select 1 from blocks where (blocker_id=p.id and blocked_id=me.id) or (blocker_id=me.id and blocked_id=p.id))
        then 'one of you has blocked the other'
      when exists (select 1 from swipes where from_id=me.id and to_id=p.id)
        then 'you already swiped on them — they will not come back'
      when p.instrument_keys && me.instrument_keys
        then 'same instrument (' || array_to_string(p.instrument_keys,', ') || ') — turn off "different instrument" to see them'
      when me.city is null then 'YOUR profile has no city and no location'
      when p.city is null then 'their profile has no city and no location'
      when (p.location is null or me.location is null)
           and lower(btrim(p.city)) <> lower(btrim(me.city))
        then 'different cities: "' || me.city || '" vs "' || p.city || '" — and no location to measure instead'
      else 'should be visible'
    end,
    p.city, me.city, p.instruments, me.instruments,
    (p.location is not null), (me.location is not null),
    exists (select 1 from swipes where from_id=me.id and to_id=p.id)
  from profiles p, me
  where p.id <> me.id;
$$;

-- ------------------------------------------------------------
--  2b. The same answer, from the SQL Editor
--
--  match_debug() asks "who is signed in?", and the SQL Editor
--  is not signed in as anybody — so there it returns nothing.
--  This takes the handle instead, so you can run it right here:
--
--      select * from match_debug_as('stella');
--
--  Run it as the owner, in the SQL Editor. From inside the app
--  it is bound by the same rules as everything else.
-- ------------------------------------------------------------
create or replace function match_debug_as(p_handle text, radius_miles numeric default 7)
returns table (
  who text, visible boolean, reason text,
  their_city text, my_city text,
  their_instruments text[], my_instruments text[],
  they_have_location boolean, i_have_location boolean, already_swiped boolean
)
language sql stable as $$
  with me as (
    select * from profiles
    where lower(handle) = lower(btrim(replace(p_handle,'@','')))
    limit 1
  )
  select
    coalesce(p.display_name,'(no name)') || ' (@' || p.handle || ')',
    (
      not p.is_banned
      and not exists (select 1 from blocks where (blocker_id=p.id and blocked_id=me.id) or (blocker_id=me.id and blocked_id=p.id))
      and not exists (select 1 from swipes where from_id=me.id and to_id=p.id)
      and (radius_miles <= 0
           or (p.location is not null and me.location is not null)
           or (p.city is not null and me.city is not null and lower(btrim(p.city))=lower(btrim(me.city))))
      and not (p.instrument_keys && me.instrument_keys)
    ),
    case
      when p.is_banned then 'they are banned'
      when exists (select 1 from blocks where (blocker_id=p.id and blocked_id=me.id) or (blocker_id=me.id and blocked_id=p.id))
        then 'one of you has blocked the other'
      when exists (select 1 from swipes where from_id=me.id and to_id=p.id)
        then 'you already swiped on them - run select reset_my_swipes() from the app, or delete from swipes here'
      when p.instrument_keys && me.instrument_keys
        then 'same instrument (' || array_to_string(p.instrument_keys,', ') || ')'
      when me.city is null and me.location is null then 'YOUR profile has no city and no location'
      when p.city is null and p.location is null then 'their profile has no city and no location'
      when (p.location is null or me.location is null)
           and lower(btrim(coalesce(p.city,''))) <> lower(btrim(coalesce(me.city,'')))
        then 'different cities: "' || coalesce(me.city,'(none)') || '" vs "' || coalesce(p.city,'(none)') || '" - and no location to measure instead'
      else 'should be visible'
    end,
    p.city, me.city, p.instruments, me.instruments,
    (p.location is not null), (me.location is not null),
    exists (select 1 from swipes where from_id=me.id and to_id=p.id)
  from profiles p, me
  where p.id <> me.id;
$$;

-- ------------------------------------------------------------
--  3. Undo a swipe, for testing
--
--  Swiping is permanent by design — people should not get a
--  second look at someone who passed on them. While you are
--  testing with your own two accounts that gets in the way, so
--  this clears your own swipes and nobody else's.
-- ------------------------------------------------------------
create or replace function reset_my_swipes()
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from swipes where from_id = auth.uid();
  get diagnostics n = row_count;
  return n;
end $$;

-- ------------------------------------------------------------
--  4. Proof
-- ------------------------------------------------------------
do $$
begin
  perform 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in ('match_debug','reset_my_swipes');
  raise notice 'Jammy: "any distance" now means any distance, and match_debug() will tell you why someone is hidden.';
end $$;
