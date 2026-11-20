-- ============================================================
--  JAMMY — 04_likes_comments.sql
--  Run AFTER 01, 02 and 03.
--
--  Makes likes and comments real: paged, counted, rate-limited,
--  live, and safe to delete.
-- ============================================================


-- ------------------------------------------------------------
--  Indexes. Without these, every comment sheet opens with a
--  sequential scan of the whole table.
-- ------------------------------------------------------------
create index if not exists post_comments_post_idx
  on post_comments (post_id, created_at desc);
create index if not exists post_comments_author_idx
  on post_comments (author_id);
create index if not exists post_likes_user_idx
  on post_likes (user_id);


-- ------------------------------------------------------------
--  COMMENTS, paged by cursor
--  Returns the comment plus its author, blocked users filtered out
--  in the database so the client never has to.
-- ------------------------------------------------------------
create or replace function comments_page(
  post uuid,
  before timestamptz default null,
  page_size int default 30
) returns table (
  id uuid,
  post_id uuid,
  author_id uuid,
  body text,
  created_at timestamptz,
  author_name text,
  author_handle text,
  author_photo text,
  is_mine boolean
) language sql stable as $$
  select c.id, c.post_id, c.author_id, c.body, c.created_at,
         p.display_name, p.handle, p.photo_path,
         (c.author_id = (select auth.uid())) as is_mine
  from post_comments c
  join profiles p on p.id = c.author_id
  where c.post_id = post
    and (before is null or c.created_at < before)
    and not p.is_banned
    and not exists (
      select 1 from blocks b
      where (b.blocker_id = c.author_id and b.blocked_id = (select auth.uid()))
         or (b.blocker_id = (select auth.uid()) and b.blocked_id = c.author_id))
  order by c.created_at desc
  limit least(page_size, 100);
$$;


-- ------------------------------------------------------------
--  LIKES
--  One row per person per post, so a double-tap can never
--  double-count. The counter on the post is maintained by the
--  trigger installed in 03_scale.sql.
-- ------------------------------------------------------------
create or replace function toggle_like(post uuid)
returns table (liked boolean, like_count int)
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := auth.uid();
  existed boolean;
  n int;
begin
  if me is null then
    raise exception 'not signed in';
  end if;

  delete from post_likes where post_id = post and user_id = me;
  existed := found;

  if not existed then
    if not check_rate('like', 300, 60) then
      raise exception 'Slow down — too many likes in a short time.';
    end if;
    insert into post_likes (post_id, user_id) values (post, me)
    on conflict do nothing;
  end if;

  select p.like_count into n from posts p where p.id = post;
  return query select (not existed), coalesce(n, 0);
end $$;


-- ------------------------------------------------------------
--  Comment rate limit. Comments are the cheapest abuse vector
--  on any social app — one script can post thousands a minute.
-- ------------------------------------------------------------
create or replace function guard_comment_rate() returns trigger
  language plpgsql security definer set search_path = public, extensions as $$
begin
  if not check_rate('comment', 60, 10) then
    raise exception 'Slow down — too many comments. Try again shortly.';
  end if;
  return new;
end $$;

drop trigger if exists post_comments_rate on post_comments;
create trigger post_comments_rate before insert on post_comments
for each row execute function guard_comment_rate();


-- ------------------------------------------------------------
--  Deleting
--  You can delete your own comment, and the post's author can
--  delete any comment on their own post. That second rule is
--  what lets people keep their own threads clean without
--  waiting on moderation.
-- ------------------------------------------------------------
drop policy if exists "comment as me" on post_comments;

drop policy if exists "read comments" on post_comments;
create policy "read comments" on post_comments for select to authenticated using (true);

drop policy if exists "write own comments" on post_comments;
create policy "write own comments" on post_comments for insert to authenticated
  with check (author_id = (select auth.uid()));

drop policy if exists "delete own comments or on my post" on post_comments;
create policy "delete own comments or on my post" on post_comments for delete to authenticated
  using (
    author_id = (select auth.uid())
    or exists (select 1 from posts p
               where p.id = post_comments.post_id and p.author_id = (select auth.uid()))
  );

-- editing a comment after people have replied to it is a misinformation
-- vector and nobody misses it. Delete and repost instead.
-- (no update policy is deliberate)


-- ------------------------------------------------------------
--  Realtime, so an open comment sheet updates itself
-- ------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table post_comments;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table post_likes;
exception when duplicate_object then null;
end $$;


-- ------------------------------------------------------------
--  Reporting a comment, not just a post or a user
-- ------------------------------------------------------------
alter table reports add column if not exists target_comment uuid references post_comments on delete cascade;
create index if not exists reports_comment_idx on reports (target_comment) where target_comment is not null;
