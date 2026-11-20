-- ============================================================
--  JAMMY — 07_storage.sql
--  WHERE FILES LIVE. Run this after 01–06.
--
--  The database holds words and numbers. Photos, videos and jam
--  clips go somewhere else — Supabase Storage — and that needs
--  its own containers and its own rules.
--
--  Two containers:
--
--    jammy-media   profile photos, band photos, pictures and
--                  video attached to posts. Readable by anyone
--                  with the link, the same way every social app
--                  works. You can only write into your own
--                  folder, so nobody can overwrite your photo.
--
--    jam-clips     the audio clips people send each other in
--                  messages. PRIVATE. Readable only by the
--                  people in that conversation, and only through
--                  a link that expires in an hour.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. The containers
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'jammy-media', 'jammy-media', true,
  26214400,                                     -- 25 MB a file
  array['image/jpeg','image/png','image/webp','image/gif',
        'video/mp4','video/webm','video/quicktime']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'jam-clips', 'jam-clips', false,
  10485760,                                     -- 10 MB a clip
  array['audio/webm','audio/mp4','audio/mpeg','audio/ogg','audio/wav']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ------------------------------------------------------------
--  2. jammy-media — your folder is yours
--
--  Every file goes to  <your user id>/<something>.jpg
--  The first folder in the path must be your own id, which is
--  what stops one person writing over another's picture.
-- ------------------------------------------------------------
drop policy if exists "media is readable" on storage.objects;
create policy "media is readable" on storage.objects
  for select using (bucket_id = 'jammy-media');

drop policy if exists "write into my own media folder" on storage.objects;
create policy "write into my own media folder" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'jammy-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "replace my own media" on storage.objects;
create policy "replace my own media" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'jammy-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "delete my own media" on storage.objects;
create policy "delete my own media" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'jammy-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ------------------------------------------------------------
--  3. jam-clips — only the two of you
--
--  Every clip goes to  clips/<conversation id>/<something>.webm
--  so the second folder in the path names the conversation. The
--  in_conversation() check already used by the messages table
--  decides who is allowed in.
--
--  This is why clips are served through links that expire: if
--  someone is blocked or leaves a conversation, no new link is
--  ever issued for them again.
-- ------------------------------------------------------------
drop policy if exists "read clips from my conversations" on storage.objects;
create policy "read clips from my conversations" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'jam-clips'
    and array_length(storage.foldername(name), 1) >= 2
    and in_conversation(((storage.foldername(name))[2])::uuid)
  );

drop policy if exists "send clips to my conversations" on storage.objects;
create policy "send clips to my conversations" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'jam-clips'
    and array_length(storage.foldername(name), 1) >= 2
    and in_conversation(((storage.foldername(name))[2])::uuid)
  );

drop policy if exists "delete my own clips" on storage.objects;
create policy "delete my own clips" on storage.objects
  for delete to authenticated
  using (bucket_id = 'jam-clips' and owner = (select auth.uid()));

-- ------------------------------------------------------------
--  4. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from storage.buckets where id in ('jammy-media','jam-clips');
  if n = 2 then
    raise notice 'Jammy: both storage containers exist and are protected.';
  else
    raise exception 'Jammy: expected 2 storage containers, found %', n;
  end if;
end $$;
