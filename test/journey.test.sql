-- ============================================================
--  JAMMY — journey.test.sql
--
--  The whole thing a person does, start to finish, run as an
--  ordinary signed-in user rather than as the database owner.
--
--  That distinction is the point. The owner bypasses row-level
--  security and ignores table grants, so testing as the owner
--  silently skips the exact machinery most likely to be wrong.
--  Every bug this project has hit in production — the missing
--  grant on `blocks`, the trigger that ignored updates, the
--  distance ring that excluded everyone without coordinates —
--  was invisible to an owner and obvious to a user.
--
--  Run against a database built from 01–13 with real PostGIS.
--  Every line prints PASS or FAIL. Nothing should print FAIL.
-- ============================================================

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

-- a clean slate
delete from messages;
delete from conversation_members;
delete from conversations;
delete from connections;
delete from swipes;
delete from blocks;
delete from rate_counters;
delete from profiles where handle in ('tester_t','tester_d','tester_far','tester_nogps');
delete from auth.users where id in (
  '11110000-0000-0000-0000-000000000001',
  '11110000-0000-0000-0000-000000000002',
  '11110000-0000-0000-0000-000000000003',
  '11110000-0000-0000-0000-000000000004');

insert into auth.users (id) values
  ('11110000-0000-0000-0000-000000000001'),
  ('11110000-0000-0000-0000-000000000002'),
  ('11110000-0000-0000-0000-000000000003'),
  ('11110000-0000-0000-0000-000000000004');

create or replace function t(label text, got boolean) returns text
language sql immutable as $$ select case when got then 'PASS  ' else 'FAIL  ' end || label $$;

-- ------------------------------------------------------------
--  1. Signing up
-- ------------------------------------------------------------
\echo '-- signing up --'
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
insert into profiles (id, handle, display_name, city, instruments, genres,
                      looking_for, looking_for_instruments, rehearsal_days,
                      birth_date, terms_agreed_at, remote_ok)
values ('11110000-0000-0000-0000-000000000001','tester_t','Trumpet Tester','Boston',
        '{Trumpet}','{Jazz,Funk}','Form a band','{Drums}','{Wed}','2000-03-01',now(),false);
select t('a signed-in person can create their own profile',
         (select count(*) = 1 from profiles where id = auth.uid()));

-- the app stores a blunted location, never an exact one
update profiles set location = 'SRID=4326;POINT(-71.06 42.36)' where id = auth.uid();
-- read back through has_location, not the point itself: since 23_columns
-- an ordinary member cannot select the coordinate at all, their own included
select t('and can save their own location',
         (select has_location from profiles where id = auth.uid()));
reset role;

set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
insert into profiles (id, handle, display_name, city, instruments, genres,
                      looking_for, looking_for_instruments, rehearsal_days,
                      birth_date, terms_agreed_at, remote_ok)
values ('11110000-0000-0000-0000-000000000002','tester_d','Drum Tester','Boston',
        '{Drums}','{Jazz}','Join a band','{Trumpet}','{Wed}','1996-05-05',now(),false);
update profiles set location = 'SRID=4326;POINT(-71.09 42.37)' where id = auth.uid();
reset role;

-- someone genuinely far away, and someone with no location at all
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000003';
insert into profiles (id, handle, display_name, city, instruments, genres, birth_date, terms_agreed_at)
values ('11110000-0000-0000-0000-000000000003','tester_far','Far Drummer','Seattle',
        '{Drums}','{Jazz}','1990-01-01',now());
update profiles set location = 'SRID=4326;POINT(-122.33 47.61)' where id = auth.uid();
reset role;

set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000004';
insert into profiles (id, handle, display_name, city, instruments, genres, birth_date, terms_agreed_at)
values ('11110000-0000-0000-0000-000000000004','tester_nogps','No GPS Bassist','Boston',
        '{Bass}','{Jazz}','1994-01-01',now());
reset role;

-- ------------------------------------------------------------
--  2. Finding people
-- ------------------------------------------------------------
\echo '-- finding people --'
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';

select t('the drummer two miles away is found',
         exists (select 1 from discover(7) where handle = 'tester_d'));

select t('the distance is right (about 2 miles, real PostGIS)',
         (select miles between 1 and 3 from discover(7) where handle = 'tester_d'));

select t('a drummer in Seattle is NOT shown to a Boston player',
         not exists (select 1 from discover(7) where handle = 'tester_far'));

select t('someone with no location is matched on their city instead',
         exists (select 1 from discover(7) where handle = 'tester_nogps'));

select t('that person comes back with no distance rather than a made-up one',
         (select miles is null from discover(7) where handle = 'tester_nogps'));

select t('"any distance" means any distance, not zero miles',
         exists (select 1 from discover(0) where handle = 'tester_far'));

select t('another trumpet player is excluded by default',
         not exists (select 1 from discover(7) where 'Trumpet' = any(instruments)));

select t('the drummer who wants a trumpet scores higher than the bassist who said nothing',
         (select fit from discover(7) where handle='tester_d')
       > (select fit from discover(7) where handle='tester_nogps'));
reset role;

-- ------------------------------------------------------------
--  3. Swiping and matching
-- ------------------------------------------------------------
\echo '-- swiping and matching --'
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
select t('one-sided yes creates no match',
         not (select matched from swipe_and_check('11110000-0000-0000-0000-000000000002','yes')));
select t('and the person you swiped on does not come back around',
         not exists (select 1 from discover(7) where handle = 'tester_d'));
reset role;

set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
select t('swiping back makes a match',
         (select matched from swipe_and_check('11110000-0000-0000-0000-000000000001','yes')));
select t('and a conversation comes with it',
         (select conversation_id is not null from swipe_and_check('11110000-0000-0000-0000-000000000001','yes')));
reset role;

-- the bug that cost a day: swiping again UPDATES the row, which once
-- skipped the trigger entirely and left a match with nothing behind it
\echo '-- re-swiping (the update case) --'
delete from connections; delete from conversation_members; delete from conversations;
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
select t('swiping a SECOND time still matches (update, not insert)',
         (select matched from swipe_and_check('11110000-0000-0000-0000-000000000002','yes')));
select t('and still creates the conversation',
         (select count(*) = 1 from conversations where kind = 'dm'));
reset role;

-- ------------------------------------------------------------
--  4. Messaging
-- ------------------------------------------------------------
\echo '-- messaging --'
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
insert into messages (conversation_id, sender_id, body)
  select dm_with('11110000-0000-0000-0000-000000000002'), auth.uid(), 'bring the kit thursday';
select t('a message can be sent to a match',
         (select count(*) = 1 from messages));
select t('the connections list shows them',
         exists (select 1 from my_connections() where handle = 'tester_d'));
reset role;

set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
select t('the other person sees the conversation',
         exists (select 1 from my_conversations() where other_id = '11110000-0000-0000-0000-000000000001'));
select t('with the message preview',
         (select last_body = 'bring the kit thursday' from my_conversations() limit 1));
select t('and it is marked unread',
         (select unread = 1 from my_conversations() limit 1));

update conversation_members set last_read_at = now() where user_id = auth.uid();
select t('reading it clears the unread count',
         (select unread = 0 from my_conversations() limit 1));
reset role;

-- ------------------------------------------------------------
--  5. Blocking — the part Apple actually tests
-- ------------------------------------------------------------
\echo '-- blocking --'
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
insert into blocks (blocker_id, blocked_id)
  values (auth.uid(), '11110000-0000-0000-0000-000000000001');
select t('a blocked person disappears from the conversation list',
         not exists (select 1 from my_conversations() where other_id = '11110000-0000-0000-0000-000000000001'));
select t('and from the connections list',
         not exists (select 1 from my_connections() where handle = 'tester_t'));
reset role;

set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
select t('blocking works in BOTH directions, not just for the blocker',
         not exists (select 1 from my_conversations() where other_id = '11110000-0000-0000-0000-000000000002'));
-- NOTE: tester_t already swiped on tester_d, so Discover would exclude them
-- either way. Testing the block here would pass for the wrong reason. The
-- bassist, who nobody has swiped on, is the honest test.
select t('and the blocked person cannot find them again',
         not exists (select 1 from discover(0) where handle = 'tester_d'));
select t('their profile is not readable either',
         not exists (select 1 from profiles where handle = 'tester_d'));
reset role;

-- an untouched pair, so nothing else can mask the block
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000004';
insert into blocks (blocker_id, blocked_id)
  values (auth.uid(), '11110000-0000-0000-0000-000000000001');
reset role;
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
select t('a block by someone you never swiped on still hides them from Discover',
         not exists (select 1 from discover(0) where handle = 'tester_nogps'));
select t('and hides their profile from you',
         not exists (select 1 from profiles where handle = 'tester_nogps'));
reset role;
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000004';
delete from blocks where blocker_id = auth.uid();
reset role;

set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
delete from blocks where blocker_id = auth.uid();
select t('unblocking restores the conversation',
         exists (select 1 from my_conversations() where other_id = '11110000-0000-0000-0000-000000000001'));
reset role;

-- ------------------------------------------------------------
--  6. What one person must never see of another
-- ------------------------------------------------------------
\echo '-- privacy --'
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000003';
select t('a stranger cannot read a conversation they are not in',
         (select count(*) = 0 from messages));
select t('a stranger cannot open a DM with someone they have not matched',
         (select not exists (
            select 1 from conversations c
            join conversation_members m on m.conversation_id = c.id
            where m.user_id = auth.uid())));
select t('the advertisers table stays invisible',
         (select count(*) = 0 from advertisers));
select t('the staff table stays invisible',
         (select count(*) = 0 from staff));
reset role;

\echo '-- done --'
