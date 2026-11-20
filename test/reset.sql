-- ============================================================
--  JAMMY — reset.sql
--  Empty the test database. Run as the OWNER, before each test.
--
--  Why this file exists: the tests used to clear up after
--  themselves with `delete from bands` as an ordinary user. There
--  is no delete policy on bands, so those deletes removed nothing
--  and said nothing — row-level security refuses in silence. Every
--  run inherited the last one's data, and tests started failing
--  for reasons that had nothing to do with the code.
--
--  Clearing up is the owner's job. Checking the rules is the
--  user's. Keeping those apart is the whole point.
-- ============================================================

truncate
  messages, conversation_members, conversations,
  connections, swipes, blocks, reports,
  post_likes, post_comments, posts,
  plays, play_daily, play_dedupe, tracks,
  band_join_requests, event_tasks, event_rsvps, band_media,
  band_events, band_members, bands,
  rate_counters, notifications_sent, device_tokens,
  profiles
cascade;

delete from auth.users;
