\pset tuples_only on
\pset format unaligned
delete from band_events; delete from band_members; delete from bands;

create or replace function t(label text, got boolean) returns text
language sql immutable as $$ select case when got then 'PASS  ' else 'FAIL  ' end || label $$;

-- Stella starts a band
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
select t('starting a band works',
  (select create_band('The Flaming Weirdos','Boston','{Jazz,Funk}','Loud.','{Trumpet}','Horns') is not null));
select t('and you are in it, as an admin',
  (select i_am_admin and member_count = 1 from my_bands()));
select t('with a group chat already made',
  exists (select 1 from conversations where kind='band'));
reset role;

-- the drummer asks to join, and is let in
--
-- CHANGED by 17_gigs.sql. Joining used to be something you did to
-- a band; now it is something you ask a band, because band pages
-- became reachable by strangers and a member can read the
-- rehearsal address.
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
select t('asking to join does not let you in',
  join_band((select id from bands limit 1), '{Drums}', 'Drums') = false);
select t('and you are still outside',
  (select count(*) = 0 from my_bands()));
reset role;

-- the founder approves
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
select t('the founder sees the request',
  (select count(*) = 1 from band_requests()));
select t('and approving it works',
  answer_band_request((select request_id from band_requests() limit 1), true));
reset role;

set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
select t('and now sees it in their bands',
  (select count(*) = 1 from my_bands()));
reset role;

set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
select t('the roster shows both, and what each plays',
  (select count(*) = 2 from band_roster((select id from bands limit 1)))
  and exists (select 1 from band_roster((select id from bands limit 1))
              where 'Drums' = any(instruments)));

-- the diary
select t('a practice can be scheduled',
  add_band_event((select id from bands limit 1),'practice', now() + interval '2 days',
                 'My flat','14 Beacon St','bring the PA') is not null);
select t('a gig can be scheduled',
  add_band_event((select id from bands limit 1),'gig', now() + interval '5 days',
                 'Lilypad','1353 Cambridge St','doors 8') is not null);
select t('a gig is public by default',
  (select visibility='public' from band_schedule((select id from bands limit 1)) where kind='gig'));
select t('a practice is members-only by default',
  (select visibility='members' from band_schedule((select id from bands limit 1)) where kind='practice'));

-- the rule that matters
do $$ begin
  perform add_band_event((select id from bands limit 1),'practice', now() + interval '3 days',
                         'My flat','14 Beacon St', null, null, 'public');
  raise warning 'FAIL  a practice was allowed to be public';
exception when others then
  raise notice 'PASS  a practice cannot be made public (%)' , left(sqlerrm, 48);
end $$;

select t('the band sees the practice address',
  (select address is not null from band_schedule((select id from bands limit 1)) where kind='practice'));
select t('and my_schedule lists what is coming up',
  (select count(*) = 2 from my_schedule()));
reset role;

-- an outsider
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000003';
select t('a stranger sees the public gig',
  exists (select 1 from band_schedule((select id from bands limit 1)) where kind='gig'));
select t('a stranger does NOT see the practice',
  not exists (select 1 from band_schedule((select id from bands limit 1)) where kind='practice'));
select t('and gets no address even for the gig',
  (select address is null from band_schedule((select id from bands limit 1)) where kind='gig'));
do $$ begin
  perform add_band_event((select id from bands limit 1),'gig', now() + interval '9 days','Somewhere');
  raise warning 'FAIL  a stranger scheduled a date for a band they are not in';
exception when others then
  raise notice 'PASS  a stranger cannot schedule anything for the band';
end $$;
reset role;

-- leaving
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000001';
select t('the admin can leave', leave_band((select id from bands limit 1)));
reset role;
set role app_user;
set request.jwt.claim.sub = '11110000-0000-0000-0000-000000000002';
select t('and the band is not left without an admin',
  (select i_am_admin from my_bands()));
select leave_band((select id from bands limit 1));
select t('the last member out removes the band', (select count(*)=0 from bands));
reset role;
