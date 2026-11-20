-- ============================================================
--  JAMMY — seed.sql
--  The cast the older tests expect. Run as the OWNER, after
--  reset.sql, before any test that does not make its own people.
--
--  These tests used to rely on journey.test.sql having run first
--  and left its people behind. That made them pass or fail
--  depending on what ran before them, which is not a test. The
--  same four names and the same four ids live here now, so each
--  test starts from the same place whatever ran before it.
-- ============================================================

insert into auth.users (id) values
  ('11110000-0000-0000-0000-000000000001'),
  ('11110000-0000-0000-0000-000000000002'),
  ('11110000-0000-0000-0000-000000000003'),
  ('11110000-0000-0000-0000-000000000004'),
  ('aaaaaaaa-0000-0000-0000-000000000001'),
  ('bbbbbbbb-0000-0000-0000-000000000002'),
  ('cccc0000-0000-0000-0000-00000000000a'),
  ('cccc0000-0000-0000-0000-00000000000b')
on conflict do nothing;

insert into profiles (id, handle, display_name, city, instruments, genres,
                      looking_for, looking_for_instruments, rehearsal_days,
                      birth_date, terms_agreed_at, remote_ok, location)
values
  -- the two who find each other
  ('11110000-0000-0000-0000-000000000001','tester_t','Trumpet Tester','Boston',
   '{Trumpet}','{Jazz,Funk}','Form a band','{Drums}','{Wed}','2000-03-01',now(),false,
   'SRID=4326;POINT(-71.06 42.36)'),
  ('11110000-0000-0000-0000-000000000002','tester_d','Drum Tester','Boston',
   '{Drums}','{Jazz}','Join a band','{Trumpet}','{Wed}','1996-05-05',now(),false,
   'SRID=4326;POINT(-71.09 42.37)'),

  -- someone genuinely far away, and someone with no location at all
  ('11110000-0000-0000-0000-000000000003','tester_far','Far Drummer','Seattle',
   '{Drums}','{Jazz}',null,'{}','{}','1990-01-01',now(),false,
   'SRID=4326;POINT(-122.33 47.61)'),
  ('11110000-0000-0000-0000-000000000004','tester_nogps','No GPS Bassist','Boston',
   '{Bass}','{Jazz}',null,'{}','{}','1994-01-01',now(),false, null),

  -- spare accounts the permissions tests reach for
  ('aaaaaaaa-0000-0000-0000-000000000001','tester_a','Ana Tester','Boston',
   '{Bass}','{Indie}',null,'{Drums}','{}','1997-11-05',now(),false,
   'SRID=4326;POINT(-71.065 42.362)'),
  ('bbbbbbbb-0000-0000-0000-000000000002','tester_b','Bo Tester','Boston',
   '{Drums}','{Indie}',null,'{Bass}','{}','1996-03-30',now(),false,
   'SRID=4326;POINT(-71.066 42.361)'),
  ('cccc0000-0000-0000-0000-00000000000a','tester_c','Cass Tester','Boston',
   '{Violin}','{Folk}',null,'{Guitar}','{}','1995-09-09',now(),false,
   'SRID=4326;POINT(-71.067 42.363)'),
  ('cccc0000-0000-0000-0000-00000000000b','tester_e','Dee Tester','Boston',
   '{Guitar}','{Folk}',null,'{Violin}','{}','1994-12-12',now(),false,
   'SRID=4326;POINT(-71.068 42.364)')
on conflict (id) do nothing;
