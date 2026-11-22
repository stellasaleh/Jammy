-- ============================================================
--  JAMMY — account.test.sql
--  Deleting your account, and taking your data with you.
--
--  Apple rejects apps that let you sign up and not delete
--  (guideline 5.1.1(v)). Until now the button cleared the phone
--  and left everything in the database.
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
--  Ana is leaving. Bo stays, and has talked to her.
-- ------------------------------------------------------------
do $$
declare a uuid; b uuid; conv uuid; p uuid; bd uuid;
begin
  a := gen_random_uuid(); b := gen_random_uuid();
  perform set_config('test.ana', a::text, false);
  perform set_config('test.bo',  b::text, false);
  insert into auth.users (id) values (a),(b);

  perform pg_temp.be(a);
  insert into profiles (id, display_name, handle, city, location, instruments, genres, birth_date)
  values (a,'Ana','a_ana_'||substr(a::text,1,8),'Boston',
          st_setsrid(st_makepoint(-71.06,42.36),4326)::geography,'{Bass}','{Indie}','1997-01-01');
  perform pg_temp.be(b);
  insert into profiles (id, display_name, handle, city, location, instruments, genres, birth_date)
  values (b,'Bo','a_bo_'||substr(b::text,1,8),'Boston',
          st_setsrid(st_makepoint(-71.07,42.37),4326)::geography,'{Drums}','{Indie}','1996-01-01');

  -- they connect and talk
  perform pg_temp.be(a); perform swipe_and_check(b,'yes');
  perform pg_temp.be(b); perform swipe_and_check(a,'yes');

  perform pg_temp.be(a);
  conv := dm_with(b);
  perform set_config('test.conv', conv::text, false);
  insert into messages (conversation_id, sender_id, body)
  values (conv, a, 'see you Tuesday');

  -- she posts, comments, starts a band and gets reported
  p := add_post('Looking for a drummer', 'looking', '{"instrument":"Drums"}'::jsonb);
  perform set_config('test.post', p::text, false);
  bd := create_band('Ana''s Band','Boston','{Indie}','','{Bass}','Bass');
  perform set_config('test.band', bd::text, false);

  perform pg_temp.be(b);
  insert into post_comments (post_id, author_id, body) values (p, b, 'I play Tuesdays');
  insert into reports (reporter_id, target_user, reason, note)
  values (b, a, 'spam', 'posted the same thing four times');
end $$;

-- ------------------------------------------------------------
--  1. Download my data — which the privacy policy promises
-- ------------------------------------------------------------
do $$
declare j jsonb;
begin
  perform pg_temp.be(current_setting('test.ana')::uuid);
  j := export_my_data();

  perform pg_temp.chk('you can export everything Jammy holds on you', j is not null);
  perform pg_temp.chk('with your profile in it',
    j #>> '{profile,display_name}' = 'Ana', coalesce(j #>> '{profile,display_name}','null'));
  perform pg_temp.chk('your posts', jsonb_array_length(j->'posts') = 1,
    jsonb_array_length(j->'posts')::text);
  perform pg_temp.chk('the messages you sent',
    jsonb_array_length(j->'messages_you_sent') = 1,
    jsonb_array_length(j->'messages_you_sent')::text);
  perform pg_temp.chk('your bands', jsonb_array_length(j->'bands') = 1,
    jsonb_array_length(j->'bands')::text);
  perform pg_temp.chk('and who you are connected to',
    jsonb_array_length(j->'connections') = 1,
    jsonb_array_length(j->'connections')::text);

  -- the policy says coordinates are rounded to about a mile; the export
  -- must not be the one place that hands back something more precise
  perform pg_temp.chk('the location in it is rounded, not exact',
    (j #>> '{profile,approximate_location,latitude}') = '42.36',
    coalesce(j #>> '{profile,approximate_location,latitude}','null'));
  perform pg_temp.chk('and the raw coordinates are not in there at all',
    (j->'profile') ? 'location' = false);
end $$;

-- ------------------------------------------------------------
--  2. The export is yours and nobody else's
-- ------------------------------------------------------------
do $$
declare j jsonb;
begin
  perform pg_temp.be(current_setting('test.bo')::uuid);
  j := export_my_data();
  perform pg_temp.chk('somebody else''s export is their own data',
    j #>> '{profile,display_name}' = 'Bo', coalesce(j #>> '{profile,display_name}','null'));
  perform pg_temp.chk('and has none of your posts',
    jsonb_array_length(j->'posts') = 0, jsonb_array_length(j->'posts')::text);
end $$;

-- ------------------------------------------------------------
--  3. Deleting needs you to mean it
-- ------------------------------------------------------------
do $$
declare refused boolean := false; n int;
begin
  perform pg_temp.be(current_setting('test.ana')::uuid);
  begin
    perform delete_my_account('yes');
  exception when others then refused := true;
  end;
  perform pg_temp.chk('deleting without typing the word is refused', refused);

  select count(*) into n from profiles where id = current_setting('test.ana')::uuid;
  perform pg_temp.chk('and nothing happened', n = 1, n::text);
end $$;

-- ------------------------------------------------------------
--  4. Deleting
-- ------------------------------------------------------------
do $$
declare r jsonb; n int;
begin
  perform pg_temp.be(current_setting('test.ana')::uuid);
  r := delete_my_account('delete');
  perform pg_temp.chk('the account deletes', (r->>'deleted')::boolean);
  perform pg_temp.chk('and the sign-in goes with it', (r->>'sign_in_removed')::boolean);

  select count(*) into n from auth.users where id = current_setting('test.ana')::uuid;
  perform pg_temp.chk('so signing in again is not possible', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  5. What went, checked from the account that stayed
-- ------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.bo')::uuid);

  select count(*) into n from profiles where id = current_setting('test.ana')::uuid;
  perform pg_temp.chk('the profile is gone', n = 0, n::text);

  select count(*) into n from feed_page() where author_id = current_setting('test.ana')::uuid;
  perform pg_temp.chk('the posts are gone', n = 0, n::text);

  select count(*) into n from band_members where user_id = current_setting('test.ana')::uuid;
  perform pg_temp.chk('and they are out of every band', n = 0, n::text);

  select count(*) into n from connections
   where a_id = current_setting('test.ana')::uuid or b_id = current_setting('test.ana')::uuid;
  perform pg_temp.chk('the connection is gone', n = 0, n::text);

  select count(*) into n from swipes
   where from_id = current_setting('test.ana')::uuid or to_id = current_setting('test.ana')::uuid;
  perform pg_temp.chk('and so is every yes and no they ever gave', n = 0, n::text);

  select count(*) into n from my_connections();
  perform pg_temp.chk('and Bo''s connections no longer lists them', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  6. What stays, and why
--
--  The privacy policy says: "Messages you sent may remain visible
--  to the person who received them, in the same way a sent text
--  does." The alternative is editing somebody else's conversation
--  after they have read it.
-- ------------------------------------------------------------
do $$
declare n int; b text;
begin
  perform pg_temp.be(current_setting('test.bo')::uuid);

  select count(*) into n from messages
   where conversation_id = current_setting('test.conv')::uuid;
  perform pg_temp.chk('the message they sent is still in Bo''s conversation', n = 1, n::text);

  select body into b from messages
   where conversation_id = current_setting('test.conv')::uuid limit 1;
  perform pg_temp.chk('and still readable', b = 'see you Tuesday', coalesce(b,'null'));

  select count(*) into n from messages
   where conversation_id = current_setting('test.conv')::uuid and sender_id is not null;
  perform pg_temp.chk('with nobody behind it any more', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  7. A safety record is not a way to wipe your own history
--
--  Reports about somebody cascade from the profile, so deleting
--  your account would otherwise erase the record of what you did
--  and let you sign up again clean. The policy keeps them twelve
--  months.
-- ------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.bo')::uuid);
  select count(*) into n from reports where reason = 'spam';
  perform pg_temp.chk('the report about them outlives the account', n = 1, n::text);

  select count(*) into n from reports where reason = 'spam' and target_user is not null;
  perform pg_temp.chk('with no profile attached to it', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  8. You cannot delete anybody but yourself
-- ------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.bo')::uuid);
  -- there is no argument for whose account to delete, by design
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname='public' and p.proname='delete_my_account' and p.pronargs = 1;
  perform pg_temp.chk('delete_my_account takes no user to delete', n = 1, n::text);

  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname='public' and p.proname='export_my_data' and p.pronargs = 0;
  perform pg_temp.chk('and export_my_data takes none either', n = 1, n::text);
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
    raise exception 'account.test.sql failed';
  end if;
end $$;
