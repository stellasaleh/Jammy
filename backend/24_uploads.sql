-- ============================================================
--  24_uploads.sql — let the radio accept audio, and keep the
--                   bucket closed to everything that can run
--
--  Two things here. One is a break, one is a hardening.
--
--  THE BREAK. Tracks for the radio are uploaded to `jammy-media`
--  with an audio content type — audio/mpeg, audio/wav, and so on.
--  `jammy-media` allowed images and video and no audio at all, so
--  Supabase rejected every single track upload. Nothing caught it
--  because every automated test replaces storage with a fake that
--  accepts whatever it is handed. It only fails against the real
--  server, which is the worst place to find out.
--
--  THE HARDENING. What a bucket may hold is the whole defence
--  against someone using Jammy to host something dangerous.
--  Supabase serves a file back with the content type it was stored
--  under, so a file can only run in somebody's browser if that type
--  is on this list. These two are the ones that matter and they
--  stay off it permanently:
--
--    text/html          — a page that runs scripts on your domain
--    image/svg+xml      — an image format that can carry <script>
--
--  Nothing here admits application/*, so no executables, no
--  installers, no archives, no PDFs.
-- ============================================================

-- ------------------------------------------------------------
--  jammy-media: public by design. Profile photos, post pictures
--  and video, and tracks on the radio — things meant to be seen
--  and heard by anyone.
-- ------------------------------------------------------------
update storage.buckets
   set allowed_mime_types = array[
         -- pictures
         'image/jpeg','image/png','image/webp','image/gif',
         -- video
         'video/mp4','video/webm','video/quicktime',
         -- audio, for the radio. This is the line that was missing.
         'audio/mpeg','audio/mp4','audio/x-m4a','audio/wav','audio/x-wav',
         'audio/ogg','audio/webm','audio/flac'
       ],
       file_size_limit = 26214400          -- 25 MB, unchanged
 where id = 'jammy-media';

-- ------------------------------------------------------------
--  jam-clips: private, conversation-scoped, audio only. A clip is
--  something you played into a chat, so it needs nothing else.
-- ------------------------------------------------------------
update storage.buckets
   set allowed_mime_types = array[
         'audio/webm','audio/mp4','audio/mpeg','audio/ogg',
         'audio/wav','audio/x-wav','audio/x-m4a','audio/flac'
       ],
       file_size_limit = 10485760          -- 10 MB, unchanged
 where id = 'jam-clips';

-- ------------------------------------------------------------
--  A standing check, so this cannot rot quietly again.
--
--  If either bucket is ever given a type that a browser will
--  execute, this raises instead of letting it through. It runs
--  when the migration is applied, and the test suite runs it too.
-- ------------------------------------------------------------
create or replace function assert_buckets_cannot_run_code()
returns void
language plpgsql
as $$
declare
  bad text;
begin
  select string_agg(b.id || ' allows ' || t, ', ')
    into bad
    from storage.buckets b,
         unnest(b.allowed_mime_types) as t
   where t in ('text/html','image/svg+xml','application/xhtml+xml',
               'text/xml','application/xml','application/javascript',
               'text/javascript','application/pdf')
      or t like 'application/x-%'
      or t = '*/*';

  if bad is not null then
    raise exception
      'A storage bucket would serve runnable content: %', bad;
  end if;

  -- a bucket with no list at all accepts anything, which is worse
  select string_agg(b.id, ', ')
    into bad
    from storage.buckets b
   where b.allowed_mime_types is null
      or cardinality(b.allowed_mime_types) = 0;

  if bad is not null then
    raise exception
      'A storage bucket accepts any file type at all: %', bad;
  end if;
end $$;

select assert_buckets_cannot_run_code();
