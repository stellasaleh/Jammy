-- ============================================================
--  JAMMY — gigs.test.sql
--  Can a stranger find the gig, and only the gig?
--
--  Run as app_user (a plain signed-in account), never as the
--  database owner — the owner walks through every rule unchecked,
--  which is how the last three bugs got past me.
--
--    psql -d jammy -U app_user -f test/gigs.test.sql
-- ============================================================

\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on

create temp table t (n int generated always as identity, name text, ok boolean, detail text);

create function pg_temp.chk(nm text, cond boolean, detail text default '') returns void
language plpgsql as $$
begin insert into t (name, ok, detail) values (nm, coalesce(cond,false), detail); end $$;

-- who is signed in
create function pg_temp.be(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', u::text, false); end $$;

-- ------------------------------------------------------------
--  Cast. Stella starts a band. Hasan is a stranger in the same
--  city. Priya is three states away.
-- ------------------------------------------------------------
do $$
declare s uuid; v uuid; h uuid; pr uuid;
begin
  s := gen_random_uuid(); v := gen_random_uuid();
  h := gen_random_uuid(); pr := gen_random_uuid();
  perform set_config('test.stella', s::text, false);
  perform set_config('test.vik',    v::text, false);
  perform set_config('test.hasan',  h::text, false);
  perform set_config('test.priya', pr::text, false);

  -- Boston, within a mile or two of each other
  insert into auth.users (id) values (s),(v),(h),(pr);

  perform pg_temp.be(s);
  insert into profiles (id, display_name, handle, city, location, instruments, genres, birth_date)
  values (s,'Stella','stella_'||substr(s::text,1,8),'Boston',
          st_setsrid(st_makepoint(-71.0589, 42.3601),4326)::geography,
          '{Guitar}','{Indie}','1999-04-02');

  perform pg_temp.be(v);
  insert into profiles (id, display_name, handle, city, location, instruments, genres, birth_date)
  values (v,'Vik','vik_'||substr(v::text,1,8),'Boston',
          st_setsrid(st_makepoint(-71.0620, 42.3580),4326)::geography,
          '{Drums}','{Indie}','1999-04-02');

  perform pg_temp.be(h);
  insert into profiles (id, display_name, handle, city, location, instruments, genres, birth_date)
  values (h,'Hasan','hasan_'||substr(h::text,1,8),'Boston',
          st_setsrid(st_makepoint(-71.1097, 42.3736),4326)::geography,   -- Allston, ~3 mi
          '{Bass}','{Indie}','1999-04-02');

  perform pg_temp.be(pr);
  insert into profiles (id, display_name, handle, city, location, instruments, genres, birth_date)
  values (pr,'Priya','priya_'||substr(pr::text,1,8),'Chicago',
          st_setsrid(st_makepoint(-87.6298, 41.8781),4326)::geography,
          '{Keys}','{Jazz}','1999-04-02');
end $$;

-- ------------------------------------------------------------
--  Stella starts a band, books a practice and a gig
-- ------------------------------------------------------------
do $$
declare b uuid; gig uuid; prac uuid;
begin
  perform pg_temp.be(current_setting('test.stella')::uuid);
  b := create_band('The Fog Signals','Boston','{Indie,Post-punk}','We practise Tuesdays','{Guitar}','Guitar');
  perform set_config('test.band', b::text, false);

  perform pg_temp.chk('band gets its founder''s coordinates',
    (select location is not null from bands where id = b));

  prac := add_band_event(b,'practice', now() + interval '2 days',
                         'Stella''s place','14 Dane St, Somerville','bring the DI box');
  gig  := add_band_event(b,'gig', now() + interval '9 days',
                         'The Middle East','472 Mass Ave','doors at 8');
  perform set_config('test.gig',  gig::text, false);
  perform set_config('test.prac', prac::text, false);
end $$;

-- ------------------------------------------------------------
--  1. THE QUESTION: where would Hasan see it?
-- ------------------------------------------------------------
do $$
declare n int; m numeric;
begin
  perform pg_temp.be(current_setting('test.hasan')::uuid);

  select count(*) into n from gigs_near_me(25, 30);
  perform pg_temp.chk('a stranger nearby finds the gig', n = 1, n || ' found');

  select miles into m from gigs_near_me(25, 30) limit 1;
  perform pg_temp.chk('and it tells him how far', m is not null and m between 1 and 8, coalesce(m::text,'null') || ' mi');

  select count(*) into n from gigs_near_me(25, 30) where i_am_member;
  perform pg_temp.chk('and does not claim he is in the band', n = 0);
end $$;

-- ------------------------------------------------------------
--  2. The practice stays where it belongs
-- ------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.hasan')::uuid);

  select count(*) into n from gigs_near_me(0, 365);
  perform pg_temp.chk('no practice ever reaches the gig list', n = 1, n || ' events');

  select count(*) into n from band_schedule(current_setting('test.band')::uuid);
  perform pg_temp.chk('the band page shows him one date, not two', n = 1, n || ' dates');

  select count(*) into n from band_schedule(current_setting('test.band')::uuid)
   where kind = 'practice';
  perform pg_temp.chk('and the practice is not one of them', n = 0);

  select count(*) into n from band_schedule(current_setting('test.band')::uuid)
   where address is not null or note is not null;
  perform pg_temp.chk('no address and no note for a non-member', n = 0);
end $$;

-- ------------------------------------------------------------
--  3. The band page opens for a stranger
-- ------------------------------------------------------------
do $$
declare r record;
begin
  perform pg_temp.be(current_setting('test.hasan')::uuid);
  select * into r from band_page(current_setting('test.band')::uuid);

  perform pg_temp.chk('a stranger can open the band page', r.name = 'The Fog Signals', coalesce(r.name,'(nothing)'));
  perform pg_temp.chk('it knows he is not in it', r.i_am_member = false);
  perform pg_temp.chk('it knows he has not asked yet', r.my_request is null);
  perform pg_temp.chk('it shows the next gig', r.next_gig is not null);
  perform pg_temp.chk('it counts the members', r.member_count = 1, r.member_count::text);
end $$;

-- ------------------------------------------------------------
--  4. Far away is far away
-- ------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.priya')::uuid);

  select count(*) into n from gigs_near_me(25, 30);
  perform pg_temp.chk('Chicago does not see a Boston gig at 25 miles', n = 0, n || ' found');

  select count(*) into n from gigs_near_me(0, 30);
  perform pg_temp.chk('but "anywhere" means anywhere', n = 1, n || ' found');
end $$;

-- ------------------------------------------------------------
--  5. THE HOLE: he must not be able to let himself in
--
--  This is the test that would have failed before 17_gigs.sql.
-- ------------------------------------------------------------
do $$
declare n int; failed boolean := false;
begin
  perform pg_temp.be(current_setting('test.hasan')::uuid);
  begin
    insert into band_members (band_id, user_id, instruments)
    values (current_setting('test.band')::uuid, current_setting('test.hasan')::uuid, '{Bass}');
  exception when others then failed := true;
  end;

  select count(*) into n from band_members
   where band_id = current_setting('test.band')::uuid
     and user_id = current_setting('test.hasan')::uuid;
  perform pg_temp.chk('a stranger cannot add himself to the roster', failed and n = 0,
              case when n > 0 then 'HE IS IN THE BAND' else 'refused' end);

  -- and therefore still cannot see the rehearsal address
  select count(*) into n from band_schedule(current_setting('test.band')::uuid)
   where address is not null;
  perform pg_temp.chk('so the rehearsal address stays private', n = 0);
end $$;

-- ------------------------------------------------------------
--  6. He asks instead
-- ------------------------------------------------------------
do $$
declare s text; n int; r record;
begin
  perform pg_temp.be(current_setting('test.hasan')::uuid);

  s := ask_to_join_band(current_setting('test.band')::uuid, '{Bass}', 'Bass', 'saw you at the Middle East');
  perform pg_temp.chk('he can ask to join', s = 'sent', s);

  s := ask_to_join_band(current_setting('test.band')::uuid, '{Bass}', 'Bass', 'again');
  perform pg_temp.chk('asking twice does not queue twice', s = 'pending', s);

  select * into r from band_page(current_setting('test.band')::uuid);
  perform pg_temp.chk('his band page now says it is pending', r.my_request = 'pending', coalesce(r.my_request,'null'));

  select count(*) into n from band_members
   where band_id = current_setting('test.band')::uuid
     and user_id = current_setting('test.hasan')::uuid;
  perform pg_temp.chk('asking does not put him in the band', n = 0);
end $$;

-- ------------------------------------------------------------
--  7. Only the band can answer, and only approving admits anyone
-- ------------------------------------------------------------
do $$
declare req uuid; n int; refused boolean := false;
begin
  -- Priya, a stranger, tries to approve it
  perform pg_temp.be(current_setting('test.stella')::uuid);
  select request_id into req from band_requests() limit 1;
  -- never let a missing request abort the run: a nil id makes the
  -- checks below fail and say so, instead of throwing
  perform set_config('test.req', coalesce(req, '00000000-0000-0000-0000-000000000000'::uuid)::text, false);
  perform pg_temp.chk('Stella sees the request', req is not null,
                      case when req is null then 'no request was ever created' else '' end);

  select count(*) into n from band_requests();
  perform pg_temp.chk('one request, not more', n = 1, n::text);

  select band_request_count() into n;
  perform pg_temp.chk('the badge counts it', n = 1, n::text);

  perform pg_temp.be(current_setting('test.priya')::uuid);
  select count(*) into n from band_requests();
  perform pg_temp.chk('a stranger sees no requests', n = 0, n::text);

  begin
    perform answer_band_request(req, true);
  exception when others then refused := true;
  end;
  perform pg_temp.chk('a stranger cannot approve it', refused);

  select count(*) into n from band_members
   where band_id = current_setting('test.band')::uuid
     and user_id = current_setting('test.hasan')::uuid;
  perform pg_temp.chk('and nobody was let in by the attempt', n = 0);
end $$;

-- ------------------------------------------------------------
--  8. Approve
-- ------------------------------------------------------------
do $$
declare n int; r record; conv uuid;
begin
  perform pg_temp.be(current_setting('test.stella')::uuid);
  perform answer_band_request(current_setting('test.req')::uuid, true);

  select count(*) into n from band_members
   where band_id = current_setting('test.band')::uuid
     and user_id = current_setting('test.hasan')::uuid;
  perform pg_temp.chk('approving puts him in the band', n = 1, n::text);

  select count(*) into n from band_requests();
  perform pg_temp.chk('and clears the request', n = 0, n::text);

  -- he is in the band chat
  select c.id into conv from conversations c
   where c.kind = 'band' and c.band_id = current_setting('test.band')::uuid;
  select count(*) into n from conversation_members
   where conversation_id = conv and user_id = current_setting('test.hasan')::uuid;
  perform pg_temp.chk('and in the band chat', n = 1, n::text);

  -- NOW he sees the practice
  perform pg_temp.be(current_setting('test.hasan')::uuid);
  select count(*) into n from band_schedule(current_setting('test.band')::uuid);
  perform pg_temp.chk('a member sees both dates', n = 2, n || ' dates');

  select count(*) into n from band_schedule(current_setting('test.band')::uuid)
   where kind = 'practice' and address is not null;
  perform pg_temp.chk('and now gets the rehearsal address', n = 1);

  select * into r from band_page(current_setting('test.band')::uuid);
  perform pg_temp.chk('his band page says he is in', r.i_am_member, '');
  perform pg_temp.chk('but not that he runs it', r.i_am_admin = false, '');
end $$;

-- ------------------------------------------------------------
--  9. Decline
-- ------------------------------------------------------------
do $$
declare req uuid; n int; r record;
begin
  perform pg_temp.be(current_setting('test.priya')::uuid);
  perform ask_to_join_band(current_setting('test.band')::uuid, '{Keys}', 'Keys', null);

  perform pg_temp.be(current_setting('test.stella')::uuid);
  select request_id into req from band_requests() limit 1;
  perform pg_temp.chk('a second request arrives', req is not null);

  if req is not null then perform answer_band_request(req, false); end if;

  select count(*) into n from band_members
   where band_id = current_setting('test.band')::uuid
     and user_id = current_setting('test.priya')::uuid;
  perform pg_temp.chk('declining lets nobody in', n = 0, n::text);

  perform pg_temp.be(current_setting('test.priya')::uuid);
  select * into r from band_page(current_setting('test.band')::uuid);
  perform pg_temp.chk('she is told it was declined', r.my_request = 'declined', coalesce(r.my_request,'null'));

  select count(*) into n from band_schedule(current_setting('test.band')::uuid);
  perform pg_temp.chk('and still sees only the gig', n = 1, n || ' dates');
end $$;

-- ------------------------------------------------------------
--  10. join_band, the old door, is now a doorbell
-- ------------------------------------------------------------
do $$
declare got boolean; n int;
begin
  perform pg_temp.be(current_setting('test.priya')::uuid);
  -- clear her declined request so she may ask again
  got := join_band(current_setting('test.band')::uuid, '{Keys}', 'Keys');
  perform pg_temp.chk('join_band no longer admits anyone', got = false);

  select count(*) into n from band_members
   where band_id = current_setting('test.band')::uuid
     and user_id = current_setting('test.priya')::uuid;
  perform pg_temp.chk('she is still outside', n = 0, n::text);

  select count(*) into n from band_join_requests
   where band_id = current_setting('test.band')::uuid
     and user_id = current_setting('test.priya')::uuid and status = 'pending';
  perform pg_temp.chk('it asked on her behalf instead', n = 1, n::text);
end $$;

-- ------------------------------------------------------------
--  11. A members-only gig is still members-only
-- ------------------------------------------------------------
do $$
declare n int; e uuid; v text;
begin
  perform pg_temp.be(current_setting('test.stella')::uuid);
  e := add_band_event(current_setting('test.band')::uuid, 'gig', now() + interval '14 days',
                      'a wedding','Private address', null, null, 'members');

  select visibility into v from band_events where id = e;
  perform pg_temp.chk('a gig marked members-only stays members-only', v = 'members', coalesce(v,'null'));

  perform pg_temp.be(current_setting('test.priya')::uuid);
  select count(*) into n from gigs_near_me(0, 365);
  perform pg_temp.chk('a private booking never appears in gigs near me', n = 1, n || ' found');
end $$;

-- ------------------------------------------------------------
--  11b. ...and a gig nobody said anything about is still public
--
--  The fix above removed a column default and narrowed a trigger.
--  This is the check that it removed the right one.
-- ------------------------------------------------------------
do $$
declare e uuid; v text; n int;
begin
  perform pg_temp.be(current_setting('test.stella')::uuid);

  e := add_band_event(current_setting('test.band')::uuid, 'gig',
                      now() + interval '16 days', 'Great Scott', '1222 Comm Ave');
  select visibility into v from band_events where id = e;
  perform pg_temp.chk('a gig with nothing said is public', v = 'public', coalesce(v,'null'));

  e := add_band_event(current_setting('test.band')::uuid, 'recording',
                      now() + interval '17 days', 'Q Division');
  select visibility into v from band_events where id = e;
  perform pg_temp.chk('a recording with nothing said is not', v = 'members', coalesce(v,'null'));

  -- a straight insert, going round the function entirely
  insert into band_events (band_id, kind, starts_at, place, visibility)
  values (current_setting('test.band')::uuid, 'gig', now() + interval '18 days', 'the pub', 'members')
  returning id into e;
  select visibility into v from band_events where id = e;
  perform pg_temp.chk('and a direct insert cannot be overruled either', v = 'members', coalesce(v,'null'));

  -- a straight insert that says nothing still gets the default
  insert into band_events (band_id, kind, starts_at, place)
  values (current_setting('test.band')::uuid, 'gig', now() + interval '19 days', 'the other pub')
  returning id into e;
  select visibility into v from band_events where id = e;
  perform pg_temp.chk('a direct insert that says nothing is public', v = 'public', coalesce(v,'null'));

  perform pg_temp.be(current_setting('test.priya')::uuid);
  select count(*) into n from gigs_near_me(0, 365);
  perform pg_temp.chk('three public gigs, and neither private one', n = 3, n || ' found');
end $$;

-- ------------------------------------------------------------
--  12. And a practice still refuses to be public
-- ------------------------------------------------------------
do $$
declare refused boolean := false;
begin
  perform pg_temp.be(current_setting('test.stella')::uuid);
  begin
    perform add_band_event(current_setting('test.band')::uuid, 'practice',
                           now() + interval '20 days', 'home', '14 Dane St', null, null, 'public');
  exception when others then refused := true;
  end;
  perform pg_temp.chk('a practice cannot be made public', refused);
end $$;

-- ------------------------------------------------------------
--  Results
-- ------------------------------------------------------------
\pset tuples_only off
\pset format aligned
select n, case when ok then 'PASS' else 'FAIL' end as result, name, detail from t order by n;

\pset tuples_only on
\pset format unaligned
select case when count(*) filter (where not ok) = 0
            then E'\n' || count(*) || ' checks, all passed.'
            else E'\n' || count(*) filter (where not ok) || ' FAILED of ' || count(*) end
from t;

do $$
begin
  if exists (select 1 from t where not ok) then
    raise exception 'gigs.test.sql failed';
  end if;
end $$;
