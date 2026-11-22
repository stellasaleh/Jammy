-- ============================================================
--  JAMMY — 19_feed.sql
--  THE FRONT PAGE, FOR REAL. Run after 01–18.
--
--  WHY THIS EXISTS
--  The posts table, feed_page(), likes and comments have all been
--  here since the beginning. Nothing in the app ever called them.
--  So the first screen anyone opens was sixteen invented posts by
--  eight invented musicians, shown to real signed-in people.
--
--  Same shape as the gigs problem: the database half was built and
--  the screen was not.
--
--  Two things are missing from the table, and both of them are
--  what makes a Jammy post different from a status update:
--
--  1. The fields. "Drums · Tuesdays and Sundays · Brighton" is the
--     useful part of looking for a drummer. There was nowhere to
--     put it, so it would have been lost in the prose.
--
--  2. A post with nothing but a picture. `body` was NOT NULL with
--     a minimum of one character, so a photo of the new pedalboard
--     needed a caption to exist at all.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. The fields
-- ------------------------------------------------------------
alter table posts add column if not exists fields jsonb not null default '{}'::jsonb;

-- Keep it small. This is a handful of short labels, not a document,
-- and without a limit it is a place to paste anything.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'posts_fields_small' and conrelid = 'posts'::regclass
  ) then
    alter table posts add constraint posts_fields_small
      check (pg_column_size(fields) <= 2048);
  end if;
end $$;

-- ------------------------------------------------------------
--  2. A picture can be the whole post
--
--  body stays NOT NULL so nothing already written has to change;
--  it is now allowed to be empty, but only when there is something
--  else to look at. An entirely empty post is still refused.
-- ------------------------------------------------------------
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'posts'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) like '%char_length(body)%';
  if c is not null then
    execute format('alter table posts drop constraint %I', c);
  end if;
end $$;

alter table posts alter column body set default '';
update posts set body = '' where body is null;
alter table posts alter column body set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'posts_say_something' and conrelid = 'posts'::regclass
  ) then
    alter table posts add constraint posts_say_something
      check (
        char_length(body) <= 2000
        and (char_length(btrim(body)) > 0
             or media_path is not null
             or track_id is not null
             or fields <> '{}'::jsonb)
      );
  end if;
end $$;

-- ------------------------------------------------------------
--  3. feed_page, carrying the fields
--
--  Postgres will not widen a function in place, so it goes first.
--  SECURITY DEFINER with a pinned search_path, like everything
--  else that has to see past a row rule — here, blocked_between().
-- ------------------------------------------------------------
--  FOUND BY THE TEST. Paging was "older than this timestamp", and two
--  posts written in the same second share one. On a tie the second page
--  skipped every post that shared the boundary time — quietly, with no
--  gap to see. Busy minutes are exactly when it would have happened.
--
--  The cursor is now the time AND the id together, which is unique, so
--  a tie has an order and nothing falls through it.
drop function if exists feed_page(timestamptz, int);
drop function if exists feed_page(timestamptz, int, uuid);

create or replace function feed_page(
  before timestamptz default null,
  page_size int default 20,
  before_id uuid default null
) returns table (
  id uuid, author_id uuid, body text, tag text, track_id uuid, media_path text,
  fields jsonb, created_at timestamptz, like_count int, comment_count int,
  author_name text, author_handle text, author_city text, author_photo text,
  liked_by_me boolean, mine boolean
)
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.author_id, p.body, p.tag, p.track_id, p.media_path,
         p.fields, p.created_at, p.like_count, p.comment_count,
         pr.display_name, pr.handle, pr.city, pr.photo_path,
         exists (select 1 from post_likes l
                  where l.post_id = p.id and l.user_id = (select auth.uid())),
         (p.author_id = (select auth.uid()))
  from posts p
  join profiles pr on pr.id = p.author_id
  where (before is null
         or p.created_at < before
         or (p.created_at = before and before_id is not null and p.id < before_id))
    and not pr.is_banned
    and not blocked_between(p.author_id, (select auth.uid()))
  order by p.created_at desc, p.id desc
  limit least(greatest(page_size, 1), 50);
$$;

-- ------------------------------------------------------------
--  4. Posting, in one call
--
--  Done from the app as a bare insert, a post with a picture was
--  two steps that could half-happen: the file uploaded and the row
--  never written, leaving an orphan in storage and nothing on the
--  screen. The upload still happens first — it has to — but the row
--  is one call that either works or does not.
-- ------------------------------------------------------------
create or replace function add_post(
  p_body text default '',
  p_tag text default null,
  p_fields jsonb default '{}'::jsonb,
  p_media_path text default null,
  p_track_id uuid default null
)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := (select auth.uid());
  id_out uuid;
begin
  if me is null then raise exception 'not signed in'; end if;

  if coalesce(btrim(p_body),'') = ''
     and p_media_path is null and p_track_id is null
     and coalesce(p_fields,'{}'::jsonb) = '{}'::jsonb then
    raise exception 'A post needs something in it — a few words, a picture or a track.';
  end if;

  -- you may only attach a file out of your own folder
  if p_media_path is not null
     and split_part(p_media_path, '/', 1) <> me::text then
    raise exception 'that file is not yours';
  end if;

  insert into posts (author_id, body, tag, fields, media_path, track_id)
  values (me, coalesce(btrim(p_body),''), nullif(btrim(coalesce(p_tag,'')),''),
          coalesce(p_fields,'{}'::jsonb), p_media_path, p_track_id)
  returning id into id_out;

  return id_out;
end $$;

-- ------------------------------------------------------------
--  5. Your own posts, for your profile
-- ------------------------------------------------------------
create or replace function my_posts(limit_n int default 50)
returns table (
  id uuid, body text, tag text, fields jsonb, media_path text, track_id uuid,
  created_at timestamptz, like_count int, comment_count int
)
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.body, p.tag, p.fields, p.media_path, p.track_id,
         p.created_at, p.like_count, p.comment_count
  from posts p
  where p.author_id = (select auth.uid())
  order by p.created_at desc
  limit least(greatest(limit_n, 1), 100);
$$;

-- ------------------------------------------------------------
--  6. Someone else's posts, for their profile
-- ------------------------------------------------------------
create or replace function posts_by(who uuid, limit_n int default 50)
returns table (
  id uuid, body text, tag text, fields jsonb, media_path text, track_id uuid,
  created_at timestamptz, like_count int, comment_count int, liked_by_me boolean
)
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.body, p.tag, p.fields, p.media_path, p.track_id,
         p.created_at, p.like_count, p.comment_count,
         exists (select 1 from post_likes l
                  where l.post_id = p.id and l.user_id = (select auth.uid()))
  from posts p
  join profiles pr on pr.id = p.author_id
  where p.author_id = who
    and not pr.is_banned
    and not blocked_between(who, (select auth.uid()))
  order by p.created_at desc
  limit least(greatest(limit_n, 1), 100);
$$;

-- ------------------------------------------------------------
--  7. Speed
-- ------------------------------------------------------------
create index if not exists posts_author_recent_idx on posts (author_id, created_at desc);

-- ------------------------------------------------------------
--  8. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('add_post','my_posts','posts_by','feed_page');
  if n < 4 then
    raise exception 'Jammy: expected 4 feed functions, found %', n;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_name = 'posts' and column_name = 'fields') then
    raise exception 'Jammy: posts has nowhere to keep what a post is looking for';
  end if;

  raise notice 'Jammy: the feed is real. Nothing on it is invented any more.';
end $$;
