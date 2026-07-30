# shellcheck shell=bash
# Shared "supervision missing" predicates.
# Usage: . bin/fm-supervision-lib.sh
#
# fm_supervision_status/fm_supervision_unhealthy are true exactly when a
# firstmate home has in-flight work (a state/<id>.meta exists) but no watcher has
# a fresh liveness beacon (state/.last-watcher-beat, touched every poll cycle,
# within the grace window). bin/fm-guard.sh uses this grace-based warning
# predicate directly; bin/fm-turnend-guard.sh uses the status fields here for its
# banner but performs its end-of-turn block decision with the live watcher lock
# check in bin/fm-wake-lib.sh.
#
# fm_supervision_undispatched is the separate claimed-but-never-dispatched
# predicate: a backlog row recorded as started for which no worker exists.

# fm_task_id_path_safe (bin/fm-pr-lib.sh) is the repo's one owner of task-id
# path safety; sourced here only when a caller has not already provided it, so
# re-sourcing never resets that library's FM_PR_* globals mid-run.
if ! declare -F fm_task_id_path_safe >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-pr-lib.sh"
fi

# Age at which a completion-pending marker stops excluding its row, so a task
# torn down but never filed eventually surfaces again instead of being blinded
# forever. Overridable per home; a non-numeric override falls back to the default.
FM_SUP_COMPLETION_PENDING_MAX_AGE=${FM_COMPLETION_PENDING_MAX_AGE:-86400}
case "$FM_SUP_COMPLETION_PENDING_MAX_AGE" in
  ''|*[!0-9]*) FM_SUP_COMPLETION_PENDING_MAX_AGE=86400 ;;
esac

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

# fm_sup_in_flight_row_records <backlog-file>
# The one parser for structured backlog rows under the "In flight" heading.
# Prints "<held|open><TAB><id>" per row. Understands both row forms the tasks-axi
# markdown backend writes: "- [ ] <id> - ..." and "- **<id>** - ...".
# Section detection anchors on "^##[[:space:]]+" exactly like the repo's other
# backlog parsers (fm-backlog-handoff.sh, fm-session-start.sh,
# fm-fleet-snapshot.sh), so a stray column-0 "#" line in a hand-edited note - a
# pasted command, a deeper sub-heading, a "#691" reference - cannot end the
# section early and silently hide every row after it.
# A hold is ACTIVE only when the row carries a real "hold:" reason AND either no
# "hold-until:" date or a date still in the future, matching tasks-axi's own
# semantics: a date gate is inactive on and after that date, so a lapsed gate is
# dispatchable work again. "hold-kind:" alone is never a hold.
# Silent for an absent or headingless backlog.
fm_sup_in_flight_row_records() {
  local backlog=$1
  [ -f "$backlog" ] || return 0
  awk -v today="$(date +%Y-%m-%d)" '
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "", section)
      sub(/[[:space:]]+$/, "", section)
      next
    }
    section != "In flight" { next }
    {
      id = ""
      if (match($0, /^[-*][ \t]+\[[ xX]\][ \t]+/)) {
        rest = substr($0, RSTART + RLENGTH)
        if (match(rest, /^[^ \t]+[ \t]+-[ \t]+/)) {
          id = rest
          sub(/[ \t].*$/, "", id)
        }
      } else if (match($0, /^[-*][ \t]+\*\*[^*]+\*\*[ \t]+-[ \t]+/)) {
        id = $0
        sub(/^[-*][ \t]+\*\*/, "", id)
        sub(/\*\*.*$/, "", id)
      }
      if (id == "") next

      held = ($0 ~ /\([ \t]*hold:/ || $0 ~ /,[ \t]*hold:/)
      if (held && match($0, /hold-until:[ \t]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        until_date = substr($0, RSTART, RLENGTH)
        sub(/^hold-until:[ \t]*/, "", until_date)
        # Lexical compare is correct for zero-padded ISO dates.
        if (until_date <= today) held = 0
      }
      printf "%s\t%s\n", (held ? "held" : "open"), id
    }
  ' "$backlog"
}

# fm_sup_in_flight_unheld_ids <backlog-file> [row-records]
# Ids of in-flight rows carrying no ACTIVE hold, one per line. A caller that
# already holds fm_sup_in_flight_row_records output passes it as <row-records> so
# one guarded command parses the backlog once.
fm_sup_in_flight_unheld_ids() {
  local backlog=$1 records
  if [ "$#" -ge 2 ]; then
    records=$2
  else
    records=$(fm_sup_in_flight_row_records "$backlog")
  fi
  printf '%s\n' "$records" | awk -F'\t' '$1 == "open" { print $2 }'
}

# fm_sup_completion_pending_marker <state-dir> <id>
# Path of the durable "torn down, awaiting its backlog filing" marker for a task.
fm_sup_completion_pending_marker() {
  printf '%s/.completion-pending-%s\n' "$1" "$2"
}

# fm_supervision_mark_completion_pending <state-dir> <id>
# Record that <id>'s worker metadata was just removed by a real teardown and its
# backlog row has not been filed yet. bin/fm-teardown.sh is the writer. Refuses
# an unsafe id rather than creating a path outside the state dir.
fm_supervision_mark_completion_pending() {
  local state=$1 id=$2
  fm_task_id_path_safe "$id" || return 1
  [ -d "$state" ] || return 0
  : > "$(fm_sup_completion_pending_marker "$state" "$id")" 2>/dev/null || return 1
  return 0
}

# fm_sup_completion_pending_fresh <state-dir> <id> [now-epoch]
# True while <id> carries an unexpired completion-pending marker. A caller
# checking several ids passes one <now-epoch> so the clock is read once.
fm_sup_completion_pending_fresh() {
  local state=$1 id=$2 now=${3:-} marker m
  marker=$(fm_sup_completion_pending_marker "$state" "$id")
  [ -e "$marker" ] || return 1
  m=$(fm_sup_stat_mtime "$marker")
  [ -n "$m" ] || return 1
  [ -n "$now" ] || now=$(date +%s)
  [ "$((now - m))" -lt "$FM_SUP_COMPLETION_PENDING_MAX_AGE" ]
}

# fm_supervision_sweep_completion_pending <backlog-file> <state-dir> [row-records]
# Keep the marker set self-clearing and bounded: drop every marker whose row is
# no longer in flight (it has been filed) and every marker past the max age (so a
# torn-down-but-never-filed row surfaces again). Writers only; callers in
# read-only mode must not run this. A caller that already holds
# fm_sup_in_flight_row_records output passes it as <row-records>.
# Always returns 0.
fm_supervision_sweep_completion_pending() {
  local backlog=$1 state=$2 records marker id now m in_flight found=0
  [ -d "$state" ] || return 0
  # A home with no markers is the ordinary case, so cost nothing there.
  for marker in "$state"/.completion-pending-*; do
    [ -e "$marker" ] || continue
    found=1
    break
  done
  [ "$found" -eq 1 ] || return 0
  if [ "$#" -ge 3 ]; then
    records=$3
  else
    records=$(fm_sup_in_flight_row_records "$backlog")
  fi
  now=$(date +%s)
  in_flight=$(printf '%s\n' "$records" | awk -F'\t' '{ print $2 }')
  for marker in "$state"/.completion-pending-*; do
    [ -e "$marker" ] || continue
    id=${marker##*/.completion-pending-}
    # Only teardown writes these, and it validates the id first. Anything else is
    # hand-placed and could only serve to blind the alarm, so drop it rather than
    # letting an untrusted name drive the match below.
    if ! fm_task_id_path_safe "$id"; then
      rm -f "$marker" 2>/dev/null || true
      continue
    fi
    m=$(fm_sup_stat_mtime "$marker")
    if [ -z "$m" ] || [ "$((now - m))" -ge "$FM_SUP_COMPLETION_PENDING_MAX_AGE" ]; then
      rm -f "$marker" 2>/dev/null || true
      continue
    fi
    case $'\n'"$in_flight"$'\n' in
      *$'\n'"$id"$'\n'*) : ;;
      *) rm -f "$marker" 2>/dev/null || true ;;
    esac
  done
  return 0
}

# fm_sup_display_id <id>
# A bounded, printable rendering of an untrusted backlog id, so a hand-edited row
# can never inject control characters or unbounded text into a banner.
fm_sup_display_id() {
  local rendered
  rendered=$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '?' | cut -c1-60)
  printf '%s\n' "$rendered"
}

# fm_supervision_undispatched <backlog-file> <state-dir> [row-records]
# Print the id of every in-flight backlog row that has no ACTIVE hold, no
# state/<id>.meta, and no fresh completion-pending marker, one per line: work
# recorded as started for which no worker exists, which is what a dropped or
# falsely reported dispatch looks like on disk.
# Two exclusions keep this quiet enough to be worth reading, and both are
# deterministic rather than content heuristics:
#   - An actively held row: a deliberately parked item legitimately keeps an
#     in-flight row after its worker is gone.
#   - A row whose task was just torn down (bin/fm-teardown.sh writes the marker
#     as it removes state/<id>.meta) and has not been filed yet. That window is
#     the ordinary ship-cleanup path, so without this the alarm would fire on
#     every normal completion and train the reader to skim past it.
# A row whose id is not path safe is never used to probe the filesystem; it is
# reported as malformed instead, so a hand-edited row cannot quietly hide work.
# A caller that already holds fm_sup_in_flight_row_records output passes it as
# <row-records>; bin/fm-guard.sh does, so one guarded command parses once.
# Always returns 0.
# Related but deliberately separate: fm-fleet-snapshot.sh's secondmate-home
# summary invalidates a read when an in-flight row has no child metadata. That
# one answers "can a parent trust this summary" and applies no hold exclusion, so
# the two must not be collapsed into each other.
fm_supervision_undispatched() {
  local backlog=$1 state=$2 unheld id now=
  if [ "$#" -ge 3 ]; then
    unheld=$(fm_sup_in_flight_unheld_ids "$backlog" "$3")
  else
    unheld=$(fm_sup_in_flight_unheld_ids "$backlog")
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! fm_task_id_path_safe "$id"; then
      printf 'malformed backlog id: %s\n' "$(fm_sup_display_id "$id")"
      continue
    fi
    [ -e "$state/$id.meta" ] && continue
    [ -n "$now" ] || now=$(date +%s)
    fm_sup_completion_pending_fresh "$state" "$id" "$now" && continue
    printf '%s\n' "$id"
  done <<EOF
$unheld
EOF
  return 0
}
