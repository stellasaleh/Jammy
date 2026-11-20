-- ============================================================
--  JAMMY — 02_security_and_functions.sql
--  Run this AFTER 01_schema.sql.
--
--  Nothing here is optional. Without RLS, anyone who views your
--  app's source can read every message and every rehearsal
--  address in the database using the public key.
-- ============================================================

-- ------------------------------------------------------------
--  Turn RLS on everywhere, first. Deny by default.
-- ------------------------------------------------------------
alter table profiles             enable row level security;
alter table tracks               enable row level security;
alter table plays                enable row level security;
alter table posts                enable row level security;
alter table post_likes           enable row level security;
alter table post_comments        enable row level security;
alter table swipes               enable row level security;
alter table connections          enable row level security;
alter table conversations        enable row level security;
alter table conversation_members enable row level security;
alter table messages             enable row level security;
alter table bands                enable row level security;
alter table band_members         enable row level security;
alter table band_events          enable row level security;
alter table event_tasks          enable row level security;
alter table event_rsvps          enable row level security;
alter table band_media           enable row level security;
alter table blocks               enable row level security;
alter table reports              enable row level security;
alter table device_tokens        enable row level security;

-- helper: am I in this band?
create or replace function is_band_member(b uuid) returns boolean as $$
  select exists (
    select 1 from band_members
    where band_id = b and user_id = auth.uid()
  );
$$ language sql stable security definer set search_path = public, extensions;

-- helper: am I in this conversation?
create or replace function in_conversation(c uuid) returns boolean as $$
  select exists (
    select 1 from conversation_members
    where conversation_id = c and user_id = auth.uid()
  );
$$ language sql stable security definer set search_path = public, extensions;

-- ------------------------------------------------------------
--  PROFILES
-- ------------------------------------------------------------
drop policy if exists "read profiles" on profiles;
create policy "read profiles" on profiles for select to authenticated using (
  not is_banned
  and not exists (select 1 from blocks where blocker_id = profiles.id and blocked_id = auth.uid())
  and not exists (select 1 from blocks where blocker_id = auth.uid() and blocked_id = profiles.id)
);

drop policy if exists "insert own profile" on profiles;
create policy "insert own profile" on profiles for insert to authenticated with check (id = auth.uid());

drop policy if exists "update own profile" on profiles;
create policy "update own profile" on profiles for update to authenticated using (id = auth.uid());

-- ------------------------------------------------------------
--  TRACKS, PLAYS, POSTS
-- ------------------------------------------------------------
drop policy if exists "read public tracks" on tracks;
create policy "read public tracks" on tracks for select to authenticated
  using (is_public or owner_id = auth.uid());

drop policy if exists "write own tracks" on tracks;
create policy "write own tracks" on tracks for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "log my plays" on plays;
create policy "log my plays" on plays for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "read posts" on posts;
create policy "read posts" on posts for select to authenticated using (
  not exists (select 1 from blocks
    where (blocker_id = posts.author_id and blocked_id = auth.uid())
       or (blocker_id = auth.uid() and blocked_id = posts.author_id))
);

drop policy if exists "write own posts" on posts;
create policy "write own posts" on posts for all to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());

drop policy if exists "read likes" on post_likes;
create policy "read likes" on post_likes for select to authenticated using (true);
drop policy if exists "like as me" on post_likes;
create policy "like as me" on post_likes for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "read comments" on post_comments;
create policy "read comments" on post_comments for select to authenticated using (true);
drop policy if exists "comment as me" on post_comments;
create policy "comment as me" on post_comments for all to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());

-- ------------------------------------------------------------
--  SWIPES AND CONNECTIONS
--  A mutual yes creates the connection and the DM automatically.
-- ------------------------------------------------------------
drop policy if exists "own swipes" on swipes;
create policy "own swipes" on swipes for all to authenticated
  using (from_id = auth.uid()) with check (from_id = auth.uid());

drop policy if exists "my connections" on connections;
create policy "my connections" on connections for select to authenticated
  using (a_id = auth.uid() or b_id = auth.uid());

create or replace function on_swipe() returns trigger as $$
declare
  lo uuid; hi uuid; conv uuid;
begin
  if new.direction <> 'yes' then return new; end if;

  if not exists (
    select 1 from swipes
    where from_id = new.to_id and to_id = new.from_id and direction = 'yes'
  ) then return new; end if;

  lo := least(new.from_id, new.to_id);
  hi := greatest(new.from_id, new.to_id);

  insert into connections (a_id, b_id) values (lo, hi)
  on conflict do nothing;

  -- give every new connection a conversation immediately
  if not exists (
    select 1 from conversations c
    join conversation_members m1 on m1.conversation_id = c.id and m1.user_id = lo
    join conversation_members m2 on m2.conversation_id = c.id and m2.user_id = hi
    where c.kind = 'dm'
  ) then
    insert into conversations (kind) values ('dm') returning id into conv;
    insert into conversation_members (conversation_id, user_id) values (conv, lo), (conv, hi);
  end if;

  return new;
end $$ language plpgsql security definer set search_path = public, extensions;

drop trigger if exists swipe_match on swipes;
create trigger swipe_match after insert on swipes
for each row execute function on_swipe();

-- ------------------------------------------------------------
--  MESSAGES — the policy that matters most
-- ------------------------------------------------------------
drop policy if exists "read my conversations" on conversations;
create policy "read my conversations" on conversations for select to authenticated
  using (in_conversation(id));

drop policy if exists "read my memberships" on conversation_members;
create policy "read my memberships" on conversation_members for select to authenticated
  using (in_conversation(conversation_id));
drop policy if exists "update my read marker" on conversation_members;
create policy "update my read marker" on conversation_members for update to authenticated
  using (user_id = auth.uid());

drop policy if exists "read messages in my conversations" on messages;
create policy "read messages in my conversations" on messages for select to authenticated
  using (in_conversation(conversation_id));

drop policy if exists "send as myself" on messages;
create policy "send as myself" on messages for insert to authenticated
  with check (sender_id = auth.uid() and in_conversation(conversation_id));

-- ------------------------------------------------------------
--  BANDS — practices are private, gigs are public
-- ------------------------------------------------------------
drop policy if exists "read bands" on bands;
create policy "read bands" on bands for select to authenticated using (true);
drop policy if exists "create bands" on bands;
create policy "create bands" on bands for insert to authenticated with check (created_by = auth.uid());
drop policy if exists "members edit band" on bands;
create policy "members edit band" on bands for update to authenticated using (is_band_member(id));

drop policy if exists "read band members" on band_members;
create policy "read band members" on band_members for select to authenticated using (true);
drop policy if exists "members manage roster" on band_members;
create policy "members manage roster" on band_members for all to authenticated
  using (is_band_member(band_id) or user_id = auth.uid())
  with check (is_band_member(band_id) or user_id = auth.uid());

drop policy if exists "events: members all, others public only" on band_events;
create policy "events: members all, others public only" on band_events for select to authenticated
  using (visibility = 'public' or is_band_member(band_id));

drop policy if exists "only members schedule" on band_events;
create policy "only members schedule" on band_events for insert to authenticated
  with check (is_band_member(band_id));
drop policy if exists "only members reschedule" on band_events;
create policy "only members reschedule" on band_events for update to authenticated
  using (is_band_member(band_id));
drop policy if exists "only members cancel" on band_events;
create policy "only members cancel" on band_events for delete to authenticated
  using (is_band_member(band_id));

-- tasks and notes stay private even on a public gig
drop policy if exists "tasks are band-only" on event_tasks;
create policy "tasks are band-only" on event_tasks for all to authenticated
  using (exists (select 1 from band_events e where e.id = event_tasks.event_id and is_band_member(e.band_id)))
  with check (exists (select 1 from band_events e where e.id = event_tasks.event_id and is_band_member(e.band_id)));

drop policy if exists "rsvps are band-only" on event_rsvps;
create policy "rsvps are band-only" on event_rsvps for all to authenticated
  using (exists (select 1 from band_events e where e.id = event_rsvps.event_id and is_band_member(e.band_id)))
  with check (user_id = auth.uid());

drop policy if exists "media: members all, others public only" on band_media;
create policy "media: members all, others public only" on band_media for select to authenticated
  using (visibility = 'public' or is_band_member(band_id));
drop policy if exists "only members upload" on band_media;
create policy "only members upload" on band_media for all to authenticated
  using (is_band_member(band_id)) with check (is_band_member(band_id));

-- ------------------------------------------------------------
--  SAFETY
-- ------------------------------------------------------------
drop policy if exists "own blocks" on blocks;
create policy "own blocks" on blocks for all to authenticated
  using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

drop policy if exists "file reports" on reports;
create policy "file reports" on reports for insert to authenticated with check (reporter_id = auth.uid());
drop policy if exists "read own reports" on reports;
create policy "read own reports" on reports for select to authenticated using (reporter_id = auth.uid());

drop policy if exists "own device tokens" on device_tokens;
create policy "own device tokens" on device_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================
--  DISCOVERY
--  Distance rings + complementary instruments + genre overlap,
--  all computed in the database. Never trust a client distance.
--  Returns MILES ONLY — never another user's coordinates.
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
    round((st_distance(p.location, me.location) / 1609.34)::numeric, 1) as miles,
    array(select unnest(p.genres) intersect select unnest(me.genres))                 as shared_genres,
    array(select unnest(p.looking_for_instruments) intersect select unnest(me.instruments)) as they_need_me,
    (p.remote_ok and st_distance(p.location, me.location) > greatest(radius_miles, 25) * 1609.34) as is_remote,
    least(100, (
        14 * least(3, cardinality(array(select unnest(p.genres) intersect select unnest(me.genres))))
      + case when p.looking_for_instruments && me.instruments then 24 else 0 end
      + case when needs <> '{}' and p.instruments && needs   then 20 else 0 end
      + case when not (p.instrument_keys && me.instrument_keys) then 12 else 0 end
      + greatest(0, 14 - (st_distance(p.location, me.location) / 1609.34) * 0.9)::int
      + case when p.rehearsal_days && me.rehearsal_days then 8 else 0 end
    ))::int as fit
  from profiles p, me
  where p.id <> me.id
    and not p.is_banned
    and not exists (select 1 from blocks
                    where (blocker_id = p.id and blocked_id = me.id)
                       or (blocker_id = me.id and blocked_id = p.id))
    and not exists (select 1 from swipes where from_id = me.id and to_id = p.id)
    -- distance ring. remote collaborators are only ever ADDED beyond 25 miles,
    -- so "within 3 miles" genuinely means within 3 miles.
    and (
      st_dwithin(p.location, me.location, radius_miles * 1609.34)
      or (include_remote and p.remote_ok
          and st_distance(p.location, me.location) > greatest(radius_miles, 25) * 1609.34)
    )
    -- complementary instruments, by normalised KEY not by section
    and (not exclude_same or not (p.instrument_keys && me.instrument_keys))
    and (needs = '{}' or p.instruments && needs)
    and (min_shared_genres = 0
         or cardinality(array(select unnest(p.genres) intersect select unnest(me.genres))) >= min_shared_genres)
  order by fit desc, miles asc
  limit max_results;
$$;

-- ============================================================
--  WEEKLY CHART
--  Counted plays only. Weighted by distinct listeners so a
--  thousand plays from ten people is worth less than three
--  hundred plays from three hundred people.
-- ============================================================
create materialized view if not exists weekly_chart as
with counted as (
  select p.track_id, p.user_id, min(p.created_at) as first_play
  from plays p
  where p.created_at > now() - interval '7 days'
    and p.seconds >= 30
  group by p.track_id, p.user_id, date_trunc('day', p.created_at)
)
select
  t.id as track_id, t.title, t.owner_id, t.key, t.bpm,
  count(*)                      as plays,
  count(distinct c.user_id)     as listeners,
  (count(*) * ln(1 + count(distinct c.user_id)))::numeric(12,2) as score
from tracks t
join counted c on c.track_id = t.id
where t.is_public
group by t.id
order by score desc
limit 100;

create unique index if not exists weekly_chart_track_idx on weekly_chart (track_id);

create table if not exists chart_history (
  week_start date not null,
  track_id   uuid not null,
  position   int not null,
  score      numeric,
  primary key (week_start, track_id)
);

-- refresh every 15 minutes; snapshot Sundays at midnight UTC
select cron.schedule('refresh-chart', '*/15 * * * *',
  $$refresh materialized view concurrently weekly_chart$$);

select cron.schedule('snapshot-chart', '0 0 * * 0', $$
  insert into chart_history (week_start, track_id, position, score)
  select current_date, track_id, row_number() over (order by score desc), score
  from weekly_chart
  on conflict do nothing;
$$);
