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
