\pset tuples_only on
\pset format unaligned
delete from swipes; delete from connections; delete from conversation_members; delete from conversations; delete from blocks;

create or replace function t(label text, got boolean) returns text
language sql immutable as $$ select case when got then 'PASS  ' else 'FAIL  ' end || label $$;

-- the drummer asks the trumpet player
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
select t('asking does not connect you by itself',
         not (select matched from swipe_and_check('11110000-0000-0000-0000-000000000001','yes')));
select t('and the asker sees nothing in their own requests',
         (select count(*) = 0 from incoming_requests()));
reset role;

set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
select t('the person asked SEES the request',
         exists (select 1 from incoming_requests() where handle = 'tester_d'));
select t('with what they play',
         (select 'Drums' = any(instruments) from incoming_requests() where handle='tester_d'));
select t('and whether they need what you play',
         (select 'Trumpet' = any(they_need_me) from incoming_requests() where handle='tester_d'));
select t('the count is right', incoming_request_count() = 1);

-- accepting
select t('saying yes back connects you',
         (select matched from swipe_and_check('11110000-0000-0000-0000-000000000002','yes')));
select t('and the request disappears once answered',
         (select count(*) = 0 from incoming_requests()));
reset role;

-- declining
delete from swipes; delete from connections; delete from conversation_members; delete from conversations;
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
select swipe_and_check('11110000-0000-0000-0000-000000000001','yes');
reset role;
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
select t('a pending request is there before you answer',
         incoming_request_count() = 1);
select swipe_and_check('11110000-0000-0000-0000-000000000002','no');
select t('declining clears it too, without connecting you',
         incoming_request_count() = 0 and (select count(*) = 0 from connections));
reset role;

-- a blocked person cannot queue up in your requests
delete from swipes; delete from blocks;
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
select swipe_and_check('11110000-0000-0000-0000-000000000001','yes');
reset role;
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
insert into blocks (blocker_id, blocked_id) values (auth.uid(), '11110000-0000-0000-0000-000000000002');
select t('someone you blocked cannot appear in your requests',
         (select count(*) = 0 from incoming_requests()));
delete from blocks where blocker_id = auth.uid();
reset role;
