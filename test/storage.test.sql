-- ============================================================
--  JAMMY — storage.test.sql
--  What Jammy will and will not hold.
--
--  Jammy takes uploads from anybody with an account and serves
--  them back from Jammy's own domain. That makes the list of
--  types a bucket accepts the whole defence against two things:
--  somebody using Jammy to host something dangerous, and
--  somebody storing a file that runs in another member's browser.
--
--  Supabase serves a file back under the content type it was
--  stored with, so a stored file can only execute if that type is
--  on the bucket's list. These tests hold that line.
--
--  They also cover the break that sent them here. Tracks for the
--  radio upload to jammy-media as audio, and jammy-media allowed
--  pictures and video only — so every track upload was refused by
--  the real server. Nothing caught it, because every other test
--  replaces storage with a fake that accepts whatever it is given.
--  A test that only ever talks to a fake proves nothing about the
--  thing it is standing in for.
-- ============================================================

\pset format unaligned
\pset tuples_only on

create temp table t (n int generated always as identity, name text, ok boolean, detail text);
create function pg_temp.chk(nm text, cond boolean, detail text default '') returns void
language plpgsql as $$
begin insert into t (name, ok, detail) values (nm, coalesce(cond,false), detail); end $$;

-- ------------------------------------------------------------
--  Nothing that a browser will run, in any bucket
-- ------------------------------------------------------------
select pg_temp.chk('no bucket will serve a web page',
  not exists (select 1 from storage.buckets b, unnest(b.allowed_mime_types) x
               where x = 'text/html'));

select pg_temp.chk('no bucket will serve an SVG, which can carry a script',
  not exists (select 1 from storage.buckets b, unnest(b.allowed_mime_types) x
               where x = 'image/svg+xml'));

select pg_temp.chk('no bucket will serve JavaScript',
  not exists (select 1 from storage.buckets b, unnest(b.allowed_mime_types) x
               where x in ('application/javascript','text/javascript')));

select pg_temp.chk('no bucket accepts a program, an installer or an archive',
  not exists (select 1 from storage.buckets b, unnest(b.allowed_mime_types) x
               where x like 'application/%' and x <> 'application/ogg'));

select pg_temp.chk('no bucket accepts any file type at all',
  not exists (select 1 from storage.buckets
               where allowed_mime_types is null
                  or cardinality(allowed_mime_types) = 0));

-- The same rule as a standing check, which the migration runs too.
-- It reports by raising, so the test is whether calling it is quiet.
do $$
begin
  perform assert_buckets_cannot_run_code();
  insert into t (name, ok, detail)
    values ('and the standing check agrees', true, '');
exception when others then
  insert into t (name, ok, detail)
    values ('and the standing check agrees', false, sqlerrm);
end $$;

-- ------------------------------------------------------------
--  Everything the app really uploads has to be accepted, or a
--  feature is broken against the real server while green here
-- ------------------------------------------------------------
select pg_temp.chk('the radio accepts the audio types the app sends',
  (select allowed_mime_types @> array['audio/mpeg','audio/mp4','audio/wav',
                                      'audio/ogg','audio/webm','audio/flac']
     from storage.buckets where id = 'jammy-media'),
  'this is the one that was broken');

select pg_temp.chk('posts and profiles still take pictures and video',
  (select allowed_mime_types @> array['image/jpeg','image/png','image/webp',
                                      'video/mp4','video/webm']
     from storage.buckets where id = 'jammy-media'));

select pg_temp.chk('jam clips take the audio a phone records',
  (select allowed_mime_types @> array['audio/webm','audio/mp4','audio/mpeg']
     from storage.buckets where id = 'jam-clips'));

-- ------------------------------------------------------------
--  And the two buckets keep the shape the privacy policy
--  describes to people
-- ------------------------------------------------------------
select pg_temp.chk('clips stay private to their conversation',
  (select not public from storage.buckets where id = 'jam-clips'));

select pg_temp.chk('profile and post media stays public, as the policy says',
  (select public from storage.buckets where id = 'jammy-media'));

select pg_temp.chk('nothing larger than 25MB',
  (select file_size_limit <= 26214400 from storage.buckets where id = 'jammy-media'));

-- ------------------------------------------------------------
--  Report
-- ------------------------------------------------------------
\pset tuples_only off
\pset format aligned
select n, case when ok then 'PASS' else 'FAIL' end as result, name, detail from t order by n;

\pset tuples_only on
\pset format unaligned

do $$
begin
  if exists (select 1 from t where not ok) then
    raise exception 'storage.test.sql failed';
  end if;
end $$;
