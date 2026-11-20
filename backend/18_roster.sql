-- ============================================================
--  JAMMY — 18_roster.sql
--  GETTING SOMEBODY OUT OF A BAND. Run after 01–17.
--
--  WHY THIS EXISTS
--  17_gigs.sql closed the door that let anyone add themselves to
--  any band. Closing a door does nothing about whoever already
--  walked through it, and there was no way at all to take a
--  person off a roster — not for them, not for the band.
--
--  Two holes, and they are opposite shapes:
--
--  1. The band could not remove anyone. Somebody who let
--     themselves in through the old door stayed in, and a member
--     can read the rehearsal address. There was no way to undo
--     that short of deleting the band.
--
--  2. Leaving did not work either. The app's Leave button only
--     changed what was stored on the phone and never told the
--     database, so a person who left was still on the roster, in
--     the band chat, and still able to read the address. That half
--     is fixed in the app; leave_band() itself was already right.
--
--  Safe to run twice.
-- ============================================================

-- ------------------------------------------------------------
--  1. Taking somebody off the roster
--
--  Only somebody who runs the band. The same two protections
--  leave_band() has apply: a band is never left with no admin,
--  and nobody can remove the last person and strand the band.
--
--  Removing somebody also takes them out of the band chat. A
--  person who is no longer in the band should not keep receiving
--  the band's messages, and the chat is where the next practice
--  gets arranged.
-- ------------------------------------------------------------
create or replace function remove_band_member(b uuid, who uuid)
returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare
  me     uuid := (select auth.uid());
  others int;
begin
  if me is null then raise exception 'not signed in'; end if;

  if not exists (select 1 from band_members
                  where band_id = b and user_id = me and is_admin) then
    raise exception 'only someone who runs this band can take a person out of it';
  end if;

  if who = me then
    raise exception 'use Leave to take yourself out of a band';
  end if;

  if not exists (select 1 from band_members where band_id = b and user_id = who) then
    return false;   -- already not in it; nothing to do and nothing to report
  end if;

  select count(*) into others from band_members
   where band_id = b and user_id is distinct from who;
  if others = 0 then
    raise exception 'that is the only person left in the band';
  end if;

  -- never leave the band with nobody running it
  if exists (select 1 from band_members
              where band_id = b and user_id = who and is_admin)
     and not exists (select 1 from band_members
                      where band_id = b and is_admin and user_id is distinct from who) then
    update band_members set is_admin = true
     where id = (select id from band_members
                  where band_id = b and user_id is distinct from who
                  order by joined_at limit 1);
  end if;

  delete from band_members where band_id = b and user_id = who;

  -- and out of the band chat, which is where practices get arranged
  delete from conversation_members
   where user_id = who
     and conversation_id in (select id from conversations
                              where kind = 'band' and band_id = b);

  -- a removed person may ask again later; an old answer should not
  -- sit there pretending to be the current one
  delete from band_join_requests
   where band_id = b and user_id = who and status <> 'pending';

  return true;
end $$;

comment on function remove_band_member is
  'Admin only. Never strands a band without an admin, and never empties it.';

-- ------------------------------------------------------------
--  2. Who is in this band, and how did they get in
--
--  After the old door, "is this person really in my band?" is a
--  fair question to be able to answer from inside the app rather
--  than from the SQL editor.
-- ------------------------------------------------------------
create or replace function band_roster_detail(b uuid)
returns table (
  user_id uuid, display_name text, handle text, photo_path text,
  instruments text[], role_label text, is_admin boolean,
  joined_at timestamptz, is_me boolean, can_remove boolean
)
language sql stable security definer set search_path = public, extensions as $$
  select bm.user_id,
         coalesce(p.display_name, bm.display_name),
         p.handle, p.photo_path,
         case when bm.instruments <> '{}' then bm.instruments
              else coalesce(p.instruments,'{}') end,
         bm.role_label, bm.is_admin, bm.joined_at,
         (bm.user_id = (select auth.uid())),
         -- you can take somebody out if you run the band, it is not
         -- you, and they are not the only person left
         (exists (select 1 from band_members a
                   where a.band_id = b and a.user_id = (select auth.uid()) and a.is_admin)
          and bm.user_id is distinct from (select auth.uid())
          and (select count(*) from band_members c where c.band_id = b) > 1)
  from band_members bm
  left join profiles p on p.id = bm.user_id
  where bm.band_id = b
    and is_band_member(b)        -- the roster's joining dates are the band's business
  order by bm.is_admin desc, bm.joined_at;
$$;

-- ------------------------------------------------------------
--  3. Proof
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('remove_band_member','band_roster_detail');
  if n <> 2 then
    raise exception 'Jammy: expected 2 roster functions, found %', n;
  end if;
  raise notice 'Jammy: a band can now take somebody out of it, and leaving works.';
end $$;
