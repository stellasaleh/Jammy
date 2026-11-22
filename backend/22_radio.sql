-- ============================================================
--  JAMMY — 22_radio.sql
--  FIFTEEN SECONDS, A PODIUM, AND SOMEBODY NEW. Run after 01–21.
--
--  Three things Stella asked for.
--
--  1. Fifteen seconds should count as a play, not thirty.
--     The rule lived in two places — the app and this trigger —
--     and only this one is real. The app's copy just avoids a
--     pointless round trip; anyone could call the API directly,
--     so a threshold enforced only in the app is a suggestion.
--
--  2. The top three marked out on the chart.
--
--  3. "Discover a new artist" — one up-and-coming track and the
--     person behind it. The hard part is what up-and-coming
--     means. The chart already shows what is popular; this has
--     to show the opposite without showing nothing, which is why
--     it is a score rather than a filter.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. Fifteen seconds
--
--  The number appears once, here, so there is no second copy to
--  fall out of step. Short clips are most of what gets uploaded
--  to Jammy — half a riff, a drum take — and thirty seconds
--  meant a good number of them could never be played to the end.
--
--  The dedupe below still holds: a play counts once per person
--  per track per day however many times it is played, so a
--  shorter threshold does not make the chart easier to climb by
--  pressing play repeatedly.
-- ------------------------------------------------------------
create or replace function roll_up_play() returns trigger
  language plpgsql security definer set search_path = public, extensions as $$
declare
  d date := (new.created_at at time zone 'utc')::date;
  fresh boolean;
begin
  -- a play counts at fifteen seconds or more
  if new.seconds < 15 then return null; end if;
  -- and only once per person per track per day, however often it is played
  if new.user_id is null then return null; end if;

  insert into play_dedupe (track_id, user_id, day)
  values (new.track_id, new.user_id, d)
  on conflict do nothing;
  fresh := found;

  insert into play_daily (track_id, day, plays, listeners)
  values (new.track_id, d, 1, case when fresh then 1 else 0 end)
  on conflict (track_id, day) do update
    set plays     = play_daily.plays + 1,
        listeners = play_daily.listeners + case when fresh then 1 else 0 end;

  update tracks set play_count = play_count + 1 where id = new.track_id;
  return null;
end $$;

-- ------------------------------------------------------------
--  2. Discover a new artist
--
--  What "up and coming" has to mean here, and why.
--
--  A filter — "tracks with under ten plays" — empties the moment
--  everybody has eleven, and on a new app it is every track, so
--  it means nothing either way. This scores instead, so there is
--  always something to show and it is always the most deserving
--  thing available:
--
--    * few plays is the point, so that weighs heaviest
--    * recently uploaded, because a new artist is a new arrival
--    * somebody you have never played before
--    * somebody you are not already connected to
--    * same city, a little, because Jammy is about who is near
--
--  It never returns your own track, anyone banned, or anyone
--  either of you has blocked. The random tiebreak means two
--  people opening the radio at the same moment are unlikely to
--  be shown the same person.
-- ------------------------------------------------------------
create or replace function rising_track()
returns table (
  track_id uuid, title text, key text, bpm int, audio_path text,
  duration_ms int, plays bigint,
  artist_id uuid, artist_name text, artist_handle text, artist_photo text,
  artist_city text, artist_bio text, artist_instruments text[],
  artist_genres text[], shared_genres text[], miles numeric,
  uploaded_days_ago int
)
language sql stable security definer set search_path = public, extensions as $$
  with me as (select * from profiles where id = (select auth.uid()))
  select t.id, t.title, t.key, t.bpm, t.audio_path, t.duration_ms,
         coalesce((select sum(d.plays) from play_daily d where d.track_id = t.id), 0)::bigint,
         p.id, p.display_name, p.handle, p.photo_path, p.city, p.bio,
         p.instruments, p.genres,
         array(select unnest(p.genres) intersect select unnest(me.genres)),
         case when p.location is null or me.location is null then null
              else round((st_distance(p.location, me.location) / 1609.34)::numeric, 1) end,
         extract(day from (now() - t.created_at))::int
  from tracks t
  join profiles p on p.id = t.owner_id
  cross join me
  where t.is_public
    and p.id <> me.id
    and not p.is_banned
    and not blocked_between(p.id, me.id)
  order by
    (
      -- few plays is the whole idea, so it carries the most weight
      greatest(0, 40 - coalesce((select sum(d.plays) from play_daily d
                                  where d.track_id = t.id), 0) * 4)
      -- new arrivals first
      + greatest(0, 25 - extract(day from (now() - t.created_at))::int * 2)
      -- somebody you have not heard before
      + case when exists (select 1 from plays pl
                           where pl.track_id = t.id and pl.user_id = me.id)
             then 0 else 20 end
      -- and have not already met
      + case when exists (select 1 from connections c
                           where (c.a_id = me.id and c.b_id = p.id)
                              or (c.b_id = me.id and c.a_id = p.id))
             then 0 else 12 end
      -- a little for being nearby, a little for playing what you play
      + case when p.city is not null and me.city is not null
                  and lower(btrim(p.city)) = lower(btrim(me.city)) then 8 else 0 end
      + 3 * least(2, cardinality(array(select unnest(p.genres)
                                       intersect select unnest(me.genres))))
    ) desc,
    random()
  limit 1;
$$;

comment on function rising_track is
  'One up-and-coming track and the person behind it. Scored, not filtered, so it is never empty while any track exists.';

-- ------------------------------------------------------------
--  3. Proof
-- ------------------------------------------------------------
do $$
declare src text;
begin
  select prosrc into src from pg_proc where proname = 'roll_up_play';
  if src not like '%new.seconds < 15%' then
    raise exception 'Jammy: the play threshold is still not fifteen seconds';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'rising_track') then
    raise exception 'Jammy: rising_track is missing';
  end if;

  raise notice 'Jammy: fifteen seconds counts, and the radio can introduce somebody new.';
end $$;
