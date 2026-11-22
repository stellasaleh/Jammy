-- ============================================================
--  JAMMY — feed.test.sql
--  The front page, which until now was sixteen invented posts.
--
--  Run as an ordinary signed-in user, never as the owner.
--    psql -d jammy -U app_user -f test/feed.test.sql
-- ============================================================

\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on

create temp table t (n int generated always as identity, name text, ok boolean, detail text);
create function pg_temp.chk(nm text, cond boolean, detail text default '') returns void
language plpgsql as $$
begin insert into t (name, ok, detail) values (nm, coalesce(cond,false), detail); end $$;
create function pg_temp.be(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', u::text, false); end $$;

do $$
declare a uuid; b uuid; c uuid;
begin
  a := gen_random_uuid(); b := gen_random_uuid(); c := gen_random_uuid();
  perform set_config('test.ana',  a::text, false);
  perform set_config('test.bo',   b::text, false);
  perform set_config('test.cass', c::text, false);
  insert into auth.users (id) values (a),(b),(c);

  perform pg_temp.be(a);
  insert into profiles (id, display_name, handle, city, instruments, genres, birth_date)
  values (a,'Ana','f_ana_'||substr(a::text,1,8),'Boston','{Bass}','{Indie}','1997-01-01');
  perform pg_temp.be(b);
  insert into profiles (id, display_name, handle, city, instruments, genres, birth_date)
  values (b,'Bo','f_bo_'||substr(b::text,1,8),'Boston','{Drums}','{Indie}','1996-01-01');
  perform pg_temp.be(c);
  insert into profiles (id, display_name, handle, city, instruments, genres, birth_date)
  values (c,'Cass','f_cass_'||substr(c::text,1,8),'Boston','{Keys}','{Jazz}','1995-01-01');
end $$;

-- ------------------------------------------------------------
--  1. Posting
-- ------------------------------------------------------------
do $$
declare p uuid; r record;
begin
  perform pg_temp.be(current_setting('test.ana')::uuid);

  p := add_post('Looking for a drummer. Tuesdays, Brighton.', 'looking',
                '{"instrument":"Drums","when":"Tue evenings","where":"Brighton"}'::jsonb);
  perform set_config('test.post', p::text, false);
  perform pg_temp.chk('a post can be written', p is not null);

  select * into r from feed_page() where id = p;
  perform pg_temp.chk('and comes back on the feed', r.id is not null);
  perform pg_temp.chk('with the name of whoever wrote it', r.author_name = 'Ana', coalesce(r.author_name,'null'));
  perform pg_temp.chk('and what they are looking for, not just the prose',
    r.fields ->> 'instrument' = 'Drums', coalesce(r.fields::text,'null'));
  perform pg_temp.chk('and it knows the post is yours', r.mine);
  perform pg_temp.chk('and starts with no likes', r.like_count = 0, r.like_count::text);
end $$;

-- ------------------------------------------------------------
--  2. An empty post is not a post
-- ------------------------------------------------------------
do $$
declare refused boolean := false; p uuid;
begin
  perform pg_temp.be(current_setting('test.ana')::uuid);
  begin
    p := add_post('', null, '{}'::jsonb);
  exception when others then refused := true;
  end;
  perform pg_temp.chk('a post with nothing in it is refused', refused);

  -- but a picture on its own IS a post
  p := add_post('', 'note', '{}'::jsonb,
                current_setting('test.ana') || '/posts/pedalboard.jpg');
  perform pg_temp.chk('a photo with no caption is still a post', p is not null);
end $$;

-- ------------------------------------------------------------
--  3. You cannot attach somebody else's file
--
--  The storage rule already stops you writing into another
--  person's folder. This stops you pointing at what is already
--  in it.
-- ------------------------------------------------------------
do $$
declare refused boolean := false; p uuid;
begin
  perform pg_temp.be(current_setting('test.bo')::uuid);
  begin
    p := add_post('nice board', 'note', '{}'::jsonb,
                  current_setting('test.ana') || '/posts/pedalboard.jpg');
  exception when others then refused := true;
  end;
  perform pg_temp.chk('you cannot attach a file out of someone else''s folder', refused);
end $$;

-- ------------------------------------------------------------
--  4. Likes
-- ------------------------------------------------------------
do $$
declare r record; n int;
begin
  perform pg_temp.be(current_setting('test.bo')::uuid);
  perform toggle_like(current_setting('test.post')::uuid);

  select * into r from feed_page() where id = current_setting('test.post')::uuid;
  perform pg_temp.chk('a like counts', r.like_count = 1, r.like_count::text);
  perform pg_temp.chk('and the person who liked it is told so', r.liked_by_me);

  -- and it is not everyone's like
  perform pg_temp.be(current_setting('test.cass')::uuid);
  select * into r from feed_page() where id = current_setting('test.post')::uuid;
  perform pg_temp.chk('somebody else has not liked it', r.liked_by_me = false);
  perform pg_temp.chk('but sees the same count', r.like_count = 1, r.like_count::text);

  -- liking twice un-likes
  perform pg_temp.be(current_setting('test.bo')::uuid);
  perform toggle_like(current_setting('test.post')::uuid);
  select * into r from feed_page() where id = current_setting('test.post')::uuid;
  perform pg_temp.chk('tapping again takes it back', r.like_count = 0 and not r.liked_by_me,
                      r.like_count::text);
end $$;

-- ------------------------------------------------------------
--  5. Comments
-- ------------------------------------------------------------
do $$
declare r record; n int;
begin
  perform pg_temp.be(current_setting('test.bo')::uuid);
  insert into post_comments (post_id, author_id, body)
  values (current_setting('test.post')::uuid, (select auth.uid()), 'I play Tuesdays');

  select * into r from feed_page() where id = current_setting('test.post')::uuid;
  perform pg_temp.chk('a comment counts on the card', r.comment_count = 1, r.comment_count::text);

  select count(*) into n from comments_page(current_setting('test.post')::uuid);
  perform pg_temp.chk('and reads back', n = 1, n::text);
end $$;

-- ------------------------------------------------------------
--  6. Blocking. THE ONE THAT MATTERS: the feed is the screen
--     where someone you blocked would otherwise keep appearing.
-- ------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.cass')::uuid);
  insert into blocks (blocker_id, blocked_id)
  values ((select auth.uid()), current_setting('test.ana')::uuid);

  select count(*) into n from feed_page()
   where author_id = current_setting('test.ana')::uuid;
  perform pg_temp.chk('someone you blocked is off your feed', n = 0, n::text);

  -- and the half that was broken everywhere else: the other direction
  perform pg_temp.be(current_setting('test.ana')::uuid);
  perform add_post('still here', 'note', '{}'::jsonb);
  perform pg_temp.be(current_setting('test.cass')::uuid);
  select count(*) into n from feed_page()
   where author_id = current_setting('test.ana')::uuid;
  perform pg_temp.chk('including anything they post afterwards', n = 0, n::text);

  perform pg_temp.be(current_setting('test.ana')::uuid);
  select count(*) into n from feed_page()
   where author_id = current_setting('test.cass')::uuid;
  perform pg_temp.chk('and the blocked person''s feed loses them too', n = 0, n::text);

  delete from blocks where blocker_id = current_setting('test.cass')::uuid;
end $$;

-- ------------------------------------------------------------
--  7. Deleting your own, and only your own
-- ------------------------------------------------------------
do $$
declare n int; p uuid;
begin
  perform pg_temp.be(current_setting('test.bo')::uuid);
  delete from posts where id = current_setting('test.post')::uuid;
  select count(*) into n from posts where id = current_setting('test.post')::uuid;
  perform pg_temp.chk('you cannot delete somebody else''s post', n = 1, n::text);

  perform pg_temp.be(current_setting('test.ana')::uuid);
  delete from posts where id = current_setting('test.post')::uuid;
  select count(*) into n from posts where id = current_setting('test.post')::uuid;
  perform pg_temp.chk('and can delete your own', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  8. Paging, so the feed does not fetch everything forever
-- ------------------------------------------------------------
do $$
declare n int; cut timestamptz; cut_id uuid;
begin
  perform pg_temp.be(current_setting('test.ana')::uuid);
  for n in 1..7 loop
    perform add_post('post number ' || n, 'note', '{}'::jsonb);
  end loop;

  select count(*) into n from feed_page(null, 3);
  perform pg_temp.chk('a page is the size you asked for', n = 3, n::text);

  -- the cursor is the last row of the page, time AND id
  select created_at, id into cut, cut_id
    from feed_page(null,3) order by created_at desc, id desc limit 1 offset 2;
  select count(*) into n from feed_page(cut, 3, cut_id);
  perform pg_temp.chk('and the next page carries on from it', n = 3, n::text);

  -- nothing is seen twice, and nothing is skipped: all nine, once each
  select count(distinct id) into n from (
    select id from feed_page(null,3)
    union all
    select id from feed_page(cut, 3, cut_id)
  ) s;
  perform pg_temp.chk('with no post repeated across the two pages', n = 6, n::text);

  select count(*) into n from feed_page(null, 500);
  perform pg_temp.chk('and nobody can ask for the whole table', n <= 50, n::text);
end $$;

-- ------------------------------------------------------------
--  9. Your own posts, and somebody else's
-- ------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.be(current_setting('test.ana')::uuid);
  select count(*) into n from my_posts();
  perform pg_temp.chk('your profile can list your posts', n >= 7, n::text);

  perform pg_temp.be(current_setting('test.bo')::uuid);
  select count(*) into n from posts_by(current_setting('test.ana')::uuid);
  perform pg_temp.chk('and somebody else can read them from your profile', n >= 7, n::text);

  select count(*) into n from my_posts();
  perform pg_temp.chk('but my_posts is only ever yours', n = 0, n::text);
end $$;

-- ------------------------------------------------------------
--  Results
-- ------------------------------------------------------------
\pset tuples_only off
\pset format aligned
select n, case when ok then 'PASS' else 'FAIL' end as result, name, detail from t order by n;

\pset tuples_only on
\pset format unaligned
select case when count(*) filter (where not ok) = 0
            then E'\n' || count(*) || ' checks, all passed.'
            else E'\n' || count(*) filter (where not ok) || ' FAILED of ' || count(*) end
from t;

do $$
begin
  if exists (select 1 from t where not ok) then
    raise exception 'feed.test.sql failed';
  end if;
end $$;
