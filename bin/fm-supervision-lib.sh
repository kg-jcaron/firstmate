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

# fm_sup_in_flight_unheld_ids <backlog-file>
# Print the id of every structured backlog row under the "In flight" heading
# that carries no "hold:" metadata, one per line. Understands both row forms the
# tasks-axi markdown backend writes: "- [ ] <id> - ..." and "- **<id>** - ...".
# "hold-kind:" is deliberately not a match; only a real "hold:" reason excludes a
# row. Silent for an absent or headingless backlog.
fm_sup_in_flight_unheld_ids() {
  local backlog=$1
  [ -f "$backlog" ] || return 0
  awk '
    /^#/ {
      section = $0
      sub(/^#+[ \t]*/, "", section)
      sub(/[ \t]+$/, "", section)
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
      if ($0 ~ /\([ \t]*hold:/ || $0 ~ /,[ \t]*hold:/) next
      print id
    }
  ' "$backlog"
}

# fm_supervision_undispatched <backlog-file> <state-dir>
# Print the id of every in-flight, unheld backlog row that has no
# state/<id>.meta, one per line: work recorded as started for which no worker
# exists, which is what a dropped or falsely reported dispatch looks like on
# disk. Held rows are excluded because a deliberately parked item legitimately
# keeps an in-flight row after its worker is gone, and that exclusion is what
# keeps this quiet enough to be worth reading. Always returns 0.
# Related but deliberately separate: fm-fleet-snapshot.sh's secondmate-home
# summary invalidates a read when an in-flight row has no child metadata. That
# one answers "can a parent trust this summary" and applies no hold exclusion, so
# the two must not be collapsed into each other.
fm_supervision_undispatched() {
  local backlog=$1 state=$2 id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -e "$state/$id.meta" ] && continue
    printf '%s\n' "$id"
  done <<EOF
$(fm_sup_in_flight_unheld_ids "$backlog")
EOF
  return 0
}
