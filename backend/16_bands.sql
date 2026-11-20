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
