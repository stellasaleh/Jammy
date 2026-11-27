-- ============================================================
--  26_feed_live.sql — let a new post reach other people
--
--  Hasan posted. On hey's phone, nothing appeared.
--
--  Two reasons, and this file is the server half.
--
--  Back in 04, post_comments and post_likes were added to
--  Supabase's realtime publication, and `posts` itself was not.
--  So a LIKE on a post arrived live, and a COMMENT arrived live,
--  but the post those things were happening to never did. Nobody
--  noticed because both of us only ever looked at a feed we had
--  just loaded.
--
--  This is the third time this exact gap has bitten: `messages`
--  was missing from the same publication until 25, which is why
--  chat needed a refresh. A table whose rows other people are
--  meant to see as they appear has to be published, and three of
--  them were not.
--
--  So that it stops happening, there is a check at the bottom
--  that names every table the app expects to be live and fails
--  if one is missing.
-- ============================================================

do $$
begin
  alter publication supabase_realtime add table posts;
exception when duplicate_object then null;
end $$;

-- ------------------------------------------------------------
--  A standing check, run here and by the test suite.
--
--  Being on this list means: when a row appears, somebody else's
--  screen is supposed to change without them doing anything.
-- ------------------------------------------------------------
create or replace function assert_live_tables_are_published()
returns void
language plpgsql
as $$
declare
  missing text;
begin
  select string_agg(t, ', ' order by t)
    into missing
    from unnest(array[
      'messages',              -- a reply in a conversation
      'conversation_members',  -- a conversation starting or ending
      'posts',                 -- somebody posting
      'post_likes',            -- somebody liking a post
      'post_comments'          -- somebody commenting
    ]) as t
   where not exists (
     select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and tablename = t
   );

  if missing is not null then
    raise exception
      'These tables are meant to update other people''s screens live, but Supabase is not publishing them: %', missing;
  end if;
end $$;

select assert_live_tables_are_published();
