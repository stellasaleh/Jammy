-- ============================================================
--  JAMMY — 10_grants.sql
--  THE PERMISSION THE APP WAS MISSING. Run after 01–09.
--
--  WHAT WENT WRONG
--  Postgres has two separate gates, and Jammy only built one.
--
--    1. GRANTS    — may this role touch this table at all?
--    2. POLICIES  — which rows may it see or change?
--
--  Every table here had policies. None had grants. That mostly
--  went unnoticed, because Supabase hands out grants of its own
--  for tables it sees created — but not for every one, and
--  `blocks` was among the ones it missed.
--
--  It surfaced in the worst possible place. The policy deciding
--  which profiles you may read asks "has either of us blocked
--  the other?", which reads `blocks`. With no grant on that
--  table the question itself fails, so creating a profile died
--  with "permission denied for table blocks" — a message naming
--  a table the sign-up screen never mentions.
--
--  GRANTS ARE NOT SECURITY HERE. Row-level security is, and it
--  is already on every table. A grant only says "you may ask";
--  the policies still decide what comes back. The seven tables
--  locked in 06 have no policies for the app, so they stay shut
--  no matter what is granted below.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. Let signed-in people reach the tables; let the policies
--     decide what they actually get.
-- ------------------------------------------------------------
grant usage on schema public to anon, authenticated;

grant select, insert, update, delete
  on all tables in schema public
  to authenticated;

grant usage, select on all sequences in schema public to authenticated;

-- ------------------------------------------------------------
--  2. Signed-out visitors get nothing.
--
--  Jammy requires an account — there is no browsing without
--  one, by design, because the whole app is strangers meeting
--  strangers. So `anon` is granted no table at all. If a public
--  page is ever wanted (a shareable band profile, say), it gets
--  its own narrow grant and its own policy, deliberately.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
--  3. The functions the app calls by name
-- ------------------------------------------------------------
grant execute on all functions in schema public to authenticated;

-- ------------------------------------------------------------
--  4. Anything added later gets the same treatment
--
--  Without this, the next table added brings the same bug back,
--  and it will surface somewhere just as confusing.
-- ------------------------------------------------------------
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public
  grant usage, select on sequences to authenticated;
alter default privileges in schema public
  grant execute on functions to authenticated;

-- ------------------------------------------------------------
--  5. Proof
--
--  Names every table a signed-in person still cannot reach.
--  Should be empty.
-- ------------------------------------------------------------
do $$
declare missing text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into missing
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'r'
    and not exists (
      select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e'
    )
    and not has_table_privilege('authenticated', c.oid, 'SELECT');

  if missing is null then
    raise notice 'Jammy: every table is reachable, and row-level security still decides what comes back.';
  else
    raise exception 'Jammy: these tables are still unreachable: %', missing;
  end if;
end $$;
