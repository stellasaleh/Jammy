-- ============================================================
--  JAMMY — 15_requests.sql
--  "SOMEONE WANTS TO PLAY WITH YOU". Run after 01–14.
--
--  Until now a connection could only happen by coincidence:
--  two people had to swipe yes on each other without either
--  knowing the other had. If a drummer asked to play with you
--  on Monday, you found out only if you happened to swipe yes
--  on him later. Otherwise nothing — he waits, you never know
--  he asked.
--
--  Dating apps hide this on purpose and charge to reveal it.
--  For a free app where a bassist is trying to find a band
--  before their gig on Saturday, hiding it just wastes
--  everyone's time.
--
--  incoming_requests() answers: who has asked to play with me
--  and is still waiting? It needs elevated rights because a
--  person can only see their OWN swipes by design — which is
--  exactly why this was invisible.
--
--  Safe to run twice.
-- ============================================================

create or replace function incoming_requests()
returns table (
  id uuid, display_name text, handle text, city text, photo_path text,
  instruments text[], genres text[], looking_for text, bio text,
  shared_genres text[], they_need_me text[], miles numeric, asked_at timestamptz
)
language sql stable security definer set search_path = public, extensions as $$
  with me as (select * from profiles where id = (select auth.uid()))
  select
    p.id, p.display_name, p.handle, p.city, p.photo_path,
    p.instruments, p.genres, p.looking_for, p.bio,
    array(select unnest(p.genres) intersect select unnest(me.genres))                       as shared_genres,
    array(select unnest(p.looking_for_instruments) intersect select unnest(me.instruments)) as they_need_me,
    case when p.location is null or me.location is null then null
         else round((st_distance(p.location, me.location) / 1609.34)::numeric, 1)
    end as miles,
    s.created_at as asked_at
  from swipes s
  join profiles p on p.id = s.from_id
  cross join me
  where s.to_id = me.id
    and s.direction = 'yes'
    and not exists (
      select 1 from swipes mine
      where mine.from_id = me.id and mine.to_id = p.id
    )
    and not p.is_banned
    and not blocked_between(p.id, me.id)
  order by s.created_at desc;
$$;

-- ------------------------------------------------------------
--  How many are waiting — cheap enough to ask on every screen
-- ------------------------------------------------------------
create or replace function incoming_request_count()
returns int
language sql stable security definer set search_path = public, extensions as $$
  select count(*)::int from incoming_requests();
$$;

-- ------------------------------------------------------------
--  Speed: "who swiped yes on me?" is a different question from
--  "who did I swipe on", and wants its own index.
-- ------------------------------------------------------------
create index if not exists swipes_to_yes_idx
  on swipes (to_id, direction, created_at desc)
  where direction = 'yes';

-- ------------------------------------------------------------
--  Proof
-- ------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname='public' and p.proname='incoming_requests') then
    raise notice 'Jammy: people can now see who has asked to play with them.';
  else
    raise exception 'Jammy: incoming_requests() is missing';
  end if;
end $$;
