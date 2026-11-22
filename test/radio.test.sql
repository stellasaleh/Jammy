-- ============================================================
--  JAMMY — radio.test.sql
--  Fifteen seconds, and finding somebody nobody has heard yet.
--
--  Run as an ordinary signed-in user, never as the owner.
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
--  Ana is established. Bo is brand new. Cass is listening.
-- ------------------------------------------------------------
do $$
declare a uuid; b uuid; c uuid; t1 uuid; t2 uuid;
begin
  a := gen_random_uuid(); b := gen_random_uuid(); c := gen_random_uuid();
  perform set_config('test.ana', a::text, false);
  perform set_config('test.bo',  b::text, false);
  perform set_config('test.cass',c::text, false);
  insert into auth.users (id) values (a),(b),(c);

  perform pg_temp.be(a);
  insert into profiles (id, display_name, handle, city, instruments, genres, birth_date, bio)
  values (a,'Ana','r_ana_'||substr(a::text,1,8),'Boston','{Bass}','{Indie}','1997-01-01','Been at this a while');
  insert into tracks (owner_id, title, audio_path, key, bpm, is_public)
  values (a,'Established Thing', a||'/tracks/one.mp3','A minor',104,true) returning id into t1;
  perform set_config('test.track_ana', t1::text, false);

  perform pg_temp.be(b);
  insert into profiles (id, display_name, handle, city, instruments, genres, birth_date, bio)
  values (b,'Bo','r_bo_'||substr(b::text,1,8),'Boston','{Drums}','{Indie}','1996-01-01','Just moved here');
  insert into tracks (owner_id, title, audio_path, key, bpm, is_public)
  values (b,'First Take', b||'/tracks/two.mp3','C',92,true) returning id into t2;
  perform set_config('test.track_bo', t2::text, false);

  perform pg_temp.be(c);
  insert into profiles (id, display_name, handle, city, instruments, genres, birth_date)
  values (c,'Cass','r_cass_'||substr(c::text,1,8),'Boston','{Keys}','{Indie}','1995-01-01');
end $$;

-- ------------------------------------------------------------
--  1. Fifteen seconds counts; fourteen does not
-- ------------------------------------------------------------
--  Counted through tracks.play_count, not play_daily: 06_lockdown.sql
--  closes the raw play tables to the app on purpose, so an ordinary
--  user reading play_daily sees nothing whether the rollup ran or not.
--  A check that cannot see its subject is not a check.
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.cass')::uuid);

  insert into plays (track_id, user_id, seconds, source)
  values (current_setting('test.track_ana')::uuid, (select auth.uid()), 14, 'radio');
  select play_count into n from tracks where id = current_setting('test.track_ana')::uuid;
  perform pg_temp.chk('fourteen seconds is not a play', n = 0, n::text);

  insert into plays (track_id, user_id, seconds, source)
  values (current_setting('test.track_ana')::uuid, (select auth.uid()), 15, 'radio');
  select play_count into n from tracks where id = current_setting('test.track_ana')::uuid;
  perform pg_temp.chk('fifteen seconds is', n = 1, n::text);

  -- and the raw table stays closed, which is why the above reads tracks
  select count(*)::int into n from play_daily;
  perform pg_temp.chk('(the raw play table is still closed to the app)', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  2. The dedupe is what stops the chart being gamed, not the
--     length. Play it ten more times; the listener count holds.
-- ------------------------------------------------------------
do $$
declare r record; i int;
begin
  perform pg_temp.be(current_setting('test.cass')::uuid);
  for i in 1..10 loop
    insert into plays (track_id, user_id, seconds, source)
    values (current_setting('test.track_ana')::uuid, (select auth.uid()), 20, 'radio');
  end loop;

  -- read it the way the app does: through the chart
  select * into r from weekly_chart(10)
   where track_id = current_setting('test.track_ana')::uuid;
  perform pg_temp.chk('playing it again and again still counts one listener',
                      r.listeners = 1,
                      coalesce(r.listeners::text,'?') || ' listeners from '
                      || coalesce(r.plays::text,'?') || ' plays');
end $$;

-- ------------------------------------------------------------
--  3. Discover a new artist
-- ------------------------------------------------------------
do $$
declare r record; n int;
begin
  perform pg_temp.be(current_setting('test.cass')::uuid);

  select * into r from rising_track();
  perform pg_temp.chk('the radio can find somebody to introduce', r.track_id is not null);
  perform pg_temp.chk('and it picks the one nobody has played',
    r.title = 'First Take', coalesce(r.title,'null'));
  perform pg_temp.chk('with the person behind it', r.artist_name = 'Bo', coalesce(r.artist_name,'null'));
  perform pg_temp.chk('and something about them to read', r.artist_bio = 'Just moved here');
  perform pg_temp.chk('and what you both play',
    'Indie' = any(r.shared_genres), coalesce(array_to_string(r.shared_genres,','),'none'));
  perform pg_temp.chk('and how new the track is', r.uploaded_days_ago = 0, r.uploaded_days_ago::text);
end $$;

-- ------------------------------------------------------------
--  4. It never introduces you to yourself
-- ------------------------------------------------------------
do $$
declare r record; n int;
begin
  perform pg_temp.be(current_setting('test.bo')::uuid);
  select count(*) into n from rising_track() where artist_id = current_setting('test.bo')::uuid;
  perform pg_temp.chk('your own track is never the new artist', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  5. Nor to anyone blocked, in either direction
-- ------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.cass')::uuid);
  insert into blocks (blocker_id, blocked_id)
  values ((select auth.uid()), current_setting('test.bo')::uuid);

  select count(*) into n from rising_track() where artist_id = current_setting('test.bo')::uuid;
  perform pg_temp.chk('somebody you blocked is never introduced to you', n = 0, n::text);

  -- and the direction that used to be broken everywhere
  perform pg_temp.be(current_setting('test.bo')::uuid);
  select count(*) into n from rising_track() where artist_id = current_setting('test.cass')::uuid;
  perform pg_temp.chk('and the block holds the other way too', n = 0, n::text);

  perform pg_temp.be(current_setting('test.cass')::uuid);
  delete from blocks where blocker_id = (select auth.uid());
end $$;

-- ------------------------------------------------------------
--  6. A private track is not introduced to anybody
-- ------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.bo')::uuid);
  update tracks set is_public = false where id = current_setting('test.track_bo')::uuid;

  perform pg_temp.be(current_setting('test.cass')::uuid);
  select count(*) into n from rising_track()
   where track_id = current_setting('test.track_bo')::uuid;
  perform pg_temp.chk('a track kept private is never introduced', n = 0, n::text);

  perform pg_temp.be(current_setting('test.bo')::uuid);
  update tracks set is_public = true where id = current_setting('test.track_bo')::uuid;
end $$;

-- ------------------------------------------------------------
--  7. It is a score, not a filter — so it is never empty
--
--  A filter like "under ten plays" empties the day everybody has
--  eleven. Give Bo's track plenty of plays and the radio must
--  still have somebody to introduce.
-- ------------------------------------------------------------
do $$
declare r record; i int; u uuid;
begin
  for i in 1..30 loop
    u := gen_random_uuid();
    insert into auth.users (id) values (u);
    perform pg_temp.be(u);
    insert into profiles (id, display_name, handle, city, instruments, genres, birth_date)
    values (u,'Listener '||i,'r_l'||i||'_'||substr(u::text,1,6),'Boston','{Voice}','{Indie}','1995-01-01');
    insert into plays (track_id, user_id, seconds, source)
    values (current_setting('test.track_bo')::uuid, u, 60, 'radio');
  end loop;

  perform pg_temp.be(current_setting('test.cass')::uuid);
  select * into r from rising_track();
  perform pg_temp.chk('even when every track is popular, there is still somebody to show',
                      r.track_id is not null, coalesce(r.title,'nothing'));
end $$;

-- ------------------------------------------------------------
--  8. And it is one row, so a screen can rely on it
-- ------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.cass')::uuid);
  select count(*) into n from rising_track();
  perform pg_temp.chk('it returns exactly one artist', n = 1, n::text);
end $$;

-- ------------------------------------------------------------
--  9. Taking a recording down takes it off the radio too
--
--  Stella's question: if I upload a track, can I remove it later?
--  Off the profile is the easy half. Off the chart is the half
--  that would quietly not happen if play_daily did not cascade —
--  the track would be gone and its plays would still be ranked.
-- ------------------------------------------------------------
do $$
declare n int; tr uuid;
begin
  -- Ana's track has real plays on it by now
  perform pg_temp.be(current_setting('test.ana')::uuid);
  tr := current_setting('test.track_ana')::uuid;

  select count(*)::int into n from weekly_chart(50) where track_id = tr;
  perform pg_temp.chk('the track is on the chart to begin with', n = 1, n::text);

  delete from tracks where id = tr;
  select count(*)::int into n from tracks where id = tr;
  perform pg_temp.chk('you can delete your own recording', n = 0, n::text);

  select count(*)::int into n from weekly_chart(50) where track_id = tr;
  perform pg_temp.chk('and it leaves the chart with it', n = 0, n::text);

  select count(*)::int into n from tracks_by(current_setting('test.ana')::uuid);
  perform pg_temp.chk('and your profile no longer lists it', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  10. But only your own
-- ------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.cass')::uuid);
  delete from tracks where id = current_setting('test.track_bo')::uuid;
  select count(*)::int into n from tracks where id = current_setting('test.track_bo')::uuid;
  perform pg_temp.chk('you cannot delete somebody else''s recording', n = 1, n::text);
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
    raise exception 'radio.test.sql failed';
  end if;
end $$;
