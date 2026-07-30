#!/usr/bin/env bash
# Watcher liveness, worktree-tangle, and claimed-but-never-dispatched guard,
# called by supervision scripts, by fm-wake-drain.sh after it empties queued
# wakes, and by fm-session-start.sh in read-only advisory mode when another
# session holds the fleet lock.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Second, always warn if data/backlog.md records an item as in flight while it is
# neither held nor backed by a state/<id>.meta: firstmate started that item and
# never spawned a worker, which is what a dropped or falsely reported dispatch
# looks like on disk. Like the tangle alarm it runs before the in-flight early
# exit below, because it is precisely the case where no worker exists. Its full
# banner is likewise emitted once per distinct episode (keyed to the reported id
# set) under state/.guard-undispatched-banner. Unlike a stale beacon, that
# condition persists exactly while nobody has acted on it, so bin/fm-session-start.sh
# ends the episode once on its locked path, after bootstrap's discarded-output
# sweeps: loud once per session, quiet for the rest of it.
# Then, if any task is in flight (a state/<id>.meta exists) and the watcher's
# liveness beacon (state/.last-watcher-beat, touched every poll cycle) is
# missing or older than FM_GUARD_GRACE seconds, prints a loud, clearly delimited
# banner so the agent cannot skim past it in the tool output of whatever it was
# doing - the one channel every harness has. The full banner is emitted once per
# distinct staleness episode in this FM_HOME (keyed to beacon mtime or absence);
# later guarded commands in the same episode print a one-line reminder instead.
# Episode state lives only under state/.guard-watcher-stale-banner (volatile,
# bounded). Independent alarms (queued wakes, worktree tangle) are never
# suppressed by that dedup. Normal wake handling (watcher briefly down between a
# wake and the next supervision resume) stays inside the grace window and stays
# silent. Always exits 0: the guard warns, it never blocks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"
GRACE=${FM_GUARD_GRACE:-300}
# Bound the ids listed in the claimed-but-never-dispatched banner; the count line
# above them always reports the true total. Validated before use so a non-numeric
# override cannot leak a head or test error into the middle of the banner, and
# clamped to at least 1 so the banner can never name no ids at all.
UNDISPATCHED_LIST_MAX=${FM_GUARD_UNDISPATCHED_LIST_MAX:-5}
case "$UNDISPATCHED_LIST_MAX" in ''|*[!0-9]*) UNDISPATCHED_LIST_MAX=5 ;; esac
[ "$UNDISPATCHED_LIST_MAX" -ge 1 ] || UNDISPATCHED_LIST_MAX=1
queue_pending=false
READ_ONLY=${FM_GUARD_READ_ONLY:-0}
case "$READ_ONLY" in 1|true|TRUE|yes|YES) READ_ONLY=1 ;; *) READ_ONLY=0 ;; esac
CONTINUE_LINE=${FM_GUARD_CONTINUE_LINE:-This is a supervision warning only; the guarded operation WILL still run.}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Volatile, home-scoped episode markers: one line = that alarm's current episode
# key. Each is cleared when its own condition clears so a later episode re-arms;
# the undispatched one is additionally cleared once per locked session start
# (bin/fm-session-start.sh), because that condition persists precisely while
# nobody has acted on it and must stay loud on every new session.
STALE_BANNER_MARKER="$STATE/.guard-watcher-stale-banner"
UNDISPATCHED_BANNER_MARKER=$(fm_sup_undispatched_banner_marker "$STATE")

# Deterministic episode key from beacon state: same continuous stale beacon
# (or continuous absence) shares a key; a recovered-then-restale beacon gets a
# new mtime and therefore a new episode.
fm_guard_stale_episode_key() {
  local state=$1 beat m
  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    printf 'beat:%s\n' "${m:-unknown}"
  else
    printf 'beat:absent\n'
  fi
}

# Claim the full banner for this episode of the alarm owning <marker>. Exit 0 =
# print full banner (this call owns the first announcement). Exit 1 = same
# episode already announced (print reminder). The shared wake lock helper owns
# the race-safety mechanics; the re-check under the lock makes concurrent claims
# idempotent. Each alarm passes its own marker, so one alarm's dedup never
# suppresses another's.
fm_guard_claim_banner() {
  local marker=$1 key=$2
  local lock="$marker.lock"
  local seen i

  seen=$(cat "$marker" 2>/dev/null || true)
  # Strip a single trailing newline so key comparison is line-content based.
  seen=${seen%$'\n'}
  if [ "$seen" = "$key" ]; then
    return 1
  fi

  i=0
  while [ "$i" -lt 50 ]; do
    if fm_lock_try_acquire "$lock"; then
      seen=$(cat "$marker" 2>/dev/null || true)
      seen=${seen%$'\n'}
      if [ "$seen" = "$key" ]; then
        fm_lock_release "$lock" 2>/dev/null || true
        return 1
      fi
      # Bounded write: one line, no growth across episodes (overwrite).
      printf '%s\n' "$key" > "$marker" || true
      fm_lock_release "$lock" 2>/dev/null || true
      return 0
    fi
    seen=$(cat "$marker" 2>/dev/null || true)
    seen=${seen%$'\n'}
    if [ "$seen" = "$key" ]; then
      return 1
    fi
    # Brief yield; 0.02s is fine on macOS/Linux sleep, fall back to 1s.
    sleep 0.02 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  # Contended past the spin budget: stay loud rather than dropping the alarm.
  return 0
}

fm_guard_banner_seen() {
  local marker=$1 key=$2
  local seen

  seen=$(cat "$marker" 2>/dev/null || true)
  seen=${seen%$'\n'}
  [ "$seen" = "$key" ]
}

fm_guard_clear_stale_banner() {
  rm -f "$STALE_BANNER_MARKER" 2>/dev/null || true
}

# Bounded episode key for an arbitrary-length set of ids: the marker stays one
# short line no matter how neglected the backlog is.
fm_guard_digest() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print "sha256:" $1}'
  else
    printf '%s' "$1" | cksum | awk '{print "cksum:" $1 ":" $2}'
  fi
}

fm_guard_line_count() {
  if [ -z "$1" ]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$1" | wc -l | tr -d ' '
}

# Print one bounded, bulleted list inside the banner, then say how many entries it
# withheld, so a neglected backlog cannot flood every fleet command while the
# count line above still reports the true total.
fm_guard_print_bounded_list() {
  local lines=$1 total=$2 entry
  printf '%s\n' "$lines" | head -"$UNDISPATCHED_LIST_MAX" | while IFS= read -r entry; do
    printf '●      %s\n' "$entry"
  done
  if [ "$total" -gt "$UNDISPATCHED_LIST_MAX" ]; then
    printf '●      ... and %s more\n' "$((total - UNDISPATCHED_LIST_MAX))"
  fi
}

# Worktree-tangle alarm, checked FIRST and independent of in-flight tasks: the
# firstmate PRIMARY checkout (FM_ROOT) must stay on its default branch. If a
# crewmate's branch/commits landed here instead of in its own isolated worktree,
# the primary is stranded on a feature branch - surface it loudly on the very next
# fleet action, the same way the watcher-down banner does. Scoped to the primary
# only: detached HEAD (linked worktrees, secondmate homes) never trips this.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  trule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$trule"
    printf '●  WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH\n'
    printf "●  %s is on '%s', not its default branch '%s'.\n" "$FM_ROOT" "$tangle_branch" "$tangle_default"
    printf '●  A crewmate likely branched/committed in the primary instead of its own worktree.\n'
    printf "●  The work is SAFE on the '%s' ref.\n" "$tangle_branch"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session must leave restore work to the session holding the fleet lock.\n'
    else
      printf "●  Restore the primary to '%s':\n" "$tangle_default"
      printf '●      git -C %s checkout %s\n' "$FM_ROOT" "$tangle_default"
      printf "●  then re-validate '%s' in a proper isolated worktree.\n" "$tangle_branch"
    fi
    printf '●%s\n' "$trule"
  } >&2
fi

# Claimed-but-never-dispatched alarm, checked before the in-flight early exit
# below because the whole point is the case where NO worker exists: a backlog row
# recorded as started, with no ACTIVE hold and no state/<id>.meta. Firstmate has
# told the captain work was dispatched when nothing was ever spawned, so surface
# it on the very next fleet action rather than at the next session start.
# The predicate's two exclusions - an active hold, and a task torn down but not
# yet filed - are what keep this quiet enough to stay worth reading; see
# bin/fm-supervision-lib.sh. The sweep below keeps the teardown markers
# self-clearing and bounded, and only a writable session may run it.
# A row whose id the predicate refused as unsafe is counted and remedied
# separately: no metadata lookup ever ran for it, so it needs the row repaired
# rather than a worker spawned, and folding it into the metadata-gap count would
# make that count line false.
# Like the watcher-down banner, the full banner prints once per episode, keyed to
# the set of reported ids, so a persistent gap does not repaint on every fleet
# command. This dedup is independent of the other alarms in both directions.
# One backlog parse serves both the sweep and the predicate; the sweep still runs
# first, so a row filed just before this call clears its marker in the same call.
in_flight_rows=$(fm_sup_in_flight_row_records "$BACKLOG")
[ "$READ_ONLY" -eq 1 ] || fm_supervision_sweep_completion_pending "$BACKLOG" "$STATE" "$in_flight_rows"
undispatched=$(fm_supervision_undispatched "$BACKLOG" "$STATE" "$in_flight_rows")
if [ -n "$undispatched" ]; then
  # Two classes, reported separately so each count line is literally true: rows
  # that were checked and have no worker metadata, and rows whose id was refused
  # as unsafe before any lookup could happen. The latter need the row repaired,
  # not a worker spawned, and no metadata check ever ran for them.
  # The predicate types every record in its first tab-separated field, so this
  # banner owns the malformed wording rather than parsing it back out of prose.
  undispatched_ids=$(printf '%s\n' "$undispatched" | awk -F'\t' '$1 == "ok" { print $2 }')
  malformed_rows=$(printf '%s\n' "$undispatched" | awk -F'\t' '$1 == "malformed" { print "malformed backlog id: " $2 }')
  undispatched_n=$(fm_guard_line_count "$undispatched_ids")
  malformed_n=$(fm_guard_line_count "$malformed_rows")
  undispatched_key=$(fm_guard_digest "$(printf '%s\n' "$undispatched" | LC_ALL=C sort)")
  print_undispatched_banner=0
  if [ "$READ_ONLY" -eq 1 ]; then
    fm_guard_banner_seen "$UNDISPATCHED_BANNER_MARKER" "$undispatched_key" || print_undispatched_banner=1
  elif fm_guard_claim_banner "$UNDISPATCHED_BANNER_MARKER" "$undispatched_key"; then
    print_undispatched_banner=1
  fi
  if [ "$print_undispatched_banner" -eq 1 ]; then
    urule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    {
      printf '●%s\n' "$urule"
      printf '●  BACKLOG SAYS STARTED - NO WORKER EXISTS\n'
      if [ "$undispatched_n" -gt 0 ]; then
        printf '●  %s backlog item(s) are in flight, unheld, and have no crewmate metadata:\n' "$undispatched_n"
        fm_guard_print_bounded_list "$undispatched_ids" "$undispatched_n"
        printf '●  Each was recorded as started but never spawned, or its worker is gone and the row was never filed.\n'
        if [ "$READ_ONLY" -eq 1 ]; then
          printf '●  This read-only session should report the gap, not repair it.\n'
        else
          printf '●  Do not report these as dispatched. Spawn the work, hold it with a reason, or file it Done.\n'
        fi
      fi
      if [ "$malformed_n" -gt 0 ]; then
        printf '●  %s in-flight row(s) carry an unusable id, so no worker could be looked up for them:\n' "$malformed_n"
        fm_guard_print_bounded_list "$malformed_rows" "$malformed_n"
        if [ "$READ_ONLY" -eq 1 ]; then
          printf '●  This read-only session should report the malformed rows, not repair them.\n'
        else
          printf '●  Repair those rows in %s so each one can be checked for a worker.\n' "$BACKLOG"
        fi
      fi
      printf '●%s\n' "$urule"
    } >&2
  elif [ "$undispatched_n" -eq 0 ]; then
    printf 'WARNING: %s in-flight backlog row(s) still carry an unusable id (same set) - full banner already printed this episode.\n' \
      "$malformed_n" >&2
  elif [ "$malformed_n" -eq 0 ]; then
    printf 'WARNING: %s backlog item(s) still recorded as started with no worker (same set) - full banner already printed this episode.\n' \
      "$undispatched_n" >&2
  else
    printf 'WARNING: %s backlog item(s) still recorded as started with no worker, and %s row(s) with an unusable id (same set) - full banner already printed this episode.\n' \
      "$undispatched_n" "$malformed_n" >&2
  fi
elif [ "$READ_ONLY" -eq 0 ]; then
  # Condition cleared: end the episode so a later recurrence re-arms the banner.
  rm -f "$UNDISPATCHED_BANNER_MARKER" 2>/dev/null || true
fi

# Compute in-flight count and watcher-beacon freshness via the shared
# grace-based predicate (bin/fm-supervision-lib.sh). Only act with tasks in
# flight; count them so the banner can say how much is riding on an absent
# watcher.
fm_supervision_status "$STATE" "$GRACE"
in_flight=$FM_SUP_IN_FLIGHT
watcher_fresh=$FM_SUP_WATCHER_FRESH
beacon_desc=$FM_SUP_BEACON_DESC
if [ "$in_flight" -eq 0 ]; then
  # Leave the unhealthy state (no work riding on the watcher): clear so a later
  # in-flight + stale combination is a fresh episode even if the beacon is still
  # absent with the same key string.
  [ "$READ_ONLY" -eq 1 ] || fm_guard_clear_stale_banner
  exit 0
fi

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true

# No fresh watcher with tasks in flight is the dangerous state: emit a prominent,
# bordered banner FIRST so it reads as an alarm, not a buried stderr line. Later
# calls in the same episode get a one-line reminder only.
if [ "$watcher_fresh" = false ]; then
  episode_key=$(fm_guard_stale_episode_key "$STATE")
  episode_key=${episode_key%$'\n'}
  print_full_banner=0
  if [ "$READ_ONLY" -eq 1 ]; then
    fm_guard_banner_seen "$STALE_BANNER_MARKER" "$episode_key" || print_full_banner=1
  elif fm_guard_claim_banner "$STALE_BANNER_MARKER" "$episode_key"; then
    print_full_banner=1
  fi
  if [ "$print_full_banner" -eq 1 ]; then
    afk=0
    [ -e "$STATE/.afk" ] && afk=1
    queue_arg=0
    "$queue_pending" && queue_arg=1
    x_mode=0
    [ -f "$CONFIG/x-mode.env" ] && x_mode=1
    fix=$("$SCRIPT_DIR/fm-supervision-instructions.sh" \
      --read-only "$READ_ONLY" \
      --afk "$afk" \
      --x-mode "$x_mode" \
      --queue-pending "$queue_arg" \
      --repair-line 2>/dev/null || printf '%s\n' 'Repair missing watcher supervision according to the session-start operating block.')
    rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    {
      printf '●%s\n' "$rule"
      printf '●  WATCHER DOWN - SUPERVISION IS OFF\n'
      printf '●  %s task(s) in flight, but no watcher has a fresh beacon (last beat: %s, grace %ss).\n' "$in_flight" "$beacon_desc" "$GRACE"
      if [ "$READ_ONLY" -eq 1 ]; then
        printf '●  This read-only session should report the lapse, not repair it.\n'
      else
        printf '●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.\n'
      fi
      printf '●  %s\n' "$CONTINUE_LINE"
      printf '●  %s\n' "$fix"
      printf '●%s\n' "$rule"
    } >&2
  else
    printf 'WARNING: watcher still down (same stale episode; last beat: %s, grace %ss) - full banner already printed this episode.\n' \
      "$beacon_desc" "$GRACE" >&2
  fi
else
  # Healthy again while work is still in flight: end the episode so a later
  # restale re-prints the full banner.
  [ "$READ_ONLY" -eq 1 ] || fm_guard_clear_stale_banner
fi

# Queued wakes are an independent hazard; warn whenever they are pending, even if
# a watcher is alive. Kept after the banner so the no-watcher alarm reads first.
# Dedup of the watcher-down banner never suppresses this warning.
if "$queue_pending"; then
  if [ "$READ_ONLY" -eq 1 ]; then
    echo "WARNING: queued wakes pending - left untouched for the session holding the fleet lock." >&2
  else
    echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
  fi
fi
exit 0
