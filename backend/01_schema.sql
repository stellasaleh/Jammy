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
