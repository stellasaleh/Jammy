#!/bin/bash
# Rebuild a Supabase-shaped database locally so tests run against the
# same shape Stella's live database has: PostGIS in `extensions`, an
# auth.uid() driven by a session setting, and a NON-OWNER role, because
# the owner bypasses every rule we are trying to test.
set -e
DB=jammy

su postgres -c "psql -q -c \"select pg_terminate_backend(pid) from pg_stat_activity where datname='$DB' and pid <> pg_backend_pid()\"" >/dev/null 2>&1 || true
su postgres -c "psql -q -c 'drop database if exists $DB'"
su postgres -c "psql -q -c 'create database $DB'"

su postgres -c "psql -q -d $DB" <<'SQL'
create schema if not exists extensions;
create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;

do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
  if not exists (select 1 from pg_roles where rolname='app_user') then create role app_user login password 'app'; end if;
end $$;

grant authenticated to app_user;

-- Supabase puts PostGIS in `extensions` and relies on the role search_path
alter role authenticated set search_path = public, extensions;
alter role anon          set search_path = public, extensions;
alter role app_user      set search_path = public, extensions;
alter database jammy     set search_path = public, extensions;

grant usage on schema extensions to anon, authenticated, service_role, app_user;
grant execute on all functions in schema extensions to anon, authenticated, service_role, app_user;

-- auth.uid(): reads whoever the test says is signed in
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, app_user;
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant execute on function auth.uid() to anon, authenticated, app_user;

-- storage.foldername(), used by the bucket rules
create schema if not exists storage;
grant usage on schema storage to anon, authenticated, app_user;
create or replace function storage.foldername(name text) returns text[]
language sql immutable as $$ select string_to_array(name, '/') $$;
grant execute on function storage.foldername(text) to anon, authenticated, app_user;
create publication supabase_realtime;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  created_at timestamptz default now());
-- test-harness conveniences: app_user stands in for Supabase Auth
-- creating accounts, and for psql scratch helpers. Neither weakens
-- row-level security, which is what the tests are actually probing.
grant select on auth.users to authenticated;
grant all on auth.users to app_user;
grant create on schema public to app_user;

-- shaped like Supabase's own storage tables, so 07_storage.sql runs here
-- exactly as it will run there
create table if not exists storage.buckets (
  id text primary key, name text, owner uuid,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  public boolean default false, avif_autodetection boolean default false,
  file_size_limit bigint, allowed_mime_types text[], owner_id text);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets, name text, owner uuid,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  last_accessed_at timestamptz default now(), metadata jsonb, owner_id text);
alter table storage.objects enable row level security;
grant select, insert, update, delete on storage.objects to authenticated, app_user;
grant select on storage.buckets to authenticated, app_user;
SQL
echo "replica ready"
