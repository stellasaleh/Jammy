-- ============================================================
--  JAMMY — roster.test.sql
--  Getting into a band, and back out of it.
--
--  The question that started this: "why does it say Hasan is a
--  member of the band? is he?" He was — he got in through the old
--  rule that let anyone add themselves — and there was no way to
--  take him out, and no way for him to leave either.
--
--  Run as an ordinary signed-in user, never as the owner.
--    psql -d jammy -U app_user -f test/roster.test.sql
-- ============================================================

\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on

create temp table t (n int generated always as identity, name text, ok boolean, detail text);
create function pg_temp.chk(nm text, cond boolean, detail text default '') returns void
language plpgsql as $$
begin insert into t (name, ok, detail) values (nm, coalesce(cond,false), detail); end $$;
create function pg_temp.be(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', u::text, false); end $$;

-- ------------------------------------------------------------
--  Stella runs a band. Hasan and Noor are in it. Priya is not.
-- ------------------------------------------------------------
do $$
declare s uuid; h uuid; n uuid; p uuid; b uuid; q uuid;
begin
  s := gen_random_uuid(); h := gen_random_uuid();
  n := gen_random_uuid(); p := gen_random_uuid();
  perform set_config('test.stella', s::text, false);
  perform set_config('test.hasan',  h::text, false);
  perform set_config('test.noor',   n::text, false);
  perform set_config('test.priya',  p::text, false);

  insert into auth.users (id) values (s),(h),(n),(p);

  perform pg_temp.be(s);
  insert into profiles (id, display_name, handle, city, instruments, genres, birth_date)
  values (s,'Stella','r_stella_'||substr(s::text,1,8),'Boston','{Guitar}','{Indie}','1999-04-02');
  perform pg_temp.be(h);
  insert into profiles (id, display_name, handle, city, instruments, genres, birth_date)
  values (h,'Hasan','r_hasan_'||substr(h::text,1,8),'Boston','{Bass}','{Indie}','1998-02-02');
  perform pg_temp.be(n);
  insert into profiles (id, display_name, handle, city, instruments, genres, birth_date)
  values (n,'Noor','r_noor_'||substr(n::text,1,8),'Boston','{Drums}','{Indie}','1997-03-03');
  perform pg_temp.be(p);
  insert into profiles (id, display_name, handle, city, instruments, genres, birth_date)
  values (p,'Priya','r_priya_'||substr(p::text,1,8),'Boston','{Keys}','{Jazz}','1996-04-04');

  perform pg_temp.be(s);
  b := create_band('The Fog Signals','Boston','{Indie}','','{Guitar}','Guitar');
  perform set_config('test.band', b::text, false);
  perform add_band_event(b,'practice', now() + interval '2 days',
                         'Stella''s place','14 Dane St','bring the DI box');

  -- Hasan and Noor ask, Stella says yes to both
  perform pg_temp.be(h); perform ask_to_join_band(b,'{Bass}','Bass',null);
  perform pg_temp.be(n); perform ask_to_join_band(b,'{Drums}','Drums',null);
  perform pg_temp.be(s);
  for q in select request_id from band_requests(b) loop
    perform answer_band_request(q, true);
  end loop;
end $$;

do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.stella')::uuid);
  select count(*) into n from band_roster(current_setting('test.band')::uuid);
  perform pg_temp.chk('three people are in the band', n = 3, n::text);
end $$;

-- ------------------------------------------------------------
--  1. "Is he really in it?" — the band can see how he got there
-- ------------------------------------------------------------
do $$
declare r record; n int;
begin
  perform pg_temp.be(current_setting('test.stella')::uuid);

  select * into r from band_roster_detail(current_setting('test.band')::uuid)
   where user_id = current_setting('test.hasan')::uuid;
  perform pg_temp.chk('the band can see when somebody joined', r.joined_at is not null);
  perform pg_temp.chk('and that he does not run the band', r.is_admin = false);
  perform pg_temp.chk('and that he can be removed', r.can_remove);

  select * into r from band_roster_detail(current_setting('test.band')::uuid)
   where is_me;
  perform pg_temp.chk('and that you cannot remove yourself', r.can_remove = false);

  -- a stranger gets nothing: joining dates are the band's business
  perform pg_temp.be(current_setting('test.priya')::uuid);
  select count(*) into n from band_roster_detail(current_setting('test.band')::uuid);
  perform pg_temp.chk('somebody outside the band sees no joining dates', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  2. Only the band can remove somebody
-- ------------------------------------------------------------
do $$
declare refused boolean := false; n int;
begin
  perform pg_temp.be(current_setting('test.priya')::uuid);
  begin
    perform remove_band_member(current_setting('test.band')::uuid,
                               current_setting('test.hasan')::uuid);
  exception when others then refused := true;
  end;
  perform pg_temp.chk('a stranger cannot remove anyone', refused);

  -- a member who does not run the band cannot either
  refused := false;
  perform pg_temp.be(current_setting('test.noor')::uuid);
  begin
    perform remove_band_member(current_setting('test.band')::uuid,
                               current_setting('test.hasan')::uuid);
  exception when others then refused := true;
  end;
  perform pg_temp.chk('and nor can a member who does not run it', refused);

  perform pg_temp.be(current_setting('test.stella')::uuid);
  select count(*) into n from band_roster(current_setting('test.band')::uuid);
  perform pg_temp.chk('so nobody has left', n = 3, n::text);
end $$;

-- ------------------------------------------------------------
--  3. Removing somebody — THE ANSWER TO HER QUESTION
-- ------------------------------------------------------------
do $$
declare got boolean; n int; conv uuid;
begin
  perform pg_temp.be(current_setting('test.stella')::uuid);
  got := remove_band_member(current_setting('test.band')::uuid,
                            current_setting('test.hasan')::uuid);
  perform pg_temp.chk('whoever runs the band can remove somebody', got);

  select count(*) into n from band_roster(current_setting('test.band')::uuid);
  perform pg_temp.chk('and they are off the roster', n = 2, n::text);

  select c.id into conv from conversations c
   where c.kind = 'band' and c.band_id = current_setting('test.band')::uuid;
  select count(*) into n from conversation_members
   where conversation_id = conv and user_id = current_setting('test.hasan')::uuid;
  perform pg_temp.chk('and out of the band chat', n = 0, n::text);

  -- and the practice address goes with it
  perform pg_temp.be(current_setting('test.hasan')::uuid);
  select count(*) into n from band_schedule(current_setting('test.band')::uuid)
   where address is not null;
  perform pg_temp.chk('and can no longer read the practice address', n = 0, n::text);

  select count(*) into n from band_schedule(current_setting('test.band')::uuid);
  perform pg_temp.chk('or see the practice at all', n = 0, n || ' dates');

  select count(*) into n from my_bands();
  perform pg_temp.chk('and the band is gone from their list', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  4. Removing twice is not an error, and asking again still works
-- ------------------------------------------------------------
do $$
declare got boolean; s text;
begin
  perform pg_temp.be(current_setting('test.stella')::uuid);
  got := remove_band_member(current_setting('test.band')::uuid,
                            current_setting('test.hasan')::uuid);
  perform pg_temp.chk('removing somebody already gone says so quietly', got = false);

  perform pg_temp.be(current_setting('test.hasan')::uuid);
  s := ask_to_join_band(current_setting('test.band')::uuid,'{Bass}','Bass',null);
  perform pg_temp.chk('and they may ask again afterwards', s = 'sent', s);
end $$;

-- ------------------------------------------------------------
--  5. A band is never emptied or left without an admin
-- ------------------------------------------------------------
do $$
declare refused boolean := false; n int; b2 uuid;
begin
  perform pg_temp.be(current_setting('test.stella')::uuid);
  b2 := create_band('A Band Of One','Boston','{Indie}','','{Guitar}','Guitar');

  begin
    perform remove_band_member(b2, current_setting('test.stella')::uuid);
  exception when others then refused := true;
  end;
  perform pg_temp.chk('you cannot remove yourself, you leave', refused);

  select count(*) into n from band_members where band_id = b2;
  perform pg_temp.chk('and the band still has somebody in it', n = 1, n::text);

  -- removing the only other person from the main band leaves one admin
  perform remove_band_member(current_setting('test.band')::uuid,
                             current_setting('test.noor')::uuid);
  select count(*) into n from band_members
   where band_id = current_setting('test.band')::uuid and is_admin;
  perform pg_temp.chk('a band always keeps somebody running it', n >= 1, n::text);
end $$;

-- ------------------------------------------------------------
--  6. LEAVING. The app's Leave button never told the database,
--     so a person who left stayed on the roster, in the chat,
--     and could still read the address.
-- ------------------------------------------------------------
do $$
declare got boolean; n int; conv uuid; b uuid; q uuid;
begin
  b := current_setting('test.band')::uuid;

  -- Noor comes back properly
  perform pg_temp.be(current_setting('test.noor')::uuid);
  perform ask_to_join_band(b,'{Drums}','Drums',null);
  perform pg_temp.be(current_setting('test.stella')::uuid);
  select request_id into q from band_requests(b)
   where user_id = current_setting('test.noor')::uuid;
  perform answer_band_request(q, true);

  select count(*) into n from band_roster(b);
  perform pg_temp.chk('Noor is back in the band', n = 2, n::text);

  -- and then leaves
  perform pg_temp.be(current_setting('test.noor')::uuid);
  got := leave_band(b);
  perform pg_temp.chk('leaving works', got);

  select count(*) into n from my_bands();
  perform pg_temp.chk('and the band leaves their list', n = 0, n::text);

  perform pg_temp.be(current_setting('test.stella')::uuid);
  select count(*) into n from band_roster(b);
  perform pg_temp.chk('and they are off the roster, which is the part that was broken',
                      n = 1, n::text);

  select c.id into conv from conversations c where c.kind='band' and c.band_id = b;
  select count(*) into n from conversation_members
   where conversation_id = conv and user_id = current_setting('test.noor')::uuid;
  perform pg_temp.chk('and out of the band chat', n = 0, n::text);

  perform pg_temp.be(current_setting('test.noor')::uuid);
  select count(*) into n from band_schedule(b) where address is not null;
  perform pg_temp.chk('and cannot read the practice address any more', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  7. And the old door is still shut
-- ------------------------------------------------------------
do $$
declare got boolean; n int; failed boolean := false;
begin
  perform pg_temp.be(current_setting('test.priya')::uuid);

  got := join_band(current_setting('test.band')::uuid,'{Keys}','Keys');
  perform pg_temp.chk('join_band still only asks', got = false);

  begin
    insert into band_members (band_id, user_id, instruments)
    values (current_setting('test.band')::uuid, current_setting('test.priya')::uuid, '{Keys}');
  exception when others then failed := true;
  end;
  select count(*) into n from band_members
   where band_id = current_setting('test.band')::uuid
     and user_id = current_setting('test.priya')::uuid;
  perform pg_temp.chk('and nobody can still add themselves', failed and n = 0,
                      case when n > 0 then 'SHE IS IN THE BAND' else 'refused' end);
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
    raise exception 'roster.test.sql failed';
  end if;
end $$;
