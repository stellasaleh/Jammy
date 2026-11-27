-- ============================================================
--  JAMMY — permissions.test.sql
--  The two gates a signed-in person has to get through, and the
--  doors that must stay shut.
--
--  Row-level security and table grants are separate things. A
--  missing grant is what broke sign-up with "permission denied
--  for table blocks", and no policy anywhere would have told you.
--  Both are checked here.
--
--  This file used to print numbers for a human to read. Numbers
--  nobody compares against anything cannot fail, so they are
--  assertions now. Run as the OWNER: it steps down to app_user
--  for every check, because the owner walks through both gates.
-- ============================================================

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

create or replace function t(label text, got boolean) returns text
language sql immutable as $$ select case when got then 'PASS  ' else 'FAIL  ' end || label $$;

set role app_user;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';

select t('a signed-in person can read their own profile',
         (select count(*) = 1 from profiles where id = auth.uid()));

with u as (update profiles set city = 'Cambridge' where id = auth.uid() returning city)
select t('and change it', (select city = 'Cambridge' from u));

-- the one that broke sign-up: RLS allowed it, the grant did not
select t('and read the blocks table without being refused',
         (select count(*) >= 0 from blocks));

select t('discover() runs and finds people',
         (select count(*) > 0 from discover(0)));

select t('my_conversations() runs',
         (select count(*) >= 0 from my_conversations()));

-- ------------------------------------------------------------
--  The tables 06_lockdown.sql closed must still be closed.
--  Security on and no policy means the query is allowed and
--  returns nothing. That IS the lock, and it leaks less than an
--  error would, because an error confirms the table is there.
-- ------------------------------------------------------------
select t('advertisers is closed to the app', (select count(*) = 0 from advertisers));
select t('staff is closed to the app',       (select count(*) = 0 from staff));
select t('ads is closed to the app',         (select count(*) = 0 from ads));
select t('ad_daily is closed to the app',    (select count(*) = 0 from ad_daily));
reset role;

-- a venue row now exists, so "0 rows" above means hidden, not absent
insert into advertisers (name, kind, contact_email)
  values ('The Middle East','venue','booking@example.com');
set role app_user;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
select t('and still closed when there IS something to hide',
         (select count(*) = 0 from advertisers));
reset role;
select t('(and the row really is there, so that check meant something)',
         (select count(*) = 1 from advertisers));

-- ------------------------------------------------------------
--  Other people are visible — Discover depends on it — until
--  somebody is blocked, and then they are not, both ways round.
-- ------------------------------------------------------------
set role app_user;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
select t('other profiles are visible, which Discover depends on',
         (select count(*) > 1 from profiles));
select set_config('test.before', (select count(*) from profiles)::text, false);
reset role;

insert into blocks (blocker_id, blocked_id)
  values ('aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000002');

set role app_user;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
select t('blocking someone hides them from the blocker',
         (select count(*) from profiles) = current_setting('test.before')::int - 1);
reset role;

-- the half that was broken until 14_blocking_fix.sql: the blocked
-- person could still see the person who blocked them
set role app_user;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';
select t('and hides the blocker from them, the half that was broken',
         not exists (select 1 from profiles where id = 'aaaaaaaa-0000-0000-0000-000000000001'));
select t('and keeps them out of each other''s Discover',
         not exists (select 1 from discover(0) where id = 'aaaaaaaa-0000-0000-0000-000000000001'));
reset role;

-- ------------------------------------------------------------
--  COLUMNS, not just rows (23_columns.sql)
--
--  Row security says which ROWS you may read; it says nothing
--  about which COLUMNS. Until 23_columns every table was granted
--  to `authenticated` whole, so any member could ask the API for
--  everyone's date of birth and for the stored coordinate — not
--  the distance the app shows, the point itself. The privacy
--  policy promised neither was ever visible. Now that is true.
-- ------------------------------------------------------------
set role app_user;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';

select t('nobody can read anyone''s date of birth, mine included',
         not has_column_privilege('app_user','profiles','birth_date','select'));

select t('nor the stored coordinate',
         not has_column_privilege('app_user','profiles','location','select'));

select t('but the app can still tell whether the server has a location',
         has_column_privilege('app_user','profiles','has_location','select'));

select t('and can still read the things people put on their profile',
         has_column_privilege('app_user','profiles','display_name','select')
     and has_column_privilege('app_user','profiles','city','select')
     and has_column_privilege('app_user','profiles','instruments','select'));

select t('a location can still be written, it just cannot be read back',
         has_column_privilege('app_user','profiles','location','update'));

select t('a birthday cannot be changed after signup',
         not has_column_privilege('app_user','profiles','birth_date','update'));

select t('nobody can award themselves a verified mark',
         not has_column_privilege('app_user','profiles','verified_at','update'));

select t('nor lift their own ban',
         not has_column_privilege('app_user','profiles','is_banned','update'));

select t('and Discover still works, returning miles rather than a point',
         exists (select 1 from discover(500)));
reset role;

-- ------------------------------------------------------------
--  REALTIME, and leaving a connection (25_live_and_leaving.sql)
--
--  The first person to use Jammy found that messages only showed
--  up after a reload. The app's subscription was correct and
--  always had been; Supabase simply never broadcast, because
--  `messages` was never added to its realtime publication.
--  post_comments and post_likes were added back in 04 and
--  messages was missed. Every test passed throughout, because
--  every test fakes the server, and a fake calling a callback is
--  no evidence that Postgres would have.
-- ------------------------------------------------------------
select t('the server broadcasts new messages',
         exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and tablename = 'messages'));

select t('and changes to the chat list',
         exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and tablename = 'conversation_members'));

select t('as it already did for comments and likes',
         (select count(*) from pg_publication_tables
           where pubname = 'supabase_realtime'
             and tablename in ('post_comments','post_likes')) = 2);

select t('there is a way out of a connection that is not a block',
         exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'disconnect_from'));

select t('and an ordinary member is allowed to use it',
         has_function_privilege('app_user', 'public.disconnect_from(uuid)', 'execute'));

-- ------------------------------------------------------------
--  EVERYTHING THAT IS MEANT TO BE LIVE (26_feed_live.sql)
--
--  Hasan posted and it never reached hey's phone. `posts` was not
--  in Supabase's realtime publication — post_likes and
--  post_comments were, from back in 04, but not the table they
--  hang off. So a LIKE arrived live and the post being liked
--  never did.
--
--  That is the third table found missing from this publication:
--  `messages` was the reason chat needed a refresh. Hence one
--  check over the whole set rather than another one-off.
-- ------------------------------------------------------------
select t('a new post reaches other people without a reload',
         exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and tablename = 'posts'));

select t('and every table meant to be live is published',
         (select count(*) from pg_publication_tables
           where pubname = 'supabase_realtime'
             and tablename in ('messages','conversation_members',
                               'posts','post_likes','post_comments')) = 5);

-- the standing check reports by raising, so wrap it in something
-- that returns a boolean this file's t() can take
create or replace function pg_temp.live_check_ok() returns boolean
language plpgsql as $fn$
begin
  perform assert_live_tables_are_published();
  return true;
exception when others then
  return false;
end $fn$;

select t('and the standing check agrees', pg_temp.live_check_ok());

-- ------------------------------------------------------------
--  SEEING WHO YOU BLOCKED (27_my_blocks.sql)
--
--  A catch-22. "read profiles" hides anyone blocked either way,
--  which is right — but it applied on the Blocked accounts
--  screen too, so the app's join to profiles came back empty and
--  the list showed rows with no names on them. You could not see
--  who you had blocked, BECAUSE you had blocked them.
--
--  What must stay true: this tells you about your own actions
--  and says nothing about who has blocked you.
-- ------------------------------------------------------------
set role app_user;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
insert into blocks (blocker_id, blocked_id)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000002')
on conflict do nothing;

select t('the old way gave a blocked person no name',
         (select p.display_name is null
            from blocks b left join profiles p on p.id = b.blocked_id
           where b.blocker_id = auth.uid()
             and b.blocked_id = 'bbbbbbbb-0000-0000-0000-000000000002'));

select t('my_blocks lists them',
         (select count(*) = 1 from my_blocks()
           where blocked_id = 'bbbbbbbb-0000-0000-0000-000000000002'));

select t('and gives their name, which is the whole point',
         (select display_name is not null and length(display_name) > 0
            from my_blocks()
           where blocked_id = 'bbbbbbbb-0000-0000-0000-000000000002'));
reset role;

--  and the rule that must not break: being blocked stays invisible
set role app_user;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';
select t('being blocked still tells you nothing',
         (select count(*) = 0 from my_blocks()));
reset role;

set role app_user;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
delete from blocks where blocker_id = auth.uid()
                     and blocked_id = 'bbbbbbbb-0000-0000-0000-000000000002';
reset role;
