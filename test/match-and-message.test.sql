-- ============================================================
--  JAMMY — match-and-message.test.sql
--  Two people say yes to each other, and then can talk.
--
--  The bug this file exists for: the match trigger fired on
--  INSERT only. Swiping a second time is an UPDATE, so a mutual
--  yes produced no connection and no conversation, and the
--  message came back "not sent". 13_match_repair.sql fixed it.
--
--  This file used to print sentences for a human to read. It
--  asserts now, so it can actually fail. Run as the OWNER: it
--  steps down to app_user for every check.
-- ============================================================

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

create or replace function t(label text, got boolean) returns text
language sql immutable as $$ select case when got then 'PASS  ' else 'FAIL  ' end || label $$;

-- a trumpet player and a drummer, in the same city
update profiles set city='Boston' where id in
 ('cccc0000-0000-0000-0000-00000000000a','cccc0000-0000-0000-0000-00000000000b');
update profiles set instruments='{Trumpet}', instrument_keys='{trumpet}'
 where id='cccc0000-0000-0000-0000-00000000000a';
update profiles set instruments='{Drums}', instrument_keys='{drums}'
 where id='cccc0000-0000-0000-0000-00000000000b';

-- ------------------------------------------------------------
--  1. The ordinary case: two fresh yeses
-- ------------------------------------------------------------
set role app_user;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000a';
select swipe_and_check('cccc0000-0000-0000-0000-00000000000b','yes');
reset role;

set role app_user;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000b';
select t('a mutual yes connects two people',
         (select matched from swipe_and_check('cccc0000-0000-0000-0000-00000000000a','yes')));
reset role;

select t('and there is exactly one connection', (select count(*) = 1 from connections));
select t('and exactly one conversation',
         (select count(*) = 1 from conversations where kind = 'dm'));

-- ------------------------------------------------------------
--  2. The case that broke: swiping AGAIN, which is an update
--
--  Clear the connection but leave both swipes in place, so the
--  next yes can only arrive as an UPDATE of an existing row.
-- ------------------------------------------------------------
delete from connections; delete from conversation_members; delete from conversations;

set role app_user;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000a';
select t('saying yes again still matches, even as an update',
         (select matched from swipe_and_check('cccc0000-0000-0000-0000-00000000000b','yes')));
select t('and hands back a conversation to write in',
         (select conversation_id is not null
            from swipe_and_check('cccc0000-0000-0000-0000-00000000000b','yes')));
reset role;

select t('the connection came back', (select count(*) = 1 from connections));
select t('and so did the conversation',
         (select count(*) = 1 from conversations where kind = 'dm'));

-- ------------------------------------------------------------
--  3. And a message actually goes through
-- ------------------------------------------------------------
set role app_user;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000a';
insert into messages (conversation_id, sender_id, body)
  select dm_with('cccc0000-0000-0000-0000-00000000000b'), auth.uid(), 'hello from the test';
select t('a message can be sent',
         (select count(*) = 1 from messages where body = 'hello from the test'));
reset role;

set role app_user;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000b';
select t('and the other person sees it',
         (select last_body = 'hello from the test' from my_conversations() limit 1));
select t('and sees them in their connections',
         exists (select 1 from my_connections()
                  where id = 'cccc0000-0000-0000-0000-00000000000a'));
reset role;

-- ------------------------------------------------------------
--  4. And a stranger cannot read any of it
-- ------------------------------------------------------------
set role app_user;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
select t('somebody outside the conversation sees none of it',
         (select count(*) = 0 from messages));
select t('and has no conversations of their own',
         (select count(*) = 0 from my_conversations()));
reset role;

-- ------------------------------------------------------------
--  5. Leaving a connection (25_live_and_leaving.sql)
--
--  The first person to use Jammy had no way out of a connection
--  short of blocking somebody, which is a bad choice to force on
--  anyone who simply played once and did not click.
--
--  The first version of disconnect_from removed the connection
--  and the swipes and left conversation_members alone — so the
--  chat would still have been sitting in both people's lists
--  while the connection was gone, which is exactly what the
--  confirmation screen promises will not happen. These tests are
--  what caught that.
-- ------------------------------------------------------------
set role app_user;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000a';

select t('before disconnecting, they are connected',
         (select count(*) = 1 from connections
           where a_id = least('cccc0000-0000-0000-0000-00000000000a'::uuid,
                              'cccc0000-0000-0000-0000-00000000000b'::uuid)
             and b_id = greatest('cccc0000-0000-0000-0000-00000000000a'::uuid,
                                 'cccc0000-0000-0000-0000-00000000000b'::uuid)));

select t('and each can see the conversation',
         (select count(*) = 1 from my_conversations()));

select disconnect_from('cccc0000-0000-0000-0000-00000000000b');

select t('disconnecting ends the connection',
         (select count(*) = 0 from connections
           where a_id = least('cccc0000-0000-0000-0000-00000000000a'::uuid,
                              'cccc0000-0000-0000-0000-00000000000b'::uuid)
             and b_id = greatest('cccc0000-0000-0000-0000-00000000000a'::uuid,
                                 'cccc0000-0000-0000-0000-00000000000b'::uuid)));

select t('and takes the conversation off my list',
         (select count(*) = 0 from my_conversations()));

select t('and clears the swipes, so we can find each other again',
         (select count(*) = 0 from swipes
           where (from_id = 'cccc0000-0000-0000-0000-00000000000a'
                  and to_id = 'cccc0000-0000-0000-0000-00000000000b')
              or (from_id = 'cccc0000-0000-0000-0000-00000000000b'
                  and to_id = 'cccc0000-0000-0000-0000-00000000000a')));
reset role;

--  and it is mutual: the other person loses it too, rather than
--  being left typing into a thread nobody is reading
set role app_user;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000b';
select t('the other person loses the conversation as well',
         (select count(*) = 0 from my_conversations()));
reset role;
