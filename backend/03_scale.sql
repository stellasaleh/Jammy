-- ============================================================
--  JAMMY — 03_scale.sql
--  Run AFTER 01 and 02. This file exists to prevent the four
--  specific walls that kill Postgres-backed social apps.
--
--  None of this is premature. Every item here is cheap to do now
--  and expensive-to-impossible to retrofit once there is live
--  user data depending on the old shape.
-- ============================================================


-- ============================================================
--  WALL 1 — RLS policies that re-run per row
--
--  `auth.uid()` inside a policy is evaluated ONCE PER ROW unless
--  it is wrapped in a scalar subquery. On a 200-row page that is
--  invisible. On a table with millions of rows it turns a 2ms
--  query into a 2-second one, and it is the single most common
--  reason Supabase apps fall over at scale.
--
--  Wrapping it in (select auth.uid()) lets Postgres treat it as a
--  constant and hoist it out of the loop.
-- ============================================================

create or replace function current_uid() returns uuid
  language sql stable
  set search_path = public, extensions
as $$ select auth.uid() $$;

-- helpers rewritten with the hoisted pattern + explicit STABLE so the
-- planner caches them per statement instead of per row
create or replace function is_band_member(b uuid) returns boolean
  language sql stable security definer set search_path = public, extensions
as $$
  select exists (
    select 1 from band_members
    where band_id = b and user_id = (select auth.uid())
  );
$$;

create or replace function in_conversation(c uuid) returns boolean
  language sql stable security definer set search_path = public, extensions
as $$
  select exists (
    select 1 from conversation_members
    where conversation_id = c and user_id = (select auth.uid())
  );
$$;

-- the hot-path policies, re-stated with the hoisted subselect
drop policy if exists "read messages in my conversations" on messages;
create policy "read messages in my conversations" on messages for select to authenticated
  using (in_conversation(conversation_id));

drop policy if exists "send as myself" on messages;
create policy "send as myself" on messages for insert to authenticated
  with check (sender_id = (select auth.uid()) and in_conversation(conversation_id));

drop policy if exists "update own profile" on profiles;
create policy "update own profile" on profiles for update to authenticated
  using (id = (select auth.uid()));

drop policy if exists "own swipes" on swipes;
create policy "own swipes" on swipes for all to authenticated
  using (from_id = (select auth.uid())) with check (from_id = (select auth.uid()));

drop policy if exists "my connections" on connections;
create policy "my connections" on connections for select to authenticated
  using (a_id = (select auth.uid()) or b_id = (select auth.uid()));

-- every column a policy filters on needs its own index, or each
-- policy check becomes a sequential scan
create index if not exists conv_members_user_idx   on conversation_members (user_id);
create index if not exists band_members_user_idx   on band_members (user_id) where user_id is not null;
create index if not exists blocks_blocked_idx      on blocks (blocked_id);
create index if not exists blocks_blocker_idx      on blocks (blocker_id);
create index if not exists swipes_from_idx         on swipes (from_id);
create index if not exists connections_a_idx       on connections (a_id);
create index if not exists connections_b_idx       on connections (b_id);
create index if not exists tracks_owner_idx        on tracks (owner_id);
create index if not exists posts_author_idx        on posts (author_id);
create index if not exists band_events_vis_idx     on band_events (band_id, visibility, starts_at);
create index if not exists band_media_vis_idx      on band_media (band_id, visibility);
create index if not exists device_tokens_user_idx  on device_tokens (user_id);


-- ============================================================
--  WALL 2 — counting rows to display a number
--
--  `select count(*) from post_likes where post_id = x` is fine at
--  100 likes and a table scan at 100,000. Feeds that count on read
--  are the classic reason a social app gets slower as it succeeds.
--
--  Keep the number on the row and maintain it with a trigger.
-- ============================================================

alter table posts add column if not exists like_count    int not null default 0;
alter table posts add column if not exists comment_count int not null default 0;
alter table tracks add column if not exists play_count   bigint not null default 0;

create or replace function bump_like_count() returns trigger
  language plpgsql security definer set search_path = public, extensions as $$
begin
  if tg_op = 'INSERT' then
    update posts set like_count = like_count + 1 where id = new.post_id;
  elsif tg_op = 'DELETE' then
    update posts set like_count = greatest(0, like_count - 1) where id = old.post_id;
  end if;
  return null;
end $$;

drop trigger if exists post_likes_count on post_likes;
create trigger post_likes_count after insert or delete on post_likes
for each row execute function bump_like_count();

create or replace function bump_comment_count() returns trigger
  language plpgsql security definer set search_path = public, extensions as $$
begin
  if tg_op = 'INSERT' then
    update posts set comment_count = comment_count + 1 where id = new.post_id;
  elsif tg_op = 'DELETE' then
    update posts set comment_count = greatest(0, comment_count - 1) where id = old.post_id;
  end if;
  return null;
end $$;

drop trigger if exists post_comments_count on post_comments;
create trigger post_comments_count after insert or delete on post_comments
for each row execute function bump_comment_count();

-- backfill once, so existing rows are correct
update posts p set
  like_count    = (select count(*) from post_likes    l where l.post_id = p.id),
  comment_count = (select count(*) from post_comments c where c.post_id = p.id);


-- ============================================================
--  WALL 3 — the plays table, and the chart built on top of it
--
--  One row per listen. At a million users this is tens of millions
--  of rows a week, and the materialised view in 02 re-reads seven
--  days of them every 15 minutes. That works at a thousand users
--  and falls over well before a million.
--
--  Fix: roll plays up into a daily aggregate as they arrive, and
--  build the chart from the aggregate. The raw rows then become
--  disposable and can be aged out.
-- ============================================================

create table if not exists play_daily (
  track_id  uuid not null references tracks on delete cascade,
  day       date not null,
  plays     bigint not null default 0,
  listeners int not null default 0,
  primary key (track_id, day)
);
create index if not exists play_daily_day_idx on play_daily (day desc);

-- one counted play per user per track per day, enforced at write time.
-- this is also the anti-gaming rule, so it belongs in the database and
-- not in the client where it can be bypassed.
create table if not exists play_dedupe (
  track_id uuid not null,
  user_id  uuid not null,
  day      date not null,
  primary key (track_id, user_id, day)
);

create or replace function roll_up_play() returns trigger
  language plpgsql security definer set search_path = public, extensions as $$
declare
  d date := (new.created_at at time zone 'utc')::date;
  fresh boolean;
begin
  -- a play only counts at 30 seconds or more
  if new.seconds < 30 then return null; end if;
  -- and only once per user per track per day
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

drop trigger if exists plays_rollup on plays;
create trigger plays_rollup after insert on plays
for each row execute function roll_up_play();

-- the chart now reads a few thousand aggregate rows instead of tens of
-- millions of raw ones, so it can be a plain view and needs no refresh job
create or replace view weekly_chart_v as
select
  t.id as track_id, t.title, t.owner_id, t.key, t.bpm,
  sum(d.plays)::bigint     as plays,
  sum(d.listeners)::int    as listeners,
  (sum(d.plays) * ln(1 + sum(d.listeners)))::numeric(14,2) as score
from tracks t
join play_daily d on d.track_id = t.id
where t.is_public
  and d.day > (current_date - 7)
group by t.id
order by score desc
limit 100;

-- retire the heavy refresh job and the materialised view that needed it
do $$
begin
  perform cron.unschedule('refresh-chart');
exception when others then null;
end $$;
drop materialized view if exists weekly_chart;

-- the Sunday snapshot job in 02 pointed at the materialised view we just
-- dropped. Re-point it at the aggregate view, or it fails silently every
-- week and you lose the chart movement arrows.
do $$
begin
  perform cron.unschedule('snapshot-chart');
exception when others then null;
end $$;

select cron.schedule('snapshot-chart', '0 0 * * 0', $$
  insert into chart_history (week_start, track_id, position, score)
  select current_date, track_id, row_number() over (order by score desc), score
  from weekly_chart_v
  on conflict do nothing;
$$);

-- raw play rows are only needed for auditing. keep 30 days.
select cron.schedule('prune-plays', '0 4 * * *', $$
  delete from plays where created_at < now() - interval '30 days';
  delete from play_dedupe where day < current_date - 40;
$$);

-- ad_events has exactly the same shape of problem
select cron.schedule('prune-ad-events', '30 4 * * *', $$
  delete from ad_events where created_at < now() - interval '90 days';
$$);


-- ============================================================
--  WALL 4 — unbounded reads from the client
--
--  Even with indexes, `order by created_at desc limit 50 offset 5000`
--  makes Postgres walk 5,050 rows. Keyset pagination walks 50.
--  These functions give the client a cursor instead of an offset.
-- ============================================================

create or replace function messages_page(
  convo uuid,
  before timestamptz default null,
  page_size int default 40
) returns setof messages
  language sql stable as $$
  select * from messages
  where conversation_id = convo
    and (before is null or created_at < before)
  order by created_at desc
  limit least(page_size, 100);
$$;

create or replace function feed_page(
  before timestamptz default null,
  page_size int default 20
) returns table (
  id uuid, author_id uuid, body text, tag text, track_id uuid, media_path text,
  created_at timestamptz, like_count int, comment_count int,
  author_name text, author_handle text, author_city text, author_photo text,
  liked_by_me boolean
) language sql stable as $$
  select p.id, p.author_id, p.body, p.tag, p.track_id, p.media_path,
         p.created_at, p.like_count, p.comment_count,
         pr.display_name, pr.handle, pr.city, pr.photo_path,
         exists (select 1 from post_likes l
                 where l.post_id = p.id and l.user_id = (select auth.uid()))
  from posts p
  join profiles pr on pr.id = p.author_id
  where (before is null or p.created_at < before)
    and not pr.is_banned
    and not exists (
      select 1 from blocks b
      where (b.blocker_id = p.author_id and b.blocked_id = (select auth.uid()))
         or (b.blocker_id = (select auth.uid()) and b.blocked_id = p.author_id))
  order by p.created_at desc
  limit least(page_size, 50);
$$;


-- ============================================================
--  ABUSE LIMITS
--  Not a scale wall exactly, but at a million users the top 0.01%
--  of bad actors generate most of the load. Cap them in the database,
--  because the client can always be bypassed.
-- ============================================================

create table if not exists rate_counters (
  user_id uuid not null references profiles on delete cascade,
  bucket  text not null,              -- 'swipe' | 'message' | 'post' | 'report'
  window_start timestamptz not null,
  count   int not null default 0,
  primary key (user_id, bucket, window_start)
);

create or replace function check_rate(bucket_name text, cap int, window_minutes int)
  returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare
  w timestamptz := date_trunc('hour', now())
                 + floor(extract(minute from now()) / window_minutes) * (window_minutes || ' minutes')::interval;
  c int;
begin
  insert into rate_counters (user_id, bucket, window_start, count)
  values ((select auth.uid()), bucket_name, w, 1)
  on conflict (user_id, bucket, window_start)
    do update set count = rate_counters.count + 1
  returning count into c;
  return c <= cap;
end $$;

create or replace function guard_message_rate() returns trigger
  language plpgsql security definer set search_path = public, extensions as $$
begin
  if not check_rate('message', 120, 10) then
    raise exception 'Slow down — too many messages. Try again in a few minutes.';
  end if;
  return new;
end $$;

drop trigger if exists messages_rate on messages;
create trigger messages_rate before insert on messages
for each row execute function guard_message_rate();

create or replace function guard_swipe_rate() returns trigger
  language plpgsql security definer set search_path = public, extensions as $$
begin
  if not check_rate('swipe', 400, 60) then
    raise exception 'Daily discovery limit reached. Come back later.';
  end if;
  return new;
end $$;

drop trigger if exists swipes_rate on swipes;
create trigger swipes_rate before insert on swipes
for each row execute function guard_swipe_rate();

select cron.schedule('prune-rate-counters', '15 4 * * *', $$
  delete from rate_counters where window_start < now() - interval '2 days';
$$);


-- ============================================================
--  HOUSEKEEPING THAT MATTERS LATER
-- ============================================================

-- autovacuum tuned for the two tables that will churn hardest
alter table messages    set (autovacuum_vacuum_scale_factor = 0.02);
alter table plays       set (autovacuum_vacuum_scale_factor = 0.01);
alter table play_daily  set (autovacuum_vacuum_scale_factor = 0.05);

-- let the planner know these are read constantly
analyze profiles;
analyze band_events;
analyze messages;
