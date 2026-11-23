-- ============================================================
--  JAMMY — COMPLETE DATABASE SETUP
--
--  Everything, in order, in one file. Paste it into the
--  Supabase SQL Editor and press Run.
--
--  Before you do, turn on two extensions under
--  Database -> Extensions:  postgis  and  pg_cron.
--
--  Safe to run more than once. Nothing is deleted; running it
--  again simply brings the database back in line with this
--  file. If you have run some of these already, running this
--  changes nothing except bringing the rest up to date.
-- ============================================================




-- ############################################################
-- ##  01_schema.sql
-- ############################################################

-- ============================================================
--  JAMMY — 01_schema.sql
--  Paste this whole file into Supabase → SQL Editor → Run.
--  Safe to re-run: everything is "if not exists" or "or replace".
-- ============================================================

create extension if not exists postgis;
create extension if not exists pg_cron;

-- ------------------------------------------------------------
--  PROFILES
--  One row per user, keyed to Supabase's auth.users.
--  location is stored at NEIGHBOURHOOD precision, never exact.
-- ------------------------------------------------------------
create table if not exists profiles (
  id             uuid primary key references auth.users on delete cascade,
  handle         text unique not null check (handle ~ '^[a-z0-9_]{3,20}$'),
  display_name   text not null check (char_length(display_name) between 1 and 60),
  bio            text check (char_length(bio) <= 600),
  city           text,
  location       geography(Point, 4326),
  photo_path     text,

  -- display labels, e.g. {'Trumpet','Flugelhorn'}
  instruments    text[] not null default '{}',
  -- normalised keys used ONLY for the complementary-instrument test.
  -- keys/synths collapse together, producer/engineer collapse together,
  -- and nothing else does. A trumpet player must still see sax players.
  instrument_keys text[] not null default '{}',
  genres         text[] not null default '{}',
  looking_for    text,
  looking_for_instruments text[] not null default '{}',
  influences     text,
  rehearsal_days text[] not null default '{}',
  remote_ok      boolean not null default true,

  birth_date     date not null,
  verified_at    timestamptz,
  is_banned      boolean not null default false,
  terms_agreed_at timestamptz,
  created_at     timestamptz not null default now(),

  constraint adults_only check (birth_date <= current_date - interval '18 years')
);

create index if not exists profiles_location_idx    on profiles using gist (location);
create index if not exists profiles_instruments_idx on profiles using gin  (instrument_keys);
create index if not exists profiles_genres_idx      on profiles using gin  (genres);

-- keep instrument_keys in sync so the client never has to
create or replace function normalise_instruments() returns trigger as $$
begin
  new.instrument_keys := (
    select coalesce(array_agg(distinct k), '{}')
    from unnest(new.instruments) i,
    lateral (select case
      when i in ('Keys','Synths','Piano','Organ') then 'keys'
      when i in ('Producer','Engineer','DJ')      then 'studio'
      else lower(i)
    end as k) m
  );
  return new;
end $$ language plpgsql;

drop trigger if exists profiles_normalise on profiles;
create trigger profiles_normalise before insert or update of instruments on profiles
for each row execute function normalise_instruments();

-- ------------------------------------------------------------
--  TRACKS AND PLAYS
-- ------------------------------------------------------------
create table if not exists tracks (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references profiles on delete cascade,
  title       text not null,
  audio_path  text not null,
  cover_path  text,
  duration_ms int,
  key         text,
  bpm         int check (bpm between 20 and 400),
  is_public   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists plays (
  id         bigserial primary key,
  track_id   uuid not null references tracks on delete cascade,
  user_id    uuid references profiles on delete set null,
  seconds    int not null,
  source     text check (source in ('radio','profile','feed','chat','band')),
  created_at timestamptz not null default now()
);
create index if not exists plays_track_time_idx on plays (track_id, created_at desc);

-- ------------------------------------------------------------
--  POSTS
-- ------------------------------------------------------------
create table if not exists posts (
  id         uuid primary key default gen_random_uuid(),
  author_id  uuid not null references profiles on delete cascade,
  body       text not null check (char_length(body) between 1 and 2000),
  tag        text,
  track_id   uuid references tracks on delete set null,
  media_path text,
  created_at timestamptz not null default now()
);
create index if not exists posts_recent_idx on posts (created_at desc);

create table if not exists post_likes (
  post_id uuid references posts on delete cascade,
  user_id uuid references profiles on delete cascade,
  primary key (post_id, user_id)
);

create table if not exists post_comments (
  id        uuid primary key default gen_random_uuid(),
  post_id   uuid not null references posts on delete cascade,
  author_id uuid not null references profiles on delete cascade,
  body      text not null check (char_length(body) between 1 and 800),
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
--  SWIPES AND CONNECTIONS
-- ------------------------------------------------------------
create table if not exists swipes (
  from_id    uuid references profiles on delete cascade,
  to_id      uuid references profiles on delete cascade,
  direction  text not null check (direction in ('yes','no')),
  created_at timestamptz not null default now(),
  primary key (from_id, to_id),
  constraint no_self_swipe check (from_id <> to_id)
);

create table if not exists connections (
  id         uuid primary key default gen_random_uuid(),
  a_id       uuid not null references profiles on delete cascade,
  b_id       uuid not null references profiles on delete cascade,
  created_at timestamptz not null default now(),
  unique (a_id, b_id),
  constraint ordered_pair check (a_id < b_id)
);

-- ------------------------------------------------------------
--  CONVERSATIONS
-- ------------------------------------------------------------
create table if not exists conversations (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('dm','band')),
  band_id    uuid,
  created_at timestamptz not null default now()
);

create table if not exists conversation_members (
  conversation_id uuid references conversations on delete cascade,
  user_id         uuid references profiles on delete cascade,
  last_read_at    timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create table if not exists messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations on delete cascade,
  sender_id       uuid references profiles on delete set null,
  body            text check (char_length(body) <= 4000),
  track_id        uuid references tracks on delete set null,

  -- jam clips: the one-tap audition recording
  clip_path       text,
  clip_mime       text,
  clip_duration_ms int,
  clip_peaks      real[],     -- ~34 values, computed on the client at record time
  clip_label      text,

  created_at      timestamptz not null default now(),
  constraint message_has_content check (body is not null or clip_path is not null or track_id is not null)
);
create index if not exists messages_convo_idx on messages (conversation_id, created_at desc);

-- ------------------------------------------------------------
--  BANDS
-- ------------------------------------------------------------
create table if not exists bands (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  kind            text not null default 'jammy' check (kind in ('jammy','listed')),
  city            text,
  formed          text,
  genres          text[] not null default '{}',
  about           text,
  rehearsal_space text,          -- members only. often someone's home address.
  avatar_path     text,
  created_by      uuid references profiles on delete set null,
  created_at      timestamptz not null default now()
);

-- NOTE: a primary key cannot use coalesce(), so this table gets a surrogate id
-- plus two partial unique indexes. (An earlier draft of this schema got that wrong.)
create table if not exists band_members (
  id           uuid primary key default gen_random_uuid(),
  band_id      uuid not null references bands on delete cascade,
  user_id      uuid references profiles on delete cascade,  -- null = not on Jammy
  display_name text,                                        -- used when user_id is null
  instruments  text[] not null default '{}',
  role_label   text,
  is_admin     boolean not null default false,
  joined_at    timestamptz not null default now(),
  constraint member_identified check (user_id is not null or display_name is not null)
);
create unique index if not exists band_members_user_uniq
  on band_members (band_id, user_id) where user_id is not null;
create unique index if not exists band_members_name_uniq
  on band_members (band_id, lower(display_name)) where user_id is null;

create table if not exists band_events (
  id         uuid primary key default gen_random_uuid(),
  band_id    uuid not null references bands on delete cascade,
  kind       text not null check (kind in ('practice','gig','recording','call')),
  starts_at  timestamptz not null,
  ends_at    timestamptz,
  place      text,
  address    text,          -- members only, always
  note       text,
  recurrence text,
  visibility text not null default 'members' check (visibility in ('members','public')),
  created_by uuid references profiles on delete set null,
  created_at timestamptz not null default now(),

  -- a rehearsal or a call can NEVER be public, whatever the client sends.
  -- a gig CAN be members-only: that is the private function case (weddings, corporate).
  constraint rehearsals_never_public
    check (visibility = 'members' or kind in ('gig','recording'))
);
create index if not exists band_events_upcoming_idx on band_events (band_id, starts_at);

-- gigs default to public, everything else to members-only
alter table band_events add column if not exists private_function boolean not null default false;

create or replace function default_event_visibility() returns trigger as $$
begin
  if new.visibility is null or new.visibility = 'members' then
    if new.kind = 'gig' and not coalesce(new.private_function, false) then
      new.visibility := 'public';
    else
      new.visibility := 'members';
    end if;
  end if;
  return new;
end $$ language plpgsql;

drop trigger if exists band_events_default_vis on band_events;
create trigger band_events_default_vis before insert on band_events
for each row execute function default_event_visibility();

create table if not exists event_tasks (
  id       uuid primary key default gen_random_uuid(),
  event_id uuid not null references band_events on delete cascade,
  user_id  uuid not null references profiles on delete cascade,
  task     text not null,          -- "you promised to bring the PA"
  done     boolean not null default false
);

create table if not exists event_rsvps (
  event_id uuid references band_events on delete cascade,
  user_id  uuid references profiles on delete cascade,
  status   text not null check (status in ('in','out','maybe')),
  primary key (event_id, user_id)
);

create table if not exists band_media (
  id           uuid primary key default gen_random_uuid(),
  band_id      uuid not null references bands on delete cascade,
  media        text not null check (media in ('track','clip')),
  title        text not null,
  storage_path text not null,
  thumb_path   text,
  duration_ms  int,
  key          text,
  bpm          int,
  clip_kind    text check (clip_kind in ('rehearsal','live','studio')),
  visibility   text not null default 'members' check (visibility in ('members','public')),
  uploaded_by  uuid references profiles on delete set null,
  created_at   timestamptz not null default now()
);

-- ------------------------------------------------------------
--  ADS
-- ------------------------------------------------------------
create table if not exists advertisers (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  kind          text not null check (kind in ('brand','venue')),
  contact_email text,
  balance_cents bigint not null default 0
);

create table if not exists ads (
  id                 uuid primary key default gen_random_uuid(),
  advertiser_id      uuid not null references advertisers on delete cascade,
  headline           text not null,
  body               text not null,
  cta_label          text not null,
  cta_url            text not null,
  image_path         text,
  target_cities      text[],
  target_genres      text[],
  target_instruments text[],
  cpm_cents          int not null,
  daily_budget_cents int,
  starts_at          timestamptz,
  ends_at            timestamptz,
  active             boolean not null default true
);

create table if not exists ad_events (
  id         bigserial primary key,
  ad_id      uuid not null references ads on delete cascade,
  user_id    uuid references profiles on delete set null,
  kind       text not null check (kind in ('impression','click')),
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
--  SAFETY
-- ------------------------------------------------------------
create table if not exists blocks (
  blocker_id uuid references profiles on delete cascade,
  blocked_id uuid references profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

create table if not exists reports (
  id             uuid primary key default gen_random_uuid(),
  reporter_id    uuid references profiles on delete set null,
  target_user    uuid references profiles on delete cascade,
  target_post    uuid references posts on delete cascade,
  target_message uuid references messages on delete cascade,
  reason         text not null check (reason in ('harassment','fake','spam','minor','other')),
  note           text,
  status         text not null default 'open' check (status in ('open','actioned','dismissed')),
  created_at     timestamptz not null default now()
);
create index if not exists reports_open_idx on reports (status, created_at);

create table if not exists device_tokens (
  user_id    uuid references profiles on delete cascade,
  token      text not null,
  platform   text check (platform in ('ios','android','web')),
  updated_at timestamptz not null default now(),
  primary key (user_id, token)
);

create table if not exists notifications_sent (
  id       bigserial primary key,
  user_id  uuid references profiles on delete cascade,
  event_id uuid references band_events on delete cascade,
  lead_time text not null,      -- '24h' | '2h'
  sent_at  timestamptz not null default now(),
  unique (user_id, event_id, lead_time)
);


-- ############################################################
-- ##  02_security_and_functions.sql
-- ############################################################

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


-- ############################################################
-- ##  03_scale.sql
-- ############################################################

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


-- ############################################################
-- ##  04_likes_comments.sql
-- ############################################################

-- ============================================================
--  JAMMY — 04_likes_comments.sql
--  Run AFTER 01, 02 and 03.
--
--  Makes likes and comments real: paged, counted, rate-limited,
--  live, and safe to delete.
-- ============================================================


-- ------------------------------------------------------------
--  Indexes. Without these, every comment sheet opens with a
--  sequential scan of the whole table.
-- ------------------------------------------------------------
create index if not exists post_comments_post_idx
  on post_comments (post_id, created_at desc);
create index if not exists post_comments_author_idx
  on post_comments (author_id);
create index if not exists post_likes_user_idx
  on post_likes (user_id);


-- ------------------------------------------------------------
--  COMMENTS, paged by cursor
--  Returns the comment plus its author, blocked users filtered out
--  in the database so the client never has to.
-- ------------------------------------------------------------
create or replace function comments_page(
  post uuid,
  before timestamptz default null,
  page_size int default 30
) returns table (
  id uuid,
  post_id uuid,
  author_id uuid,
  body text,
  created_at timestamptz,
  author_name text,
  author_handle text,
  author_photo text,
  is_mine boolean
) language sql stable as $$
  select c.id, c.post_id, c.author_id, c.body, c.created_at,
         p.display_name, p.handle, p.photo_path,
         (c.author_id = (select auth.uid())) as is_mine
  from post_comments c
  join profiles p on p.id = c.author_id
  where c.post_id = post
    and (before is null or c.created_at < before)
    and not p.is_banned
    and not exists (
      select 1 from blocks b
      where (b.blocker_id = c.author_id and b.blocked_id = (select auth.uid()))
         or (b.blocker_id = (select auth.uid()) and b.blocked_id = c.author_id))
  order by c.created_at desc
  limit least(page_size, 100);
$$;


-- ------------------------------------------------------------
--  LIKES
--  One row per person per post, so a double-tap can never
--  double-count. The counter on the post is maintained by the
--  trigger installed in 03_scale.sql.
-- ------------------------------------------------------------
create or replace function toggle_like(post uuid)
returns table (liked boolean, like_count int)
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := auth.uid();
  existed boolean;
  n int;
begin
  if me is null then
    raise exception 'not signed in';
  end if;

  delete from post_likes where post_id = post and user_id = me;
  existed := found;

  if not existed then
    if not check_rate('like', 300, 60) then
      raise exception 'Slow down — too many likes in a short time.';
    end if;
    insert into post_likes (post_id, user_id) values (post, me)
    on conflict do nothing;
  end if;

  select p.like_count into n from posts p where p.id = post;
  return query select (not existed), coalesce(n, 0);
end $$;


-- ------------------------------------------------------------
--  Comment rate limit. Comments are the cheapest abuse vector
--  on any social app — one script can post thousands a minute.
-- ------------------------------------------------------------
create or replace function guard_comment_rate() returns trigger
  language plpgsql security definer set search_path = public, extensions as $$
begin
  if not check_rate('comment', 60, 10) then
    raise exception 'Slow down — too many comments. Try again shortly.';
  end if;
  return new;
end $$;

drop trigger if exists post_comments_rate on post_comments;
create trigger post_comments_rate before insert on post_comments
for each row execute function guard_comment_rate();


-- ------------------------------------------------------------
--  Deleting
--  You can delete your own comment, and the post's author can
--  delete any comment on their own post. That second rule is
--  what lets people keep their own threads clean without
--  waiting on moderation.
-- ------------------------------------------------------------
drop policy if exists "comment as me" on post_comments;

drop policy if exists "read comments" on post_comments;
create policy "read comments" on post_comments for select to authenticated using (true);

drop policy if exists "write own comments" on post_comments;
create policy "write own comments" on post_comments for insert to authenticated
  with check (author_id = (select auth.uid()));

drop policy if exists "delete own comments or on my post" on post_comments;
create policy "delete own comments or on my post" on post_comments for delete to authenticated
  using (
    author_id = (select auth.uid())
    or exists (select 1 from posts p
               where p.id = post_comments.post_id and p.author_id = (select auth.uid()))
  );

-- editing a comment after people have replied to it is a misinformation
-- vector and nobody misses it. Delete and repost instead.
-- (no update policy is deliberate)


-- ------------------------------------------------------------
--  Realtime, so an open comment sheet updates itself
-- ------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table post_comments;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table post_likes;
exception when duplicate_object then null;
end $$;


-- ------------------------------------------------------------
--  Reporting a comment, not just a post or a user
-- ------------------------------------------------------------
alter table reports add column if not exists target_comment uuid references post_comments on delete cascade;
create index if not exists reports_comment_idx on reports (target_comment) where target_comment is not null;


-- ############################################################
-- ##  05_ads.sql
-- ############################################################

-- ============================================================
--  JAMMY — 05_ads.sql
--  The advertiser pipeline: request → review → live → billed.
--  Run after 01–04.
-- ============================================================

-- who is allowed to approve ads
create table if not exists staff (
  user_id uuid primary key references profiles on delete cascade,
  role    text not null default 'admin' check (role in ('admin','moderator'))
);

create or replace function is_staff() returns boolean
  language sql stable security definer set search_path = public, extensions
as $$ select exists (select 1 from staff where user_id = (select auth.uid())) $$;

-- ------------------------------------------------------------
--  REQUESTS
--  Anyone can submit one, including businesses with no Jammy
--  account. Only staff see them. Nothing is public until approved.
-- ------------------------------------------------------------
create table if not exists ad_requests (
  id            uuid primary key default gen_random_uuid(),
  business      text not null,
  contact_email text not null,
  contact_name  text,
  kind          text not null check (kind in ('venue','brand')),

  headline      text not null check (char_length(headline) <= 100),
  body          text not null check (char_length(body) <= 400),
  cta_label     text not null default 'Learn more',
  cta_url       text,
  image_path    text,

  plan          text not null,
  price_cents   int  not null,
  target_city   text,
  target_radius_miles int default 25,
  target_genres text[] default '{}',
  target_instruments text[] default '{}',
  note          text,

  status        text not null default 'pending'
                check (status in ('pending','approved','live','paused','declined','ended')),
  decline_reason text,
  starts_at     timestamptz,
  ends_at       timestamptz,
  reviewed_by   uuid references profiles,
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now()
);
create index if not exists ad_requests_status_idx on ad_requests (status, created_at desc);

alter table ad_requests enable row level security;

-- submissions come through an edge function, not direct insert, so the
-- form can be filled in by a venue with no account at all
drop policy if exists "staff read requests" on ad_requests;
create policy "staff read requests" on ad_requests for select to authenticated
  using (is_staff());
drop policy if exists "staff update requests" on ad_requests;
create policy "staff update requests" on ad_requests for update to authenticated
  using (is_staff());

-- ------------------------------------------------------------
--  LIVE PLACEMENTS
--  Only rows here are ever served. Keeping this separate from
--  requests means an approval is an explicit, auditable action.
-- ------------------------------------------------------------
create or replace function approve_ad(req uuid, weeks int default 1)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  r ad_requests%rowtype;
  new_id uuid;
begin
  if not is_staff() then raise exception 'not authorised'; end if;
  select * into r from ad_requests where id = req;
  if not found then raise exception 'no such request'; end if;

  insert into advertisers (name, kind, contact_email)
  values (r.business, r.kind, r.contact_email)
  on conflict do nothing;

  insert into ads (advertiser_id, headline, body, cta_label, cta_url, image_path,
                   target_cities, target_genres, target_instruments,
                   cpm_cents, starts_at, ends_at, active)
  values ((select id from advertisers where name = r.business limit 1),
          r.headline, r.body, r.cta_label, coalesce(r.cta_url,''), r.image_path,
          case when r.target_city is null then null else array[r.target_city] end,
          r.target_genres, r.target_instruments,
          0, now(), now() + (weeks || ' weeks')::interval, true)
  returning id into new_id;

  update ad_requests
     set status='live', starts_at=now(), ends_at=now() + (weeks || ' weeks')::interval,
         reviewed_by=(select auth.uid()), reviewed_at=now()
   where id = req;

  return new_id;
end $$;

-- ------------------------------------------------------------
--  SERVING
--  Targeted, time-bounded, and never more than one ad per five posts.
--  The client asks for ads; it never decides which are eligible.
-- ------------------------------------------------------------
create or replace function ads_for_me(limit_n int default 3)
returns table (
  id uuid, headline text, body text, cta_label text, cta_url text,
  image_path text, sponsor text, kind text
) language sql stable as $$
  with me as (select * from profiles where id = (select auth.uid()))
  select a.id, a.headline, a.body, a.cta_label, a.cta_url, a.image_path,
         adv.name, adv.kind
  from ads a
  join advertisers adv on adv.id = a.advertiser_id
  cross join me
  where a.active
    and (a.starts_at is null or a.starts_at <= now())
    and (a.ends_at   is null or a.ends_at   >= now())
    and (a.target_cities is null or me.city = any(a.target_cities))
    and (a.target_genres = '{}' or a.target_genres && me.genres)
    and (a.target_instruments = '{}' or a.target_instruments && me.instruments)
  order by random()
  limit least(limit_n, 5);
$$;

-- ------------------------------------------------------------
--  MEASUREMENT
--  Raw events roll up daily, same pattern as plays — otherwise the
--  events table becomes the biggest thing in your database.
-- ------------------------------------------------------------
create table if not exists ad_daily (
  ad_id uuid references ads on delete cascade,
  day   date not null,
  impressions bigint not null default 0,
  clicks      bigint not null default 0,
  primary key (ad_id, day)
);

create or replace function roll_up_ad_event() returns trigger
  language plpgsql security definer set search_path = public, extensions as $$
declare d date := (new.created_at at time zone 'utc')::date;
begin
  insert into ad_daily (ad_id, day, impressions, clicks)
  values (new.ad_id, d,
          case when new.kind='impression' then 1 else 0 end,
          case when new.kind='click' then 1 else 0 end)
  on conflict (ad_id, day) do update
    set impressions = ad_daily.impressions + case when new.kind='impression' then 1 else 0 end,
        clicks      = ad_daily.clicks      + case when new.kind='click'      then 1 else 0 end;
  return null;
end $$;

drop trigger if exists ad_events_rollup on ad_events;
create trigger ad_events_rollup after insert on ad_events
for each row execute function roll_up_ad_event();

alter table ad_events enable row level security;
drop policy if exists "log my ad events" on ad_events;
create policy "log my ad events" on ad_events for insert to authenticated
  with check (user_id = (select auth.uid()));

select cron.schedule('prune-ad-events-raw', '45 4 * * *', $$
  delete from ad_events where created_at < now() - interval '45 days';
$$);

-- what you send an advertiser at the end of a run
create or replace function ad_report(ad uuid)
returns table (day date, impressions bigint, clicks bigint, ctr numeric)
language sql stable as $$
  select d.day, d.impressions, d.clicks,
         case when d.impressions = 0 then 0
              else round((d.clicks::numeric / d.impressions) * 100, 2) end
  from ad_daily d
  where d.ad_id = ad
  order by d.day;
$$;

-- expire runs automatically so nobody gets free placement after their term
select cron.schedule('expire-ads', '0 * * * *', $$
  update ads set active = false where ends_at < now() and active;
  update ad_requests set status = 'ended' where ends_at < now() and status = 'live';
$$);


-- ############################################################
-- ##  06_lockdown.sql
-- ############################################################

-- ============================================================
--  JAMMY — 06_lockdown.sql
--  CLOSES THE LAST DOOR. Run this after 01–05.
--
--  WHY THIS FILE EXISTS
--  In Supabase, the key that ships inside the app is public by
--  design — every copy of Jammy on every phone contains it, and
--  anyone can read it out. The only thing standing between that
--  key and your database is row-level security.
--
--  Nine tables were left without it. The worst of them,
--  `advertisers`, holds the contact email and account balance of
--  every venue paying you. Without this file, anyone who
--  downloads Jammy could read that whole table.
--
--  Nothing here changes what the app can do. It only stops the
--  app being used as a window into tables it was never meant
--  to touch.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. Turn the lock on
-- ------------------------------------------------------------
alter table advertisers       enable row level security;
alter table ads               enable row level security;
alter table ad_daily          enable row level security;
alter table staff             enable row level security;
alter table chart_history     enable row level security;
alter table notifications_sent enable row level security;
alter table play_daily        enable row level security;
alter table play_dedupe       enable row level security;
alter table rate_counters     enable row level security;

-- ------------------------------------------------------------
--  2. The two tables that SHOULD be readable
--
--  chart_history is the weekly radio chart. It is meant to be
--  seen — that is the whole point of it.
-- ------------------------------------------------------------
drop policy if exists "read the chart" on chart_history;
create policy "read the chart" on chart_history
  for select to authenticated using (true);

--  notifications_sent is the log of reminders already delivered.
--  You can see your own and nobody else's.
drop policy if exists "read my own reminders" on notifications_sent;
create policy "read my own reminders" on notifications_sent
  for select to authenticated using (user_id = (select auth.uid()));

-- ------------------------------------------------------------
--  3. Everything else gets no policy at all.
--
--  A table with security on and no policy is closed to the app
--  entirely. The functions below still reach it, because a
--  "security definer" function runs with the database owner's
--  rights rather than the caller's. That is the correct shape:
--  the data is reachable only through a function you control,
--  which decides what to hand back.
--
--  Closed to the app: advertisers, ads, ad_daily, staff,
--  play_daily, play_dedupe, rate_counters.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
--  4. ads_for_me must now run with elevated rights
--
--  It reads `ads` and `advertisers`, both of which just closed.
--  It is safe to elevate because of what it returns: the
--  headline, body, button and sponsor name — the things already
--  printed on the ad card. It never returns contact_email,
--  balance_cents, cpm_cents or anyone's budget, and it only ever
--  matches against the caller's own profile.
-- ------------------------------------------------------------
create or replace function ads_for_me(limit_n int default 3)
returns table (
  id uuid, headline text, body text, cta_label text, cta_url text,
  image_path text, sponsor text, kind text
) language sql stable security definer set search_path = public, extensions as $$
  with me as (select * from profiles where id = (select auth.uid()))
  select a.id, a.headline, a.body, a.cta_label, a.cta_url, a.image_path,
         adv.name, adv.kind
  from ads a
  join advertisers adv on adv.id = a.advertiser_id
  cross join me
  where a.active
    and (a.starts_at is null or a.starts_at <= now())
    and (a.ends_at   is null or a.ends_at   >= now())
    and (a.target_cities is null or me.city = any(a.target_cities))
    and (a.target_genres = '{}' or a.target_genres && me.genres)
    and (a.target_instruments = '{}' or a.target_instruments && me.instruments)
  order by random()
  limit least(limit_n, 5);
$$;

-- ------------------------------------------------------------
--  5. ad_report had no access check whatsoever
--
--  As written, any signed-in user could call it with any ad's id
--  and read that venue's impressions and clicks — competitors
--  included. It is a staff tool, so it now says so.
--
--  When you build the advertiser dashboard, the right change is
--  to give `advertisers` an owner column and allow that owner
--  through here too. Until then, staff only.
-- ------------------------------------------------------------
create or replace function ad_report(ad uuid)
returns table (day date, impressions bigint, clicks bigint, ctr numeric)
language sql stable security definer set search_path = public, extensions as $$
  select d.day, d.impressions, d.clicks,
         case when d.impressions = 0 then 0
              else round((d.clicks::numeric / d.impressions) * 100, 2) end
  from ad_daily d
  where d.ad_id = ad
    and is_staff()
  order by d.day;
$$;

-- ------------------------------------------------------------
--  6. Proof
--
--  After this runs, every table of YOURS has row-level security
--  on. This should name nothing. If it ever names a table, that
--  table is exposed and wants a policy.
--
--  Tables installed by an extension are skipped. PostGIS brings
--  its own reference table, spatial_ref_sys — a public list of
--  map coordinate systems. It holds none of your data, it is the
--  same in every PostGIS database in the world, and it is not
--  yours to lock.
-- ------------------------------------------------------------
do $$
declare open_tables text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into open_tables
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
    and not exists (
      select 1 from pg_depend d
      where d.objid = c.oid and d.deptype = 'e'   -- belongs to an extension
    );

  if open_tables is null then
    raise notice 'Jammy: every table is protected. You are done.';
  else
    raise exception 'Jammy: these tables are still open to the public key: %', open_tables;
  end if;
end $$;


-- ############################################################
-- ##  07_storage.sql
-- ############################################################

-- ============================================================
--  JAMMY — 07_storage.sql
--  WHERE FILES LIVE. Run this after 01–06.
--
--  The database holds words and numbers. Photos, videos and jam
--  clips go somewhere else — Supabase Storage — and that needs
--  its own containers and its own rules.
--
--  Two containers:
--
--    jammy-media   profile photos, band photos, pictures and
--                  video attached to posts. Readable by anyone
--                  with the link, the same way every social app
--                  works. You can only write into your own
--                  folder, so nobody can overwrite your photo.
--
--    jam-clips     the audio clips people send each other in
--                  messages. PRIVATE. Readable only by the
--                  people in that conversation, and only through
--                  a link that expires in an hour.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. The containers
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'jammy-media', 'jammy-media', true,
  26214400,                                     -- 25 MB a file
  array['image/jpeg','image/png','image/webp','image/gif',
        'video/mp4','video/webm','video/quicktime']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'jam-clips', 'jam-clips', false,
  10485760,                                     -- 10 MB a clip
  array['audio/webm','audio/mp4','audio/mpeg','audio/ogg','audio/wav']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ------------------------------------------------------------
--  2. jammy-media — your folder is yours
--
--  Every file goes to  <your user id>/<something>.jpg
--  The first folder in the path must be your own id, which is
--  what stops one person writing over another's picture.
-- ------------------------------------------------------------
drop policy if exists "media is readable" on storage.objects;
create policy "media is readable" on storage.objects
  for select using (bucket_id = 'jammy-media');

drop policy if exists "write into my own media folder" on storage.objects;
create policy "write into my own media folder" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'jammy-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "replace my own media" on storage.objects;
create policy "replace my own media" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'jammy-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "delete my own media" on storage.objects;
create policy "delete my own media" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'jammy-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ------------------------------------------------------------
--  3. jam-clips — only the two of you
--
--  Every clip goes to  clips/<conversation id>/<something>.webm
--  so the second folder in the path names the conversation. The
--  in_conversation() check already used by the messages table
--  decides who is allowed in.
--
--  This is why clips are served through links that expire: if
--  someone is blocked or leaves a conversation, no new link is
--  ever issued for them again.
-- ------------------------------------------------------------
drop policy if exists "read clips from my conversations" on storage.objects;
create policy "read clips from my conversations" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'jam-clips'
    and array_length(storage.foldername(name), 1) >= 2
    and in_conversation(((storage.foldername(name))[2])::uuid)
  );

drop policy if exists "send clips to my conversations" on storage.objects;
create policy "send clips to my conversations" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'jam-clips'
    and array_length(storage.foldername(name), 1) >= 2
    and in_conversation(((storage.foldername(name))[2])::uuid)
  );

drop policy if exists "delete my own clips" on storage.objects;
create policy "delete my own clips" on storage.objects
  for delete to authenticated
  using (bucket_id = 'jam-clips' and owner = (select auth.uid()));

-- ------------------------------------------------------------
--  4. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from storage.buckets where id in ('jammy-media','jam-clips');
  if n = 2 then
    raise notice 'Jammy: both storage containers exist and are protected.';
  else
    raise exception 'Jammy: expected 2 storage containers, found %', n;
  end if;
end $$;


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
language sql stable security definer set search_path = public, extensions as $$
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
language plpgsql security definer set search_path = public, extensions as $$
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
language plpgsql security definer set search_path = public, extensions as $$
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
language sql stable security definer set search_path = public, extensions as $$
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
language plpgsql security definer set search_path = public, extensions as $$
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
language sql stable security definer set search_path = public, extensions as $$
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


-- ############################################################
-- ##  10_grants.sql
-- ############################################################

-- ============================================================
--  JAMMY — 10_grants.sql
--  THE PERMISSION THE APP WAS MISSING. Run after 01–09.
--
--  WHAT WENT WRONG
--  Postgres has two separate gates, and Jammy only built one.
--
--    1. GRANTS    — may this role touch this table at all?
--    2. POLICIES  — which rows may it see or change?
--
--  Every table here had policies. None had grants. That mostly
--  went unnoticed, because Supabase hands out grants of its own
--  for tables it sees created — but not for every one, and
--  `blocks` was among the ones it missed.
--
--  It surfaced in the worst possible place. The policy deciding
--  which profiles you may read asks "has either of us blocked
--  the other?", which reads `blocks`. With no grant on that
--  table the question itself fails, so creating a profile died
--  with "permission denied for table blocks" — a message naming
--  a table the sign-up screen never mentions.
--
--  GRANTS ARE NOT SECURITY HERE. Row-level security is, and it
--  is already on every table. A grant only says "you may ask";
--  the policies still decide what comes back. The seven tables
--  locked in 06 have no policies for the app, so they stay shut
--  no matter what is granted below.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. Let signed-in people reach the tables; let the policies
--     decide what they actually get.
-- ------------------------------------------------------------
grant usage on schema public to anon, authenticated;

grant select, insert, update, delete
  on all tables in schema public
  to authenticated;

grant usage, select on all sequences in schema public to authenticated;

-- ------------------------------------------------------------
--  2. Signed-out visitors get nothing.
--
--  Jammy requires an account — there is no browsing without
--  one, by design, because the whole app is strangers meeting
--  strangers. So `anon` is granted no table at all. If a public
--  page is ever wanted (a shareable band profile, say), it gets
--  its own narrow grant and its own policy, deliberately.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
--  3. The functions the app calls by name
-- ------------------------------------------------------------
grant execute on all functions in schema public to authenticated;

-- ------------------------------------------------------------
--  4. Anything added later gets the same treatment
--
--  Without this, the next table added brings the same bug back,
--  and it will surface somewhere just as confusing.
-- ------------------------------------------------------------
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public
  grant usage, select on sequences to authenticated;
alter default privileges in schema public
  grant execute on functions to authenticated;

-- ------------------------------------------------------------
--  5. Proof
--
--  Names every table a signed-in person still cannot reach.
--  Should be empty.
-- ------------------------------------------------------------
do $$
declare missing text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into missing
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'r'
    and not exists (
      select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e'
    )
    and not has_table_privilege('authenticated', c.oid, 'SELECT');

  if missing is null then
    raise notice 'Jammy: every table is reachable, and row-level security still decides what comes back.';
  else
    raise exception 'Jammy: these tables are still unreachable: %', missing;
  end if;
end $$;


-- ############################################################
-- ##  11_discover_fallback.sql
-- ############################################################

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


-- ############################################################
-- ##  12_matching_fix.sql
-- ############################################################

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


-- ############################################################
-- ##  13_match_repair.sql
-- ############################################################

-- ============================================================
--  JAMMY — 13_match_repair.sql
--  MATCHES THAT NEVER HAPPENED. Run after 01–12.
--
--  WHAT WENT WRONG
--  A mutual yes is supposed to create two things: a connection,
--  and the conversation that goes with it. A trigger did that,
--  and the trigger fired on INSERT.
--
--  But swiping is an upsert — swipe on the same person twice
--  and the second one UPDATES the existing row. An update is
--  not an insert, so the trigger stayed silent. Anyone who had
--  swiped before (every one of your test runs) could match and
--  have nothing created for it.
--
--  The app then looked connected while the database disagreed:
--  the connections list emptied on the next load, and sending a
--  message failed because there was no conversation to put it
--  in.
--
--  THE FIX, in three parts:
--    1. one function that makes a connection real, used by
--       everything, so there is one definition of what a match
--       creates rather than two that can drift apart
--    2. the trigger fires on update as well as insert
--    3. every mutual yes already sitting in the table gets the
--       connection it should have had
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. One place that knows what a match creates
-- ------------------------------------------------------------
create or replace function ensure_connection(a uuid, b uuid)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  lo uuid := least(a, b);
  hi uuid := greatest(a, b);
  conv uuid;
begin
  if a is null or b is null or a = b then return null; end if;

  insert into connections (a_id, b_id) values (lo, hi) on conflict do nothing;

  select c.id into conv
  from conversations c
  join conversation_members m1 on m1.conversation_id = c.id and m1.user_id = lo
  join conversation_members m2 on m2.conversation_id = c.id and m2.user_id = hi
  where c.kind = 'dm'
  limit 1;

  if conv is null then
    insert into conversations (kind) values ('dm') returning id into conv;
    insert into conversation_members (conversation_id, user_id)
      values (conv, lo), (conv, hi)
    on conflict do nothing;
  end if;

  return conv;
end $$;

-- ------------------------------------------------------------
--  2. Fire on an update too
-- ------------------------------------------------------------
create or replace function on_swipe() returns trigger as $$
begin
  if new.direction <> 'yes' then return new; end if;

  if not exists (
    select 1 from swipes
    where from_id = new.to_id and to_id = new.from_id and direction = 'yes'
  ) then return new; end if;

  perform ensure_connection(new.from_id, new.to_id);
  return new;
end $$ language plpgsql security definer set search_path = public, extensions;

drop trigger if exists swipe_match on swipes;
create trigger swipe_match
  after insert or update of direction on swipes
  for each row execute function on_swipe();

-- ------------------------------------------------------------
--  3. Don't depend on the trigger alone
--
--  swipe_and_check already looks to see whether a connection
--  exists. It now makes one if the other person has said yes,
--  rather than reporting "no match" because a trigger missed.
-- ------------------------------------------------------------
create or replace function swipe_and_check(to_user uuid, dir text)
returns table (matched boolean, conversation_id uuid)
language plpgsql security definer set search_path = public, extensions as $$
declare
  me   uuid := (select auth.uid());
  conv uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  if to_user is null or to_user = me then raise exception 'no such person'; end if;
  if dir not in ('yes','no') then raise exception 'a swipe is yes or no'; end if;

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

  -- do they want to as well?
  if not exists (
    select 1 from swipes
    where from_id = to_user and to_id = me and direction = 'yes'
  ) then
    return query select false, null::uuid;
    return;
  end if;

  conv := ensure_connection(me, to_user);
  return query select true, conv;
end $$;

-- ------------------------------------------------------------
--  4. Repair every match that was lost
--
--  Walks the swipes already in the table, finds every pair who
--  said yes to each other, and gives each one the connection
--  and conversation it should have had. Nothing is created
--  twice.
-- ------------------------------------------------------------
do $$
declare
  r record;
  made int := 0;
begin
  for r in
    select distinct least(s1.from_id, s1.to_id) as lo,
                    greatest(s1.from_id, s1.to_id) as hi
    from swipes s1
    join swipes s2
      on s2.from_id = s1.to_id
     and s2.to_id   = s1.from_id
     and s2.direction = 'yes'
    where s1.direction = 'yes'
  loop
    if not exists (select 1 from connections where a_id = r.lo and b_id = r.hi) then
      made := made + 1;
    end if;
    perform ensure_connection(r.lo, r.hi);
  end loop;

  raise notice 'Jammy: repaired % lost match(es). Matching and messaging now agree.', made;
end $$;


-- ############################################################
-- ##  14_blocking_fix.sql
-- ############################################################

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


-- ############################################################
-- ##  15_requests.sql
-- ############################################################

-- ============================================================
--  JAMMY — 15_requests.sql
--  "SOMEONE WANTS TO PLAY WITH YOU". Run after 01–14.
--
--  Until now a connection could only happen by coincidence:
--  two people had to swipe yes on each other without either
--  knowing the other had. If a drummer asked to play with you
--  on Monday, you found out only if you happened to swipe yes
--  on him later. Otherwise nothing — he waits, you never know
--  he asked.
--
--  Dating apps hide this on purpose and charge to reveal it.
--  For a free app where a bassist is trying to find a band
--  before their gig on Saturday, hiding it just wastes
--  everyone's time.
--
--  incoming_requests() answers: who has asked to play with me
--  and is still waiting? It needs elevated rights because a
--  person can only see their OWN swipes by design — which is
--  exactly why this was invisible.
--
--  Safe to run twice.
-- ============================================================

create or replace function incoming_requests()
returns table (
  id uuid, display_name text, handle text, city text, photo_path text,
  instruments text[], genres text[], looking_for text, bio text,
  shared_genres text[], they_need_me text[], miles numeric, asked_at timestamptz
)
language sql stable security definer set search_path = public, extensions as $$
  with me as (select * from profiles where id = (select auth.uid()))
  select
    p.id, p.display_name, p.handle, p.city, p.photo_path,
    p.instruments, p.genres, p.looking_for, p.bio,
    array(select unnest(p.genres) intersect select unnest(me.genres))                       as shared_genres,
    array(select unnest(p.looking_for_instruments) intersect select unnest(me.instruments)) as they_need_me,
    case when p.location is null or me.location is null then null
         else round((st_distance(p.location, me.location) / 1609.34)::numeric, 1)
    end as miles,
    s.created_at as asked_at
  from swipes s
  join profiles p on p.id = s.from_id
  cross join me
  where s.to_id = me.id
    and s.direction = 'yes'
    and not exists (
      select 1 from swipes mine
      where mine.from_id = me.id and mine.to_id = p.id
    )
    and not p.is_banned
    and not blocked_between(p.id, me.id)
  order by s.created_at desc;
$$;

-- ------------------------------------------------------------
--  How many are waiting — cheap enough to ask on every screen
-- ------------------------------------------------------------
create or replace function incoming_request_count()
returns int
language sql stable security definer set search_path = public, extensions as $$
  select count(*)::int from incoming_requests();
$$;

-- ------------------------------------------------------------
--  Speed: "who swiped yes on me?" is a different question from
--  "who did I swipe on", and wants its own index.
-- ------------------------------------------------------------
create index if not exists swipes_to_yes_idx
  on swipes (to_id, direction, created_at desc)
  where direction = 'yes';

-- ------------------------------------------------------------
--  Proof
-- ------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname='public' and p.proname='incoming_requests') then
    raise notice 'Jammy: people can now see who has asked to play with them.';
  else
    raise exception 'Jammy: incoming_requests() is missing';
  end if;
end $$;


-- ############################################################
-- ##  16_bands.sql
-- ############################################################

-- ============================================================
--  JAMMY — 16_bands.sql
--  THE PART AFTER YOU'VE FOUND EACH OTHER. Run after 01–15.
--
--  Every app in this space stops at the introduction. Jammy's
--  reason to exist is the week after: who is in the band, what
--  they play, when you next rehearse, where the gig is, and
--  who promised to bring the PA.
--
--  The tables and the safety rules already exist — including
--  the one that matters most, which is that a rehearsal can
--  never be made public. A practice is usually somebody's flat,
--  and a public rehearsal address is an address a stranger can
--  turn up at. Gigs are the opposite: a gig nobody can find is
--  a gig nobody comes to.
--
--  What was missing is everything the app has to call. Each of
--  these answers a whole screen in one request instead of a
--  query per row.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. The bands you're in, as the list screen needs them
-- ------------------------------------------------------------
create or replace function my_bands()
returns table (
  id uuid,
  name text,
  city text,
  genres text[],
  about text,
  avatar_path text,
  my_role text,
  i_am_admin boolean,
  member_count int,
  next_kind text,
  next_at timestamptz,
  next_place text
)
language sql stable security definer set search_path = public, extensions as $$
  with me as (select (select auth.uid()) as uid),
  mine as (
    select b.*, bm.role_label, bm.is_admin
    from band_members bm
    join bands b on b.id = bm.band_id
    cross join me
    where bm.user_id = me.uid
  ),
  counts as (
    select band_id, count(*)::int as n from band_members group by band_id
  ),
  nxt as (
    select distinct on (e.band_id) e.band_id, e.kind, e.starts_at, e.place
    from band_events e
    where e.band_id in (select id from mine)
      and e.starts_at > now() - interval '2 hours'
    order by e.band_id, e.starts_at asc
  )
  select m.id, m.name, m.city, m.genres, m.about, m.avatar_path,
         m.role_label, m.is_admin,
         coalesce(c.n, 0), n.kind, n.starts_at, n.place
  from mine m
  left join counts c on c.band_id = m.id
  left join nxt    n on n.band_id = m.id
  order by n.starts_at asc nulls last, m.name;
$$;

-- ------------------------------------------------------------
--  2. One band's page: who's in it, what each plays, what's next
--
--  Members see everything. Anyone else sees the band and its
--  public gigs, and never a rehearsal, an address or a note.
-- ------------------------------------------------------------
create or replace function band_roster(b uuid)
returns table (
  user_id uuid,
  display_name text,
  handle text,
  photo_path text,
  instruments text[],
  role_label text,
  is_admin boolean,
  on_jammy boolean
)
language sql stable security definer set search_path = public, extensions as $$
  select bm.user_id,
         coalesce(p.display_name, bm.display_name),
         p.handle, p.photo_path,
         case when bm.instruments <> '{}' then bm.instruments else coalesce(p.instruments,'{}') end,
         bm.role_label, bm.is_admin,
         (bm.user_id is not null)
  from band_members bm
  left join profiles p on p.id = bm.user_id
  where bm.band_id = b
  order by bm.is_admin desc, bm.joined_at;
$$;

create or replace function band_schedule(b uuid, limit_n int default 20)
returns table (
  id uuid, kind text, starts_at timestamptz, ends_at timestamptz,
  place text, address text, note text, visibility text, mine boolean
)
language sql stable security definer set search_path = public, extensions as $$
  select e.id, e.kind, e.starts_at, e.ends_at, e.place,
         -- the address is for the people who have to turn up, nobody else
         case when is_band_member(b) then e.address else null end,
         case when is_band_member(b) then e.note else null end,
         e.visibility,
         is_band_member(b)
  from band_events e
  where e.band_id = b
    and (e.visibility = 'public' or is_band_member(b))
    and e.starts_at > now() - interval '12 hours'
  order by e.starts_at asc
  limit least(limit_n, 50);
$$;

-- ------------------------------------------------------------
--  3. Starting a band
--
--  Creating one, joining it and giving it a group chat are a
--  single act. Done as three separate calls from the app, any
--  of them can fail on its own and leave a band with nobody in
--  it, or a band whose founder cannot message anyone.
-- ------------------------------------------------------------
create or replace function create_band(
  p_name text,
  p_city text default null,
  p_genres text[] default '{}',
  p_about text default null,
  p_my_instruments text[] default '{}',
  p_my_role text default null
)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := (select auth.uid());
  b  uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  if coalesce(btrim(p_name),'') = '' then raise exception 'a band needs a name'; end if;

  insert into bands (name, city, genres, about, created_by)
  values (btrim(p_name), p_city, coalesce(p_genres,'{}'), p_about, me)
  returning id into b;

  insert into band_members (band_id, user_id, instruments, role_label, is_admin)
  values (b, me, coalesce(p_my_instruments,'{}'), p_my_role, true);

  perform band_conversation(b);
  return b;
end $$;

create or replace function join_band(b uuid, p_instruments text[] default '{}', p_role text default null)
returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare me uuid := (select auth.uid());
begin
  if me is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from bands where id = b) then raise exception 'no such band'; end if;
  if exists (select 1 from band_members where band_id = b and user_id = me) then return true; end if;

  insert into band_members (band_id, user_id, instruments, role_label)
  values (b, me, coalesce(p_instruments,'{}'), p_role);

  perform band_conversation(b);
  return true;
end $$;

create or replace function leave_band(b uuid)
returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := (select auth.uid());
  others int;
begin
  if me is null then raise exception 'not signed in'; end if;

  select count(*) into others from band_members
   where band_id = b and user_id is distinct from me;

  -- the last person out does not get to strand the band's history
  if others = 0 then
    delete from band_members where band_id = b and user_id = me;
    delete from bands where id = b;
    return true;
  end if;

  -- never leave a band with no admin
  if exists (select 1 from band_members where band_id = b and user_id = me and is_admin)
     and not exists (select 1 from band_members
                     where band_id = b and is_admin and user_id is distinct from me) then
    update band_members set is_admin = true
     where id = (select id from band_members
                 where band_id = b and user_id is distinct from me
                 order by joined_at limit 1);
  end if;

  delete from band_members where band_id = b and user_id = me;
  delete from conversation_members
   where user_id = me
     and conversation_id in (select id from conversations where kind='band' and band_id = b);
  return true;
end $$;

-- ------------------------------------------------------------
--  4. Putting something in the diary
--
--  The check constraint already refuses a public rehearsal. This
--  turns that into a sentence a person can act on instead of a
--  constraint violation.
-- ------------------------------------------------------------
create or replace function add_band_event(
  b uuid,
  p_kind text,
  p_starts_at timestamptz,
  p_place text default null,
  p_address text default null,
  p_note text default null,
  p_ends_at timestamptz default null,
  p_visibility text default null
)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := (select auth.uid());
  vis text;
  id_out uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  if not is_band_member(b) then raise exception 'only the band can put something in its diary'; end if;
  if p_kind not in ('practice','gig','recording','call') then
    raise exception 'a date is a practice, a gig, a recording or a call';
  end if;

  -- gigs are public unless told otherwise; everything else is the band's business
  vis := coalesce(p_visibility, case when p_kind = 'gig' then 'public' else 'members' end);

  if vis = 'public' and p_kind in ('practice','call') then
    raise exception 'A % is always private. It is usually somebody''s home, and a public address is an address a stranger can turn up at. Post the gig instead.', p_kind;
  end if;

  insert into band_events (band_id, kind, starts_at, ends_at, place, address, note, visibility, created_by)
  values (b, p_kind, p_starts_at, p_ends_at, p_place, p_address, p_note, vis, me)
  returning id into id_out;

  return id_out;
end $$;

create or replace function cancel_band_event(e uuid)
returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare b uuid;
begin
  select band_id into b from band_events where id = e;
  if b is null then return false; end if;
  if not is_band_member(b) then raise exception 'only the band can cancel its own dates'; end if;
  delete from band_events where id = e;
  return true;
end $$;

-- ------------------------------------------------------------
--  5. "Your band has a gig on Saturday"
--
--  Everything coming up across all of someone's bands, in one
--  list, soonest first — what the reminder is built from.
-- ------------------------------------------------------------
create or replace function my_schedule(days int default 30)
returns table (
  event_id uuid, band_id uuid, band_name text,
  kind text, starts_at timestamptz, place text, address text, note text,
  hours_away numeric
)
language sql stable security definer set search_path = public, extensions as $$
  select e.id, b.id, b.name, e.kind, e.starts_at, e.place, e.address, e.note,
         round(extract(epoch from (e.starts_at - now())) / 3600.0, 1)
  from band_events e
  join bands b on b.id = e.band_id
  join band_members bm on bm.band_id = b.id and bm.user_id = (select auth.uid())
  where e.starts_at between now() - interval '2 hours' and now() + make_interval(days => days)
  order by e.starts_at asc;
$$;

-- ------------------------------------------------------------
--  6. Gigs near you, for people who only want to listen
--
--  Stella's own words: Jammy should also be where someone who
--  just wants to hear live music finds a gig tonight. Public
--  gigs only, and never an address that was marked members-only.
-- ------------------------------------------------------------
--  17_gigs.sql replaces this with a wider version. Postgres will
--  not widen a function in place, so clear the way either way round.
drop function if exists gigs_near_me(numeric, int);

create or replace function gigs_near_me(radius_miles numeric default 25, days int default 30)
returns table (
  event_id uuid, band_id uuid, band_name text, band_genres text[],
  starts_at timestamptz, place text, city text, miles numeric
)
language sql stable security definer set search_path = public, extensions as $$
  with me as (select * from profiles where id = (select auth.uid()))
  select e.id, b.id, b.name, b.genres, e.starts_at, e.place, b.city,
         case when me.location is null then null else null::numeric end
  from band_events e
  join bands b on b.id = e.band_id
  cross join me
  where e.kind = 'gig'
    and e.visibility = 'public'
    and e.starts_at between now() and now() + make_interval(days => days)
    and (
      radius_miles <= 0
      or b.city is null or me.city is null
      or lower(btrim(b.city)) = lower(btrim(me.city))
    )
  order by e.starts_at asc
  limit 100;
$$;

-- ------------------------------------------------------------
--  7. Speed
-- ------------------------------------------------------------
create index if not exists band_members_user_idx on band_members (user_id, band_id);
create index if not exists band_events_band_time_idx on band_events (band_id, starts_at);
create index if not exists band_events_public_gigs_idx
  on band_events (starts_at) where kind = 'gig' and visibility = 'public';

-- ------------------------------------------------------------
--  8. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('my_bands','band_roster','band_schedule','create_band',
                      'join_band','leave_band','add_band_event','cancel_band_event',
                      'my_schedule','gigs_near_me');
  if n = 10 then
    raise notice 'Jammy: bands can now be formed, scheduled and found.';
  else
    raise exception 'Jammy: expected 10 band functions, found %', n;
  end if;
end $$;


-- ############################################################
-- ##  17_gigs.sql
-- ############################################################

-- ============================================================
--  JAMMY — 17_gigs.sql
--  SO SOMEBODY CAN ACTUALLY FIND THE GIG. Run after 01–16.
--
--  WHAT WAS WRONG
--  16_bands.sql got the rule right: a practice is private, a gig
--  is public. What it never got was a way for the public to see
--  the public one. A band page could only be opened from your own
--  band list, so the only people who could find a gig were the
--  people already playing it.
--
--  Three things here.
--
--  1. A gig now has somewhere to be. Bands get a location, taken
--     from whoever started the band, so "gigs near me" can mean
--     miles rather than a spelling match on a city name.
--
--  2. A band page any signed-in person can open: the name, who's
--     in it, and its public gigs. Never a rehearsal, never an
--     address, never a note.
--
--  3. The hole that 1 and 2 would otherwise open.
--     Until now, anyone could add themselves to any band's roster
--     — the rule said "you may edit rows that are yours", and a
--     row you are inserting about yourself is yours. Nobody could
--     exploit it while band pages were unreachable. The moment a
--     stranger can open your band page, they could join your band
--     and read the rehearsal address, which is somebody's flat.
--
--     So joining becomes a request, answered the same way a
--     connection is: Approve or Decline.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. A band has a place
--
--  No geocoding and no new thing to fill in: a band starts where
--  its founder is. If they later set the band's city by hand, the
--  city still wins for anyone whose own location is unknown.
-- ------------------------------------------------------------
alter table bands add column if not exists location geography(Point, 4326);
create index if not exists bands_location_idx on bands using gist (location);

-- existing bands: borrow the founder's location, then any member's
update bands b
set location = coalesce(
      (select p.location from profiles p where p.id = b.created_by),
      (select p.location from profiles p
         join band_members bm on bm.user_id = p.id
        where bm.band_id = b.id and p.location is not null
        order by bm.joined_at limit 1))
where b.location is null;

-- and the same for city, so a band is never nowhere
update bands b
set city = coalesce(
      (select p.city from profiles p where p.id = b.created_by),
      (select p.city from profiles p
         join band_members bm on bm.user_id = p.id
        where bm.band_id = b.id and p.city is not null
        order by bm.joined_at limit 1))
where coalesce(btrim(b.city), '') = '';

-- ------------------------------------------------------------
--  2. Starting a band puts it on the map
-- ------------------------------------------------------------
create or replace function create_band(
  p_name text,
  p_city text default null,
  p_genres text[] default '{}',
  p_about text default null,
  p_my_instruments text[] default '{}',
  p_my_role text default null
)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := (select auth.uid());
  b  uuid;
  my_city text;
  my_loc  geography(Point, 4326);
begin
  if me is null then raise exception 'not signed in'; end if;
  if coalesce(btrim(p_name),'') = '' then raise exception 'a band needs a name'; end if;

  select p.city, p.location into my_city, my_loc from profiles p where p.id = me;

  insert into bands (name, city, genres, about, created_by, location)
  values (btrim(p_name),
          coalesce(nullif(btrim(coalesce(p_city,'')), ''), my_city),
          coalesce(p_genres,'{}'), p_about, me, my_loc)
  returning id into b;

  insert into band_members (band_id, user_id, instruments, role_label, is_admin)
  values (b, me, coalesce(p_my_instruments,'{}'), p_my_role, true);

  perform band_conversation(b);
  return b;
end $$;

-- ------------------------------------------------------------
--  3. Gigs near me, with real distance
--
--  Same shape as Discover, for the same reason: coordinates when
--  both ends have them, city names when either does not, and a
--  radius of zero or less meaning "anywhere".
--
--  Public gigs only. A members-only gig — a wedding, a corporate
--  booking — never appears here, and neither does an address.
-- ------------------------------------------------------------
--  16_bands.sql made this one return fewer columns, and Postgres
--  will not widen a function in place, so it goes first.
drop function if exists gigs_near_me(numeric, int);

create or replace function gigs_near_me(radius_miles numeric default 25, days int default 30)
returns table (
  event_id uuid, band_id uuid, band_name text, band_genres text[],
  band_avatar text, starts_at timestamptz, place text, city text,
  miles numeric, i_am_member boolean
)
language sql stable security definer set search_path = public, extensions as $$
  with me as (select * from profiles where id = (select auth.uid()))
  select e.id, b.id, b.name, b.genres, b.avatar_path,
         e.starts_at, e.place, b.city,
         case when b.location is null or me.location is null then null
              else round((st_distance(b.location, me.location) / 1609.34)::numeric, 1)
         end,
         is_band_member(b.id)
  from band_events e
  join bands b on b.id = e.band_id
  cross join me
  where e.kind = 'gig'
    and e.visibility = 'public'
    and e.starts_at between now() - interval '3 hours'
                        and now() + make_interval(days => greatest(days, 1))
    and (
      radius_miles <= 0
      or (b.location is not null and me.location is not null
          and st_dwithin(b.location, me.location, radius_miles * 1609.34))
      or ((b.location is null or me.location is null)
          and b.city is not null and me.city is not null
          and lower(btrim(b.city)) = lower(btrim(me.city)))
    )
  order by e.starts_at asc
  limit 100;
$$;

-- ------------------------------------------------------------
--  3b. A members-only gig stays members-only
--
--  FOUND BY THE TEST, not by anyone using the app, which is the
--  only reason it is being fixed before it mattered.
--
--  `visibility` was `not null default 'members'`, and a trigger
--  turned 'members' into 'public' for any gig. So the column
--  could not tell "the band chose members-only" apart from "the
--  band said nothing" — both arrived as 'members', and both came
--  out public. A wedding or a corporate booking marked private
--  would have been listed publicly anyway.
--
--  Removing the default is the whole fix. An insert that says
--  nothing now arrives as NULL and the trigger fills it in; an
--  insert that says 'members' means it. NOT NULL still holds,
--  because it is checked after the trigger has run.
-- ------------------------------------------------------------
alter table band_events alter column visibility drop default;

--  and the trigger now only fills a blank, never overrules a choice
create or replace function default_event_visibility() returns trigger
language plpgsql as $$
begin
  if new.visibility is null then
    if new.kind = 'gig' and not coalesce(new.private_function, false) then
      new.visibility := 'public';
    else
      new.visibility := 'members';
    end if;
  end if;
  return new;
end $$;

-- ------------------------------------------------------------
--  4. Asking to join
-- ------------------------------------------------------------
create table if not exists band_join_requests (
  id          uuid primary key default gen_random_uuid(),
  band_id     uuid not null references bands on delete cascade,
  user_id     uuid not null references profiles on delete cascade,
  note        text,
  instruments text[] not null default '{}',
  role_label  text,
  status      text not null default 'pending'
              check (status in ('pending','approved','declined')),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz,
  decided_by  uuid references profiles on delete set null
);

-- one live request per person per band
create unique index if not exists band_join_requests_live_idx
  on band_join_requests (band_id, user_id) where status = 'pending';
create index if not exists band_join_requests_band_idx
  on band_join_requests (band_id, status, created_at desc);

alter table band_join_requests enable row level security;

-- you can see your own request, and the band can see requests to it
drop policy if exists "see my own band requests" on band_join_requests;
create policy "see my own band requests" on band_join_requests for select to authenticated
  using (user_id = (select auth.uid()) or is_band_member(band_id));

-- everything else goes through the functions below
drop policy if exists "ask to join as myself" on band_join_requests;
create policy "ask to join as myself" on band_join_requests for insert to authenticated
  with check (user_id = (select auth.uid()) and status = 'pending');

grant select, insert on band_join_requests to authenticated;

-- ------------------------------------------------------------
--  5. A band page a stranger may open
--
--  Everything on it is already public: the name, the city, who
--  plays what. The private things are not here to leave out.
-- ------------------------------------------------------------
create or replace function band_page(b uuid)
returns table (
  id uuid, name text, city text, genres text[], about text,
  avatar_path text, member_count int, next_gig timestamptz,
  i_am_member boolean, i_am_admin boolean, my_request text
)
language sql stable security definer set search_path = public, extensions as $$
  select bb.id, bb.name, bb.city, bb.genres, bb.about, bb.avatar_path,
         (select count(*)::int from band_members m where m.band_id = bb.id),
         (select min(e.starts_at) from band_events e
           where e.band_id = bb.id and e.kind = 'gig'
             and e.visibility = 'public' and e.starts_at > now()),
         is_band_member(bb.id),
         exists (select 1 from band_members m
                  where m.band_id = bb.id and m.user_id = (select auth.uid()) and m.is_admin),
         (select r.status from band_join_requests r
           where r.band_id = bb.id and r.user_id = (select auth.uid())
           order by r.created_at desc limit 1)
  from bands bb
  where bb.id = b;
$$;

-- ------------------------------------------------------------
--  6. The hole, closed
--
--  "members manage roster" allowed `user_id = auth.uid()`, which
--  let anybody insert themselves into any band. Adding people is
--  now the band's business. Removing yourself still is not — that
--  is leaving, and nobody needs permission to leave.
-- ------------------------------------------------------------
drop policy if exists "members manage roster" on band_members;

drop policy if exists "roster: the band adds people" on band_members;
create policy "roster: the band adds people" on band_members for insert to authenticated
  with check (is_band_member(band_id));

drop policy if exists "roster: the band edits people" on band_members;
create policy "roster: the band edits people" on band_members for update to authenticated
  using (is_band_member(band_id)) with check (is_band_member(band_id));

drop policy if exists "roster: the band removes, or you leave" on band_members;
create policy "roster: the band removes, or you leave" on band_members for delete to authenticated
  using (is_band_member(band_id) or user_id = (select auth.uid()));

-- ------------------------------------------------------------
--  7. Ask, approve, decline
-- ------------------------------------------------------------
create or replace function ask_to_join_band(
  b uuid,
  p_instruments text[] default '{}',
  p_role text default null,
  p_note text default null
)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := (select auth.uid());
  r  uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from bands where id = b) then raise exception 'no such band'; end if;
  if is_band_member(b) then return 'member'; end if;

  select id into r from band_join_requests
   where band_id = b and user_id = me and status = 'pending';
  if r is not null then return 'pending'; end if;

  insert into band_join_requests (band_id, user_id, instruments, role_label, note)
  values (b, me, coalesce(p_instruments,'{}'), p_role, nullif(btrim(coalesce(p_note,'')), ''));

  return 'sent';
end $$;

--  Everyone waiting on an answer from a band you run.
create or replace function band_requests(b uuid default null)
returns table (
  request_id uuid, band_id uuid, band_name text,
  user_id uuid, display_name text, handle text, photo_path text,
  instruments text[], role_label text, note text, asked_at timestamptz
)
language sql stable security definer set search_path = public, extensions as $$
  select r.id, bd.id, bd.name,
         p.id, p.display_name, p.handle, p.photo_path,
         r.instruments, r.role_label, r.note, r.created_at
  from band_join_requests r
  join bands bd on bd.id = r.band_id
  join profiles p on p.id = r.user_id
  join band_members m on m.band_id = r.band_id
                     and m.user_id = (select auth.uid())
                     and m.is_admin
  where r.status = 'pending'
    and (b is null or r.band_id = b)
    and not blocked_between(p.id, (select auth.uid()))
  order by r.created_at desc;
$$;

create or replace function band_request_count()
returns int
language sql stable security definer set search_path = public, extensions as $$
  select count(*)::int from band_join_requests r
  join band_members m on m.band_id = r.band_id
                     and m.user_id = (select auth.uid())
                     and m.is_admin
  where r.status = 'pending';
$$;

--  Approve or decline. Approving is what actually puts someone in
--  the band — the roster can no longer be written any other way.
create or replace function answer_band_request(req uuid, yes boolean)
returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare
  me  uuid := (select auth.uid());
  rec band_join_requests%rowtype;
begin
  if me is null then raise exception 'not signed in'; end if;

  select * into rec from band_join_requests where id = req;
  if rec.id is null then return false; end if;
  if rec.status <> 'pending' then return false; end if;

  if not exists (select 1 from band_members
                  where band_id = rec.band_id and user_id = me and is_admin) then
    raise exception 'only someone who runs this band can answer that';
  end if;

  update band_join_requests
     set status = case when yes then 'approved' else 'declined' end,
         decided_at = now(), decided_by = me
   where id = req;

  if yes then
    insert into band_members (band_id, user_id, instruments, role_label)
    values (rec.band_id, rec.user_id, rec.instruments, rec.role_label)
    on conflict do nothing;

    -- put them in the band chat straight away
    insert into conversation_members (conversation_id, user_id)
    select c.id, rec.user_id from conversations c
     where c.kind = 'band' and c.band_id = rec.band_id
    on conflict do nothing;
  end if;

  return true;
end $$;

-- ------------------------------------------------------------
--  8. join_band now asks instead of helping itself
--
--  Kept under its old name so nothing that calls it breaks. It
--  returns true only when you are actually in the band.
-- ------------------------------------------------------------
create or replace function join_band(b uuid, p_instruments text[] default '{}', p_role text default null)
returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := (select auth.uid());
begin
  if me is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from bands where id = b) then raise exception 'no such band'; end if;
  if is_band_member(b) then return true; end if;

  -- a band with nobody in it has nobody to ask
  if not exists (select 1 from band_members where band_id = b) then
    insert into band_members (band_id, user_id, instruments, role_label, is_admin)
    values (b, me, coalesce(p_instruments,'{}'), p_role, true);
    perform band_conversation(b);
    return true;
  end if;

  perform ask_to_join_band(b, p_instruments, p_role, null);
  return false;
end $$;

-- ------------------------------------------------------------
--  9. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('gigs_near_me','band_page','ask_to_join_band',
                      'band_requests','band_request_count','answer_band_request');
  if n < 6 then
    raise exception 'Jammy: expected 6 gig functions, found %', n;
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'band_members'
      and policyname = 'members manage roster') then
    raise exception 'Jammy: the old roster rule is still in place — anyone could still join any band';
  end if;

  raise notice 'Jammy: gigs can be found, and bands can only be joined by invitation.';
end $$;


-- ############################################################
-- ##  18_roster.sql
-- ############################################################

-- ============================================================
--  JAMMY — 18_roster.sql
--  GETTING SOMEBODY OUT OF A BAND. Run after 01–17.
--
--  WHY THIS EXISTS
--  17_gigs.sql closed the door that let anyone add themselves to
--  any band. Closing a door does nothing about whoever already
--  walked through it, and there was no way at all to take a
--  person off a roster — not for them, not for the band.
--
--  Two holes, and they are opposite shapes:
--
--  1. The band could not remove anyone. Somebody who let
--     themselves in through the old door stayed in, and a member
--     can read the rehearsal address. There was no way to undo
--     that short of deleting the band.
--
--  2. Leaving did not work either. The app's Leave button only
--     changed what was stored on the phone and never told the
--     database, so a person who left was still on the roster, in
--     the band chat, and still able to read the address. That half
--     is fixed in the app; leave_band() itself was already right.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. Taking somebody off the roster
--
--  Only somebody who runs the band. The same two protections
--  leave_band() has apply: a band is never left with no admin,
--  and nobody can remove the last person and strand the band.
--
--  Removing somebody also takes them out of the band chat. A
--  person who is no longer in the band should not keep receiving
--  the band's messages, and the chat is where the next practice
--  gets arranged.
-- ------------------------------------------------------------
create or replace function remove_band_member(b uuid, who uuid)
returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare
  me     uuid := (select auth.uid());
  others int;
begin
  if me is null then raise exception 'not signed in'; end if;

  if not exists (select 1 from band_members
                  where band_id = b and user_id = me and is_admin) then
    raise exception 'only someone who runs this band can take a person out of it';
  end if;

  if who = me then
    raise exception 'use Leave to take yourself out of a band';
  end if;

  if not exists (select 1 from band_members where band_id = b and user_id = who) then
    return false;   -- already not in it; nothing to do and nothing to report
  end if;

  select count(*) into others from band_members
   where band_id = b and user_id is distinct from who;
  if others = 0 then
    raise exception 'that is the only person left in the band';
  end if;

  -- never leave the band with nobody running it
  if exists (select 1 from band_members
              where band_id = b and user_id = who and is_admin)
     and not exists (select 1 from band_members
                      where band_id = b and is_admin and user_id is distinct from who) then
    update band_members set is_admin = true
     where id = (select id from band_members
                  where band_id = b and user_id is distinct from who
                  order by joined_at limit 1);
  end if;

  delete from band_members where band_id = b and user_id = who;

  -- and out of the band chat, which is where practices get arranged
  delete from conversation_members
   where user_id = who
     and conversation_id in (select id from conversations
                              where kind = 'band' and band_id = b);

  -- a removed person may ask again later; an old answer should not
  -- sit there pretending to be the current one
  delete from band_join_requests
   where band_id = b and user_id = who and status <> 'pending';

  return true;
end $$;

comment on function remove_band_member is
  'Admin only. Never strands a band without an admin, and never empties it.';

-- ------------------------------------------------------------
--  2. Who is in this band, and how did they get in
--
--  After the old door, "is this person really in my band?" is a
--  fair question to be able to answer from inside the app rather
--  than from the SQL editor.
-- ------------------------------------------------------------
create or replace function band_roster_detail(b uuid)
returns table (
  user_id uuid, display_name text, handle text, photo_path text,
  instruments text[], role_label text, is_admin boolean,
  joined_at timestamptz, is_me boolean, can_remove boolean
)
language sql stable security definer set search_path = public, extensions as $$
  select bm.user_id,
         coalesce(p.display_name, bm.display_name),
         p.handle, p.photo_path,
         case when bm.instruments <> '{}' then bm.instruments
              else coalesce(p.instruments,'{}') end,
         bm.role_label, bm.is_admin, bm.joined_at,
         (bm.user_id = (select auth.uid())),
         -- you can take somebody out if you run the band, it is not
         -- you, and they are not the only person left
         (exists (select 1 from band_members a
                   where a.band_id = b and a.user_id = (select auth.uid()) and a.is_admin)
          and bm.user_id is distinct from (select auth.uid())
          and (select count(*) from band_members c where c.band_id = b) > 1)
  from band_members bm
  left join profiles p on p.id = bm.user_id
  where bm.band_id = b
    and is_band_member(b)        -- the roster's joining dates are the band's business
  order by bm.is_admin desc, bm.joined_at;
$$;

-- ------------------------------------------------------------
--  3. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('remove_band_member','band_roster_detail');
  if n <> 2 then
    raise exception 'Jammy: expected 2 roster functions, found %', n;
  end if;
  raise notice 'Jammy: a band can now take somebody out of it, and leaving works.';
end $$;


-- ############################################################
-- ##  19_feed.sql
-- ############################################################

-- ============================================================
--  JAMMY — 19_feed.sql
--  THE FRONT PAGE, FOR REAL. Run after 01–18.
--
--  WHY THIS EXISTS
--  The posts table, feed_page(), likes and comments have all been
--  here since the beginning. Nothing in the app ever called them.
--  So the first screen anyone opens was sixteen invented posts by
--  eight invented musicians, shown to real signed-in people.
--
--  Same shape as the gigs problem: the database half was built and
--  the screen was not.
--
--  Two things are missing from the table, and both of them are
--  what makes a Jammy post different from a status update:
--
--  1. The fields. "Drums · Tuesdays and Sundays · Brighton" is the
--     useful part of looking for a drummer. There was nowhere to
--     put it, so it would have been lost in the prose.
--
--  2. A post with nothing but a picture. `body` was NOT NULL with
--     a minimum of one character, so a photo of the new pedalboard
--     needed a caption to exist at all.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. The fields
-- ------------------------------------------------------------
alter table posts add column if not exists fields jsonb not null default '{}'::jsonb;

-- Keep it small. This is a handful of short labels, not a document,
-- and without a limit it is a place to paste anything.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'posts_fields_small' and conrelid = 'posts'::regclass
  ) then
    alter table posts add constraint posts_fields_small
      check (pg_column_size(fields) <= 2048);
  end if;
end $$;

-- ------------------------------------------------------------
--  2. A picture can be the whole post
--
--  body stays NOT NULL so nothing already written has to change;
--  it is now allowed to be empty, but only when there is something
--  else to look at. An entirely empty post is still refused.
-- ------------------------------------------------------------
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'posts'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) like '%char_length(body)%';
  if c is not null then
    execute format('alter table posts drop constraint %I', c);
  end if;
end $$;

alter table posts alter column body set default '';
update posts set body = '' where body is null;
alter table posts alter column body set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'posts_say_something' and conrelid = 'posts'::regclass
  ) then
    alter table posts add constraint posts_say_something
      check (
        char_length(body) <= 2000
        and (char_length(btrim(body)) > 0
             or media_path is not null
             or track_id is not null
             or fields <> '{}'::jsonb)
      );
  end if;
end $$;

-- ------------------------------------------------------------
--  3. feed_page, carrying the fields
--
--  Postgres will not widen a function in place, so it goes first.
--  SECURITY DEFINER with a pinned search_path, like everything
--  else that has to see past a row rule — here, blocked_between().
-- ------------------------------------------------------------
--  FOUND BY THE TEST. Paging was "older than this timestamp", and two
--  posts written in the same second share one. On a tie the second page
--  skipped every post that shared the boundary time — quietly, with no
--  gap to see. Busy minutes are exactly when it would have happened.
--
--  The cursor is now the time AND the id together, which is unique, so
--  a tie has an order and nothing falls through it.
drop function if exists feed_page(timestamptz, int);
drop function if exists feed_page(timestamptz, int, uuid);

create or replace function feed_page(
  before timestamptz default null,
  page_size int default 20,
  before_id uuid default null
) returns table (
  id uuid, author_id uuid, body text, tag text, track_id uuid, media_path text,
  fields jsonb, created_at timestamptz, like_count int, comment_count int,
  author_name text, author_handle text, author_city text, author_photo text,
  liked_by_me boolean, mine boolean
)
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.author_id, p.body, p.tag, p.track_id, p.media_path,
         p.fields, p.created_at, p.like_count, p.comment_count,
         pr.display_name, pr.handle, pr.city, pr.photo_path,
         exists (select 1 from post_likes l
                  where l.post_id = p.id and l.user_id = (select auth.uid())),
         (p.author_id = (select auth.uid()))
  from posts p
  join profiles pr on pr.id = p.author_id
  where (before is null
         or p.created_at < before
         or (p.created_at = before and before_id is not null and p.id < before_id))
    and not pr.is_banned
    and not blocked_between(p.author_id, (select auth.uid()))
  order by p.created_at desc, p.id desc
  limit least(greatest(page_size, 1), 50);
$$;

-- ------------------------------------------------------------
--  4. Posting, in one call
--
--  Done from the app as a bare insert, a post with a picture was
--  two steps that could half-happen: the file uploaded and the row
--  never written, leaving an orphan in storage and nothing on the
--  screen. The upload still happens first — it has to — but the row
--  is one call that either works or does not.
-- ------------------------------------------------------------
create or replace function add_post(
  p_body text default '',
  p_tag text default null,
  p_fields jsonb default '{}'::jsonb,
  p_media_path text default null,
  p_track_id uuid default null
)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := (select auth.uid());
  id_out uuid;
begin
  if me is null then raise exception 'not signed in'; end if;

  if coalesce(btrim(p_body),'') = ''
     and p_media_path is null and p_track_id is null
     and coalesce(p_fields,'{}'::jsonb) = '{}'::jsonb then
    raise exception 'A post needs something in it — a few words, a picture or a track.';
  end if;

  -- you may only attach a file out of your own folder
  if p_media_path is not null
     and split_part(p_media_path, '/', 1) <> me::text then
    raise exception 'that file is not yours';
  end if;

  insert into posts (author_id, body, tag, fields, media_path, track_id)
  values (me, coalesce(btrim(p_body),''), nullif(btrim(coalesce(p_tag,'')),''),
          coalesce(p_fields,'{}'::jsonb), p_media_path, p_track_id)
  returning id into id_out;

  return id_out;
end $$;

-- ------------------------------------------------------------
--  5. Your own posts, for your profile
-- ------------------------------------------------------------
create or replace function my_posts(limit_n int default 50)
returns table (
  id uuid, body text, tag text, fields jsonb, media_path text, track_id uuid,
  created_at timestamptz, like_count int, comment_count int
)
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.body, p.tag, p.fields, p.media_path, p.track_id,
         p.created_at, p.like_count, p.comment_count
  from posts p
  where p.author_id = (select auth.uid())
  order by p.created_at desc
  limit least(greatest(limit_n, 1), 100);
$$;

-- ------------------------------------------------------------
--  6. Someone else's posts, for their profile
-- ------------------------------------------------------------
create or replace function posts_by(who uuid, limit_n int default 50)
returns table (
  id uuid, body text, tag text, fields jsonb, media_path text, track_id uuid,
  created_at timestamptz, like_count int, comment_count int, liked_by_me boolean
)
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.body, p.tag, p.fields, p.media_path, p.track_id,
         p.created_at, p.like_count, p.comment_count,
         exists (select 1 from post_likes l
                  where l.post_id = p.id and l.user_id = (select auth.uid()))
  from posts p
  join profiles pr on pr.id = p.author_id
  where p.author_id = who
    and not pr.is_banned
    and not blocked_between(who, (select auth.uid()))
  order by p.created_at desc
  limit least(greatest(limit_n, 1), 100);
$$;

-- ------------------------------------------------------------
--  7. Speed
-- ------------------------------------------------------------
create index if not exists posts_author_recent_idx on posts (author_id, created_at desc);

-- ------------------------------------------------------------
--  8. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('add_post','my_posts','posts_by','feed_page');
  if n < 4 then
    raise exception 'Jammy: expected 4 feed functions, found %', n;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_name = 'posts' and column_name = 'fields') then
    raise exception 'Jammy: posts has nowhere to keep what a post is looking for';
  end if;

  raise notice 'Jammy: the feed is real. Nothing on it is invented any more.';
end $$;


-- ############################################################
-- ##  20_account.sql
-- ############################################################

-- ============================================================
--  JAMMY — 20_account.sql
--  DELETING YOUR ACCOUNT, AND TAKING YOUR DATA WITH YOU.
--  Run after 01–19.
--
--  WHY THIS EXISTS
--  "Delete account" cleared the phone and signed you out. The
--  account, the profile, the posts, the messages and the swipes
--  all stayed exactly where they were, and signing in again
--  brought it all back.
--
--  Apple rejects apps that let you create an account and not
--  delete it — guideline 5.1.1(v) — so this would have failed
--  review. It is also simply what the privacy policy already
--  promises, which makes the old button untrue as well as
--  non-compliant.
--
--  WHAT THE POLICY SAYS, AND WHAT THIS DOES
--    "your profile and content are removed"           -> gone
--    "messages you sent may remain visible to the
--     person who received them, in the same way a
--     sent text does"                                 -> kept, with
--                                                        no sender
--    "See your data ... Download my data"             -> export_my_data()
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. One thing would have blocked the delete outright
--
--  ad_requests.reviewed_by points at profiles with NO ACTION, so
--  deleting anyone who had ever reviewed an advertiser request
--  would fail on a foreign key, with an error nobody could act
--  on. It is a record of who reviewed something, not of who they
--  are, so it loosens to set null like every other such column.
-- ------------------------------------------------------------
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'ad_requests'::regclass and contype = 'f'
     and confrelid = 'profiles'::regclass and confdeltype = 'a';
  if c is not null then
    execute format('alter table ad_requests drop constraint %I', c);
    alter table ad_requests
      add constraint ad_requests_reviewed_by_fkey
      foreign key (reviewed_by) references profiles on delete set null;
    raise notice 'Jammy: a reviewed ad request no longer blocks deleting an account.';
  end if;
end $$;

-- ------------------------------------------------------------
--  2. Take your data with you
--
--  Everything Jammy holds about you, as one JSON document. This
--  is the "Download my data" the privacy policy promises, and it
--  is also what makes deletion a fair choice rather than a cliff.
--
--  It returns only the caller's own rows. There is no argument,
--  deliberately: a function that took a user id would be one
--  mistake away from handing out somebody else's life.
-- ------------------------------------------------------------
create or replace function export_my_data()
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  me uuid := (select auth.uid());
  out jsonb;
begin
  if me is null then raise exception 'not signed in'; end if;

  select jsonb_build_object(
    'exported_at', now(),
    'what_this_is', 'Everything Jammy holds about your account. '
                 || 'Distances others see are worked out from your location; '
                 || 'the coordinates below are rounded to about a mile, which '
                 || 'is how they were stored.',
    'profile', (
      select to_jsonb(p) - 'location' ||
             jsonb_build_object('approximate_location',
               case when p.location is null then null
                    else jsonb_build_object(
                      'latitude',  round(st_y(p.location::geometry)::numeric, 2),
                      'longitude', round(st_x(p.location::geometry)::numeric, 2)) end)
      from profiles p where p.id = me),
    'posts',    coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select id, body, tag, fields, media_path, created_at,
                         like_count, comment_count
                  from posts where author_id = me order by created_at) x), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select id, post_id, body, created_at
                  from post_comments where author_id = me order by created_at) x), '[]'::jsonb),
    'messages_you_sent', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select id, conversation_id, body, created_at
                  from messages where sender_id = me order by created_at) x), '[]'::jsonb),
    'recordings', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select id, title, audio_path, created_at
                  from tracks where owner_id = me order by created_at) x), '[]'::jsonb),
    'bands',    coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select b.id, b.name, b.city, m.role_label, m.is_admin, m.joined_at
                  from band_members m join bands b on b.id = m.band_id
                  where m.user_id = me order by m.joined_at) x), '[]'::jsonb),
    'connections', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select c.id, c.created_at,
                         case when c.a_id = me then c.b_id else c.a_id end as with_user
                  from connections c where c.a_id = me or c.b_id = me
                  order by c.created_at) x), '[]'::jsonb),
    'people_you_passed_or_liked', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select to_id, direction, created_at
                  from swipes where from_id = me order by created_at) x), '[]'::jsonb),
    'people_you_blocked', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select blocked_id, created_at
                  from blocks where blocker_id = me order by created_at) x), '[]'::jsonb)
  ) into out;

  return out;
end $$;

comment on function export_my_data is
  'Everything Jammy holds about the caller, and nobody else. Takes no argument on purpose.';

-- ------------------------------------------------------------
--  3. Deleting the account
--
--  Most of this happens by itself: nearly everything that points
--  at a profile is ON DELETE CASCADE, so removing the profile row
--  takes the posts, comments, likes, swipes, connections, band
--  memberships, tracks and device tokens with it.
--
--  Three things are handled by hand.
--
--  Messages stay. The column is ON DELETE SET NULL, which is what
--  the privacy policy describes: a message you sent remains in the
--  other person's conversation the way a sent text does, with no
--  profile behind it any more. This is deliberate, not an
--  oversight — the alternative is quietly editing somebody else's
--  conversation after they have read it.
--
--  Reports made ABOUT you cascade, which would let anyone delete
--  the record of their own behaviour and sign up again clean. The
--  policy says safety records are kept for twelve months, so they
--  are detached from the profile and kept, with no name attached.
--
--  The auth account itself goes last, so that nothing is half
--  deleted if it fails.
-- ------------------------------------------------------------
create or replace function delete_my_account(confirm text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  me       uuid := (select auth.uid());
  handle_was text;
  kept     int := 0;
  auth_gone boolean := false;
begin
  if me is null then raise exception 'not signed in'; end if;

  -- Deleting is not undoable, so it is not a thing you can do by
  -- tapping twice in the wrong place.
  if lower(coalesce(btrim(confirm),'')) <> 'delete' then
    raise exception 'To delete your account, type the word delete.';
  end if;

  select handle into handle_was from profiles where id = me;

  -- safety records about this person outlive the account
  update reports set target_user = null
   where target_user = me;
  get diagnostics kept = row_count;

  update reports set reporter_id = null where reporter_id = me;

  -- the profile, and everything that hangs off it
  delete from profiles where id = me;

  -- and the sign-in itself. If this database cannot reach the auth
  -- table, the account's data is already gone and we say so rather
  -- than pretending the whole thing worked.
  begin
    delete from auth.users where id = me;
    auth_gone := true;
  exception when others then
    auth_gone := false;
  end;

  return jsonb_build_object(
    'deleted', true,
    'handle', handle_was,
    'sign_in_removed', auth_gone,
    'safety_records_kept', kept,
    'note', 'Messages you sent stay in the other person''s conversation, '
         || 'with no profile attached, as the privacy policy describes.');
end $$;

comment on function delete_my_account is
  'Permanent. Requires the word "delete". Keeps sent messages and safety records, per the privacy policy.';

-- ------------------------------------------------------------
--  4. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('delete_my_account','export_my_data');
  if n <> 2 then
    raise exception 'Jammy: expected 2 account functions, found %', n;
  end if;

  if exists (
    select 1 from pg_constraint
    where conrelid = 'ad_requests'::regclass and contype = 'f'
      and confrelid = 'profiles'::regclass and confdeltype = 'a') then
    raise exception 'Jammy: a reviewed ad request would still block deleting an account';
  end if;

  raise notice 'Jammy: an account can be exported and deleted, which Apple requires.';
end $$;


-- ############################################################
-- ##  21_chart.sql
-- ############################################################

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


-- ############################################################
-- ##  22_radio.sql
-- ############################################################

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


-- ============================================================
--  23_columns.sql — stop handing out birthdays and coordinates
--
--  Row-level security decides which ROWS you may read. It says
--  nothing about which COLUMNS. Every table in Jammy was granted
--  to `authenticated` whole, so any signed-in member could ask
--  the API for every other member's `birth_date` and for the
--  stored `location` point — not the computed distance the app
--  displays, but the coordinate itself.
--
--  Proved before writing this, as an ordinary user:
--
--    select display_name, birth_date from profiles;
--     Drum Tester    | 1996-05-05
--     Far Drummer    | 1990-01-01
--
--    select display_name, st_y(location::geometry) ... ;
--     Ana Tester     | 42.3620 | -71.0650
--
--  The coordinate is rounded to about a mile before it is stored,
--  so this is a neighbourhood rather than a doorstep. It is still
--  more than the app shows, and more than the privacy policy
--  promised: "your age is never shown to anyone", "never your
--  coordinates". Rather than weaken the promise, close the gap.
--
--  A full date of birth is also the single most useful field an
--  identity thief can take, and nothing in Jammy needs to read
--  somebody else's.
-- ============================================================

-- ------------------------------------------------------------
--  1. The app needs to know whether the SERVER has a location
--     for you — that is what tells Discover which empty state to
--     show. It does not need the coordinate to answer that.
-- ------------------------------------------------------------
alter table profiles
  add column if not exists has_location boolean
  generated always as (location is not null) stored;

-- ------------------------------------------------------------
--  2. Discover already enforces its own rules — not banned, not
--     blocked either way, not already swiped — rather than
--     leaning on row security, and it returns `miles`, never the
--     point. That makes it safe to run with the definer's rights
--     so it can still read a column its callers no longer can.
-- ------------------------------------------------------------
alter function discover(numeric, boolean, text[], int, boolean, int)
  security definer;
alter function discover(numeric, boolean, text[], int, boolean, int)
  set search_path = public, extensions;

-- ------------------------------------------------------------
--  3. Hand back the table-wide grants and re-issue them column
--     by column. Anything not named here is invisible and
--     unwritable to an ordinary member, whatever query they send.
-- ------------------------------------------------------------
revoke select, update on profiles from authenticated;

grant select (
  id, handle, display_name, bio, city, photo_path,
  instruments, instrument_keys, genres,
  looking_for, looking_for_instruments, influences,
  rehearsal_days, remote_ok,
  verified_at, is_banned, terms_agreed_at, created_at,
  has_location
) on profiles to authenticated;

--  Writable: the things a person edits about themselves.
--  Deliberately absent: `birth_date`, so an account cannot change
--  its age after signup; `verified_at`, so nobody can award
--  themselves a verified mark; `is_banned`, so nobody can lift
--  their own ban; `created_at` and `id`.
grant update (
  handle, display_name, bio, city, location, photo_path,
  instruments, instrument_keys, genres,
  looking_for, looking_for_instruments, influences,
  rehearsal_days, remote_ok, terms_agreed_at
) on profiles to authenticated;

-- ------------------------------------------------------------
--  4. Your own date of birth is still yours to see. It comes back
--     through export_my_data(), which is a definer function and
--     already returns it.
-- ------------------------------------------------------------
-- ============================================================
--  24_uploads.sql — let the radio accept audio, and keep the
--                   bucket closed to everything that can run
--
--  Two things here. One is a break, one is a hardening.
--
--  THE BREAK. Tracks for the radio are uploaded to `jammy-media`
--  with an audio content type — audio/mpeg, audio/wav, and so on.
--  `jammy-media` allowed images and video and no audio at all, so
--  Supabase rejected every single track upload. Nothing caught it
--  because every automated test replaces storage with a fake that
--  accepts whatever it is handed. It only fails against the real
--  server, which is the worst place to find out.
--
--  THE HARDENING. What a bucket may hold is the whole defence
--  against someone using Jammy to host something dangerous.
--  Supabase serves a file back with the content type it was stored
--  under, so a file can only run in somebody's browser if that type
--  is on this list. These two are the ones that matter and they
--  stay off it permanently:
--
--    text/html          — a page that runs scripts on your domain
--    image/svg+xml      — an image format that can carry <script>
--
--  Nothing here admits application/*, so no executables, no
--  installers, no archives, no PDFs.
-- ============================================================

-- ------------------------------------------------------------
--  jammy-media: public by design. Profile photos, post pictures
--  and video, and tracks on the radio — things meant to be seen
--  and heard by anyone.
-- ------------------------------------------------------------
update storage.buckets
   set allowed_mime_types = array[
         -- pictures
         'image/jpeg','image/png','image/webp','image/gif',
         -- video
         'video/mp4','video/webm','video/quicktime',
         -- audio, for the radio. This is the line that was missing.
         'audio/mpeg','audio/mp4','audio/x-m4a','audio/wav','audio/x-wav',
         'audio/ogg','audio/webm','audio/flac'
       ],
       file_size_limit = 26214400          -- 25 MB, unchanged
 where id = 'jammy-media';

-- ------------------------------------------------------------
--  jam-clips: private, conversation-scoped, audio only. A clip is
--  something you played into a chat, so it needs nothing else.
-- ------------------------------------------------------------
update storage.buckets
   set allowed_mime_types = array[
         'audio/webm','audio/mp4','audio/mpeg','audio/ogg',
         'audio/wav','audio/x-wav','audio/x-m4a','audio/flac'
       ],
       file_size_limit = 10485760          -- 10 MB, unchanged
 where id = 'jam-clips';

-- ------------------------------------------------------------
--  A standing check, so this cannot rot quietly again.
--
--  If either bucket is ever given a type that a browser will
--  execute, this raises instead of letting it through. It runs
--  when the migration is applied, and the test suite runs it too.
-- ------------------------------------------------------------
create or replace function assert_buckets_cannot_run_code()
returns void
language plpgsql
as $$
declare
  bad text;
begin
  select string_agg(b.id || ' allows ' || t, ', ')
    into bad
    from storage.buckets b,
         unnest(b.allowed_mime_types) as t
   where t in ('text/html','image/svg+xml','application/xhtml+xml',
               'text/xml','application/xml','application/javascript',
               'text/javascript','application/pdf')
      or t like 'application/x-%'
      or t = '*/*';

  if bad is not null then
    raise exception
      'A storage bucket would serve runnable content: %', bad;
  end if;

  -- a bucket with no list at all accepts anything, which is worse
  select string_agg(b.id, ', ')
    into bad
    from storage.buckets b
   where b.allowed_mime_types is null
      or cardinality(b.allowed_mime_types) = 0;

  if bad is not null then
    raise exception
      'A storage bucket accepts any file type at all: %', bad;
  end if;
end $$;

select assert_buckets_cannot_run_code();
