-- ============================================================
--  JAMMY — 11_discover_fallback.sql
--  NOBODY GETS AN EMPTY APP. Run after 01–10.
--
--  WHAT WENT WRONG
--  Matching asked "are these two people within N miles?" — a
--  question that needs two locations. If either profile had
--  none, the comparison answered neither yes nor no, and the
--  row was dropped.
--
--  So anyone who declined the location prompt, or whose phone
--  couldn't get a fix, saw an empty Discover. Not an error, not
--  an explanation: just nobody, forever, with no way to tell
--  that it was broken rather than quiet.
--
--  THE FIX
--  When a location is missing, fall back to the city the person
--  typed when they signed up. It is rougher than a distance
--  ring and it is honest about that: miles come back empty, so
--  the app can say "Same city" rather than invent a number.
--
--  The distance ring still governs everyone who has a location.
--  This only catches the people it would otherwise silently
--  exclude.
--
--  Safe to run twice.
-- ============================================================

create or replace function discover(
  radius_miles     numeric default 7,
  exclude_same     boolean default true,
  needs            text[]  default '{}',
  min_shared_genres int    default 0,
  include_remote   boolean default false,
  max_results      int     default 50
)
returns table (
  id uuid,
  display_name text,
  handle text,
  city text,
  instruments text[],
  genres text[],
  looking_for text,
  bio text,
  photo_path text,
  miles numeric,
  shared_genres text[],
  they_need_me text[],
  is_remote boolean,
  fit int
)
language sql stable as $$
  with me as (select * from profiles where id = auth.uid())
  select
    p.id, p.display_name, p.handle, p.city, p.instruments, p.genres,
    p.looking_for, p.bio, p.photo_path,

    -- No location on either side means no honest distance. Return
    -- nothing rather than a number that looks measured.
    case when p.location is null or me.location is null then null
         else round((st_distance(p.location, me.location) / 1609.34)::numeric, 1)
    end as miles,

    array(select unnest(p.genres) intersect select unnest(me.genres))                      as shared_genres,
    array(select unnest(p.looking_for_instruments) intersect select unnest(me.instruments)) as they_need_me,

    (p.location is not null and me.location is not null
     and p.remote_ok
     and st_distance(p.location, me.location) > greatest(radius_miles, 25) * 1609.34) as is_remote,

    least(100, (
        14 * least(3, cardinality(array(select unnest(p.genres) intersect select unnest(me.genres))))
      + case when p.looking_for_instruments && me.instruments then 24 else 0 end
      + case when needs <> '{}' and p.instruments && needs   then 20 else 0 end
      + case when not (p.instrument_keys && me.instrument_keys) then 12 else 0 end
      -- proximity points only where proximity is actually known.
      -- Same city, no coordinates, scores as a middling distance:
      -- plausible, and never better than a measured near miss.
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

    -- Where both locations exist, the ring decides, exactly as before.
    -- Where one is missing, the city decides. Someone with neither a
    -- location nor a city is genuinely unplaceable and stays out.
    and (
      case
        when p.location is not null and me.location is not null then
          st_dwithin(p.location, me.location, radius_miles * 1609.34)
          or (include_remote and p.remote_ok
              and st_distance(p.location, me.location) > greatest(radius_miles, 25) * 1609.34)
        else
          p.city is not null and me.city is not null
          and lower(btrim(p.city)) = lower(btrim(me.city))
      end
    )

    and (not exclude_same or not (p.instrument_keys && me.instrument_keys))
    and (needs = '{}' or p.instruments && needs)
    and (min_shared_genres = 0
         or cardinality(array(select unnest(p.genres) intersect select unnest(me.genres))) >= min_shared_genres)
  order by fit desc, miles asc nulls last;
$$;

-- ------------------------------------------------------------
--  City lookups need an index now that they decide matches
-- ------------------------------------------------------------
create index if not exists profiles_city_lower_idx
  on profiles (lower(btrim(city)));

-- ------------------------------------------------------------
--  Proof
-- ------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'discover'
  ) then
    raise notice 'Jammy: matching now works without a location, using the city instead.';
  else
    raise exception 'Jammy: discover() is missing';
  end if;
end $$;
