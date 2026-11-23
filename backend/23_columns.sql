-- ============================================================
--  23_columns.sql — stop handing out birthdays and coordinates
--
--  Row-level security decides which ROWS you may read. It says
--  nothing about which COLUMNS. Every table in Jammy was granted
--  to `authenticated` whole, so any signed-in member could ask
--  the API for every other member's `birth_date` and for the
--  stored `location` point — not the computed distance the app
--  displays, but the coordinate itself.
--
--  Proved before writing this, as an ordinary user:
--
--    select display_name, birth_date from profiles;
--     Drum Tester    | 1996-05-05
--     Far Drummer    | 1990-01-01
--
--    select display_name, st_y(location::geometry) ... ;
--     Ana Tester     | 42.3620 | -71.0650
--
--  The coordinate is rounded to about a mile before it is stored,
--  so this is a neighbourhood rather than a doorstep. It is still
--  more than the app shows, and more than the privacy policy
--  promised: "your age is never shown to anyone", "never your
--  coordinates". Rather than weaken the promise, close the gap.
--
--  A full date of birth is also the single most useful field an
--  identity thief can take, and nothing in Jammy needs to read
--  somebody else's.
-- ============================================================

-- ------------------------------------------------------------
--  1. The app needs to know whether the SERVER has a location
--     for you — that is what tells Discover which empty state to
--     show. It does not need the coordinate to answer that.
-- ------------------------------------------------------------
alter table profiles
  add column if not exists has_location boolean
  generated always as (location is not null) stored;

-- ------------------------------------------------------------
--  2. Discover already enforces its own rules — not banned, not
--     blocked either way, not already swiped — rather than
--     leaning on row security, and it returns `miles`, never the
--     point. That makes it safe to run with the definer's rights
--     so it can still read a column its callers no longer can.
-- ------------------------------------------------------------
alter function discover(numeric, boolean, text[], int, boolean, int)
  security definer;
alter function discover(numeric, boolean, text[], int, boolean, int)
  set search_path = public, extensions;

-- ------------------------------------------------------------
--  3. Hand back the table-wide grants and re-issue them column
--     by column. Anything not named here is invisible and
--     unwritable to an ordinary member, whatever query they send.
-- ------------------------------------------------------------
revoke select, update on profiles from authenticated;

grant select (
  id, handle, display_name, bio, city, photo_path,
  instruments, instrument_keys, genres,
  looking_for, looking_for_instruments, influences,
  rehearsal_days, remote_ok,
  verified_at, is_banned, terms_agreed_at, created_at,
  has_location
) on profiles to authenticated;

--  Writable: the things a person edits about themselves.
--  Deliberately absent: `birth_date`, so an account cannot change
--  its age after signup; `verified_at`, so nobody can award
--  themselves a verified mark; `is_banned`, so nobody can lift
--  their own ban; `created_at` and `id`.
grant update (
  handle, display_name, bio, city, location, photo_path,
  instruments, instrument_keys, genres,
  looking_for, looking_for_instruments, influences,
  rehearsal_days, remote_ok, terms_agreed_at
) on profiles to authenticated;

-- ------------------------------------------------------------
--  4. Your own date of birth is still yours to see. It comes back
--     through export_my_data(), which is a definer function and
--     already returns it.
-- ------------------------------------------------------------
