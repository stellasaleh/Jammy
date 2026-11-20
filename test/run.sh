#!/bin/bash
# ============================================================
#  JAMMY — run.sh
#  Build a clean Supabase-shaped database, run every migration,
#  then run every test as an ORDINARY SIGNED-IN USER.
#
#  Each test gets an empty database of its own, so no test can
#  pass or fail because of what another one left behind.
#
#    bash test/run.sh
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BE="$HERE/backend"
# Two shapes of test, and the difference matters.
#
#   Tests that say `set role app_user` ... `reset role` are written
#   to CONNECT as the owner and step down into an ordinary user for
#   the checks, stepping back up to seed. Connect those as the owner
#   or `reset role` hands back to app_user and the seeding fails.
#
#   Tests that never switch role must CONNECT as app_user, or every
#   rule they are probing is bypassed and they pass for free.
AS_OWNER="psql -q -h 127.0.0.1 -U postgres -d jammy -v ON_ERROR_STOP=1"
AS_USER="PGPASSWORD=app psql -q -h 127.0.0.1 -U app_user -d jammy -v ON_ERROR_STOP=1"

MIGRATIONS="01_schema 02_security_and_functions 03_scale 04_likes_comments \
05_ads 06_lockdown 07_storage 08_chat 09_swipe 10_grants 11_discover_fallback \
12_matching_fix 13_match_repair 14_blocking_fix 15_requests 16_bands 17_gigs"

echo "building the database"
bash "$HERE/../replica.sh" >/dev/null 2>&1 || /home/claude/replica.sh >/dev/null 2>&1

for f in $MIGRATIONS; do
  if ! su postgres -c "psql -q -v ON_ERROR_STOP=1 -d jammy -f $BE/$f.sql" >/tmp/mig.log 2>&1; then
    echo "  MIGRATION FAILED: $f"; tail -8 /tmp/mig.log; exit 1
  fi
done
echo "  $(echo $MIGRATIONS | wc -w) migrations applied"

# prove they are safe to run twice, which is what the files promise
for f in $MIGRATIONS; do
  su postgres -c "psql -q -v ON_ERROR_STOP=1 -d jammy -f $BE/$f.sql" >/tmp/mig.log 2>&1 || {
    echo "  NOT RE-RUNNABLE: $f"; tail -8 /tmp/mig.log; exit 1; }
done
echo "  and re-runnable"
echo

TOTAL_PASS=0; TOTAL_FAIL=0; BROKEN=""

for t in journey match-and-message permissions requests bands gigs; do
  [ -f "$HERE/test/$t.test.sql" ] || continue
  su postgres -c "psql -q -d jammy -f $HERE/test/reset.sql" >/dev/null 2>&1
  # the older tests expect a fixed cast; journey and gigs make their own
  case "$t" in
    journey|gigs) ;;
    *) su postgres -c "psql -q -v ON_ERROR_STOP=1 -d jammy -f $HERE/test/seed.sql" >/tmp/seed.log 2>&1 \
         || { echo "  SEED FAILED for $t"; tail -5 /tmp/seed.log; } ;;
  esac
  if grep -q 'set role' "$HERE/test/$t.test.sql"; then
    out=$(su postgres -c "psql -q -d jammy -v ON_ERROR_STOP=1 -f $HERE/test/$t.test.sql" 2>&1)
  else
    out=$(eval $AS_USER -f "$HERE/test/$t.test.sql" 2>&1)
  fi
  p=$(echo "$out" | grep -cE '(^|\| )PASS')
  f=$(echo "$out" | grep -cE '(^|\| )FAIL')
  e=$(echo "$out" | grep -cE '^psql.*ERROR')
  TOTAL_PASS=$((TOTAL_PASS+p)); TOTAL_FAIL=$((TOTAL_FAIL+f))
  if [ "$f" -gt 0 ] || [ "$e" -gt 0 ]; then
    BROKEN="$BROKEN $t"
    printf '%-20s %3d passed, %d FAILED, %d errors\n' "$t" "$p" "$f" "$e"
    echo "$out" | grep -E '(^|\| )FAIL|^psql.*ERROR' | sed 's/^/    /' | head -12
  else
    printf '%-20s %3d passed\n' "$t" "$p"
  fi
done

echo
if [ -n "$BROKEN" ]; then
  echo "FAILED:$BROKEN  ($TOTAL_FAIL checks failed of $((TOTAL_PASS+TOTAL_FAIL)))"
  exit 1
fi
echo "$TOTAL_PASS checks, all passed."
