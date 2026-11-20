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
