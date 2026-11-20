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
