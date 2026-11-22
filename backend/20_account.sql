-- ============================================================
--  JAMMY — 20_account.sql
--  DELETING YOUR ACCOUNT, AND TAKING YOUR DATA WITH YOU.
--  Run after 01–19.
--
--  WHY THIS EXISTS
--  "Delete account" cleared the phone and signed you out. The
--  account, the profile, the posts, the messages and the swipes
--  all stayed exactly where they were, and signing in again
--  brought it all back.
--
--  Apple rejects apps that let you create an account and not
--  delete it — guideline 5.1.1(v) — so this would have failed
--  review. It is also simply what the privacy policy already
--  promises, which makes the old button untrue as well as
--  non-compliant.
--
--  WHAT THE POLICY SAYS, AND WHAT THIS DOES
--    "your profile and content are removed"           -> gone
--    "messages you sent may remain visible to the
--     person who received them, in the same way a
--     sent text does"                                 -> kept, with
--                                                        no sender
--    "See your data ... Download my data"             -> export_my_data()
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. One thing would have blocked the delete outright
--
--  ad_requests.reviewed_by points at profiles with NO ACTION, so
--  deleting anyone who had ever reviewed an advertiser request
--  would fail on a foreign key, with an error nobody could act
--  on. It is a record of who reviewed something, not of who they
--  are, so it loosens to set null like every other such column.
-- ------------------------------------------------------------
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'ad_requests'::regclass and contype = 'f'
     and confrelid = 'profiles'::regclass and confdeltype = 'a';
  if c is not null then
    execute format('alter table ad_requests drop constraint %I', c);
    alter table ad_requests
      add constraint ad_requests_reviewed_by_fkey
      foreign key (reviewed_by) references profiles on delete set null;
    raise notice 'Jammy: a reviewed ad request no longer blocks deleting an account.';
  end if;
end $$;

-- ------------------------------------------------------------
--  2. Take your data with you
--
--  Everything Jammy holds about you, as one JSON document. This
--  is the "Download my data" the privacy policy promises, and it
--  is also what makes deletion a fair choice rather than a cliff.
--
--  It returns only the caller's own rows. There is no argument,
--  deliberately: a function that took a user id would be one
--  mistake away from handing out somebody else's life.
-- ------------------------------------------------------------
create or replace function export_my_data()
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  me uuid := (select auth.uid());
  out jsonb;
begin
  if me is null then raise exception 'not signed in'; end if;

  select jsonb_build_object(
    'exported_at', now(),
    'what_this_is', 'Everything Jammy holds about your account. '
                 || 'Distances others see are worked out from your location; '
                 || 'the coordinates below are rounded to about a mile, which '
                 || 'is how they were stored.',
    'profile', (
      select to_jsonb(p) - 'location' ||
             jsonb_build_object('approximate_location',
               case when p.location is null then null
                    else jsonb_build_object(
                      'latitude',  round(st_y(p.location::geometry)::numeric, 2),
                      'longitude', round(st_x(p.location::geometry)::numeric, 2)) end)
      from profiles p where p.id = me),
    'posts',    coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select id, body, tag, fields, media_path, created_at,
                         like_count, comment_count
                  from posts where author_id = me order by created_at) x), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select id, post_id, body, created_at
                  from post_comments where author_id = me order by created_at) x), '[]'::jsonb),
    'messages_you_sent', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select id, conversation_id, body, created_at
                  from messages where sender_id = me order by created_at) x), '[]'::jsonb),
    'recordings', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select id, title, audio_path, created_at
                  from tracks where owner_id = me order by created_at) x), '[]'::jsonb),
    'bands',    coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select b.id, b.name, b.city, m.role_label, m.is_admin, m.joined_at
                  from band_members m join bands b on b.id = m.band_id
                  where m.user_id = me order by m.joined_at) x), '[]'::jsonb),
    'connections', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select c.id, c.created_at,
                         case when c.a_id = me then c.b_id else c.a_id end as with_user
                  from connections c where c.a_id = me or c.b_id = me
                  order by c.created_at) x), '[]'::jsonb),
    'people_you_passed_or_liked', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select to_id, direction, created_at
                  from swipes where from_id = me order by created_at) x), '[]'::jsonb),
    'people_you_blocked', coalesce((select jsonb_agg(to_jsonb(x)) from (
                  select blocked_id, created_at
                  from blocks where blocker_id = me order by created_at) x), '[]'::jsonb)
  ) into out;

  return out;
end $$;

comment on function export_my_data is
  'Everything Jammy holds about the caller, and nobody else. Takes no argument on purpose.';

-- ------------------------------------------------------------
--  3. Deleting the account
--
--  Most of this happens by itself: nearly everything that points
--  at a profile is ON DELETE CASCADE, so removing the profile row
--  takes the posts, comments, likes, swipes, connections, band
--  memberships, tracks and device tokens with it.
--
--  Three things are handled by hand.
--
--  Messages stay. The column is ON DELETE SET NULL, which is what
--  the privacy policy describes: a message you sent remains in the
--  other person's conversation the way a sent text does, with no
--  profile behind it any more. This is deliberate, not an
--  oversight — the alternative is quietly editing somebody else's
--  conversation after they have read it.
--
--  Reports made ABOUT you cascade, which would let anyone delete
--  the record of their own behaviour and sign up again clean. The
--  policy says safety records are kept for twelve months, so they
--  are detached from the profile and kept, with no name attached.
--
--  The auth account itself goes last, so that nothing is half
--  deleted if it fails.
-- ------------------------------------------------------------
create or replace function delete_my_account(confirm text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  me       uuid := (select auth.uid());
  handle_was text;
  kept     int := 0;
  auth_gone boolean := false;
begin
  if me is null then raise exception 'not signed in'; end if;

  -- Deleting is not undoable, so it is not a thing you can do by
  -- tapping twice in the wrong place.
  if lower(coalesce(btrim(confirm),'')) <> 'delete' then
    raise exception 'To delete your account, type the word delete.';
  end if;

  select handle into handle_was from profiles where id = me;

  -- safety records about this person outlive the account
  update reports set target_user = null
   where target_user = me;
  get diagnostics kept = row_count;

  update reports set reporter_id = null where reporter_id = me;

  -- the profile, and everything that hangs off it
  delete from profiles where id = me;

  -- and the sign-in itself. If this database cannot reach the auth
  -- table, the account's data is already gone and we say so rather
  -- than pretending the whole thing worked.
  begin
    delete from auth.users where id = me;
    auth_gone := true;
  exception when others then
    auth_gone := false;
  end;

  return jsonb_build_object(
    'deleted', true,
    'handle', handle_was,
    'sign_in_removed', auth_gone,
    'safety_records_kept', kept,
    'note', 'Messages you sent stay in the other person''s conversation, '
         || 'with no profile attached, as the privacy policy describes.');
end $$;

comment on function delete_my_account is
  'Permanent. Requires the word "delete". Keeps sent messages and safety records, per the privacy policy.';

-- ------------------------------------------------------------
--  4. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('delete_my_account','export_my_data');
  if n <> 2 then
    raise exception 'Jammy: expected 2 account functions, found %', n;
  end if;

  if exists (
    select 1 from pg_constraint
    where conrelid = 'ad_requests'::regclass and contype = 'f'
      and confrelid = 'profiles'::regclass and confdeltype = 'a') then
    raise exception 'Jammy: a reviewed ad request would still block deleting an account';
  end if;

  raise notice 'Jammy: an account can be exported and deleted, which Apple requires.';
end $$;
