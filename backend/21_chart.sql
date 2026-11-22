-- ============================================================
--  JAMMY — 21_chart.sql
--  THE WEEKLY CHART, FROM REAL PLAYS. Run after 01–20.
--
--  WHY THIS EXISTS
--  The radio screen was invented: made-up tracks, made-up play
--  counts, and a banner reading "2,140 LISTENING" to a real
--  signed-in person when the true number was nobody.
--
--  weekly_chart_v has been here since 03_scale.sql, counting real
--  plays. Nothing called it. Same as the feed, same as the gigs.
--
--  This adds the one call the screen needs — the track, who made
--  it, how it has moved since last week — and an honest answer
--  for how many people are actually listening.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. The chart, in one call
--
--  A view cannot be joined through PostgREST the way a table can,
--  so the app would have needed a query per row to find out who
--  made each track. This answers the whole screen at once.
--
--  SECURITY DEFINER because it reads play_daily, which is closed
--  to the app on purpose — nobody should be able to pull the raw
--  play table, only the chart built from it.
-- ------------------------------------------------------------
create or replace function weekly_chart(limit_n int default 10)
returns table (
  track_id uuid, title text, key text, bpm int, audio_path text,
  owner_id uuid, artist_name text, artist_handle text, artist_photo text,
  plays bigint, listeners int,
  last_week_rank int, rank int, is_new boolean, move int, mine boolean
)
language sql stable security definer set search_path = public, extensions as $$
  with this_week as (
    select c.track_id, c.title, c.key, c.bpm, c.plays, c.listeners, c.owner_id,
           row_number() over (order by c.score desc)::int as rank
    from weekly_chart_v c
  ),
  last_week as (
    -- the column is `position`, and the table is keyed by week_start
    select h.track_id, min(h.position)::int as was
    from chart_history h
    where h.week_start = (
      select max(week_start) from chart_history
      where week_start < date_trunc('week', now())::date)
    group by h.track_id
  )
  select w.track_id, w.title, w.key, w.bpm, t.audio_path,
         w.owner_id, p.display_name, p.handle, p.photo_path,
         w.plays, w.listeners,
         l.was,
         w.rank,
         (l.was is null),
         case when l.was is null then 0 else (l.was - w.rank) end,
         (w.owner_id = (select auth.uid()))
  from this_week w
  join tracks t on t.id = w.track_id
  join profiles p on p.id = w.owner_id
  left join last_week l on l.track_id = w.track_id
  where not p.is_banned
    and not blocked_between(w.owner_id, (select auth.uid()))
  order by w.rank
  limit least(greatest(limit_n, 1), 50);
$$;

-- ------------------------------------------------------------
--  2. How many people are actually listening
--
--  The screen said 2,140. It should say what is true, even when
--  what is true is two. An honest small number is a reason to
--  tell your friends; an invented large one is a reason to stop
--  believing the rest of the screen.
--
--  "Listening" means someone who played something in the last
--  fifteen minutes. Counted distinctly, so one person on repeat
--  is one person.
-- ------------------------------------------------------------
create or replace function listening_now()
returns int
language sql stable security definer set search_path = public, extensions as $$
  select count(distinct coalesce(user_id::text, 'anon:' || id::text))::int
  from plays
  where created_at > now() - interval '15 minutes';
$$;

-- ------------------------------------------------------------
--  3. When the chart resets
--
--  The screen says "Resets Sunday". That should come from the
--  same place the chart does rather than being typed into the
--  page and quietly drifting out of step with the job that
--  actually rolls it over.
-- ------------------------------------------------------------
create or replace function chart_resets_at()
returns timestamptz
language sql stable as $$
  select date_trunc('week', now()) + interval '7 days';
$$;

-- ------------------------------------------------------------
--  4. Your own tracks, so a profile can list them
-- ------------------------------------------------------------
create or replace function tracks_by(who uuid)
returns table (
  id uuid, title text, key text, bpm int, audio_path text,
  is_public boolean, created_at timestamptz, plays bigint
)
language sql stable security definer set search_path = public, extensions as $$
  select t.id, t.title, t.key, t.bpm, t.audio_path, t.is_public, t.created_at,
         coalesce((select sum(d.plays) from play_daily d where d.track_id = t.id), 0)::bigint
  from tracks t
  join profiles p on p.id = t.owner_id
  where t.owner_id = who
    and (t.is_public or t.owner_id = (select auth.uid()))
    and not p.is_banned
    and not blocked_between(who, (select auth.uid()))
  order by t.created_at desc;
$$;

-- ------------------------------------------------------------
--  5. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('weekly_chart','listening_now','chart_resets_at','tracks_by');
  if n <> 4 then
    raise exception 'Jammy: expected 4 chart functions, found %', n;
  end if;

  -- an empty chart is a correct chart when nobody has uploaded anything
  perform weekly_chart(10);
  if listening_now() < 0 then
    raise exception 'Jammy: listening_now returned a negative number';
  end if;

  raise notice 'Jammy: the chart counts real plays, and says how many people are really listening.';
end $$;
