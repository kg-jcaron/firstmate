#!/usr/bin/env bash
# Behavior tests for the claimed-but-never-dispatched guard.
#
# The captain sends asks mid-turn, so firstmate can start an item, pivot to the
# interrupt, and never spawn the worker - then report the work as dispatched.
# On disk that leaves one deterministic signature: a data/backlog.md row under
# "In flight" that is NOT held and has no state/<id>.meta.
# Two exclusions keep it quiet, and both are deterministic rather than content
# heuristics:
#   - An ACTIVE hold. A deliberately parked item legitimately keeps an in-flight
#     row after its worker is gone. A hold whose hold-until date has arrived is
#     NOT active - tasks-axi treats the gate as inactive on and after that date -
#     so a lapsed gate is dispatchable work the alarm must report.
#   - A fresh completion-pending marker written by bin/fm-teardown.sh as it
#     removes state/<id>.meta. Filing the row Done is the step AFTER teardown, so
#     without this the alarm would fire on every ordinary ship cleanup and train
#     the reader to skim past it. The marker expires and self-clears so it can
#     never blind the alarm for a row that really was dropped.
# These cases pin both halves: the shared lib predicate in
# bin/fm-supervision-lib.sh, and the fm-guard banner that surfaces it on the
# next fleet action. The false-positive cases matter as much as the true one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard-undispatched)

BANNER='BACKLOG SAYS STARTED - NO WORKER EXISTS'

# A home with the given backlog body under "In flight". Echoes the case dir.
make_case() {
  local name=$1 dir home
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$dir/root"
  cat > "$home/data/backlog.md"
  printf '%s\n' "$dir"
}

case_home() {
  printf '%s/home\n' "$1"
}

run_guard() {
  local dir=$1
  FM_ROOT_OVERRIDE="$1/root" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

run_guard_read_only() {
  local dir=$1
  FM_ROOT_OVERRIDE="$1/root" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_GUARD_READ_ONLY=1 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# run_guard_with <dir> <VAR=value> ... : run the guard with extra environment.
run_guard_with() {
  local dir=$1
  shift
  env FM_ROOT_OVERRIDE="$dir/root" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    "$@" \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

completion_marker() {
  printf '%s/state/.completion-pending-%s\n' "$(case_home "$1")" "$2"
}

count_text() {
  local haystack=$1 needle=$2
  awk -v needle="$needle" 'index($0, needle) { c++ } END { print c + 0 }' <<EOF
$haystack
EOF
}

undispatched_of() {
  local dir=$1 home
  home=$(case_home "$dir")
  fm_supervision_undispatched "$home/data/backlog.md" "$home/state"
}

# --- shared lib: the predicate itself ---------------------------------------

# One backlog exercising every discriminator at once: a spawned item, a held
# item, a never-spawned item, and rows in the wrong sections.
test_lib_reports_only_unheld_in_flight_without_meta() {
  local dir home out
  dir=$(make_case lib-mixed <<'EOF'
# Backlog

## In flight
- [ ] spawned - Has a live worker (repo: sample) (kind: ship) (since 2026-07-28)
- [ ] ghost - Recorded as started, never spawned (repo: sample) (kind: ship) (since 2026-07-28)
- [ ] parked - Deliberately parked after teardown (repo: sample) (kind: ship) (hold: awaiting captain review of PR 678) (hold-kind: captain)
- **bold-ghost-row** - Alternate row form, never spawned (repo: sample) (kind: scout)

## Queued
- [ ] not-started - Queued work has no worker by definition (repo: sample) (kind: ship)

## Done
- [x] landed - Already filed (repo: sample) (kind: ship) (done 2026-07-27)
EOF
  )
  home=$(case_home "$dir")
  fm_write_meta "$home/state/spawned.meta" "window=firstmate:fm-spawned" "kind=ship"

  out=$(undispatched_of "$dir")
  [ "$out" = "ghost
bold-ghost-row" ] || fail "predicate reported the wrong ids, got: $out"
  pass "undispatched predicate: only unheld in-flight rows with no metadata"
}

# A hold reason is free text the captain wrote and can be long, multi-clause, and
# full of punctuation. It must still exclude the row, and "hold-kind:" alone must
# never be mistaken for a hold reason.
test_lib_hold_matching_is_exact() {
  local dir out
  dir=$(make_case lib-holds <<'EOF'
## In flight
- [ ] long-hold - Long parked item (repo: sample) (kind: ship) (hold: CONSOLIDATED into PR 691 - both halves, 52 files, CI green, still DRAFT. CAPTAIN GATE: run pulumi -s stage up first.) (hold-kind: captain)
- [ ] kind-only - Carries hold-kind but no hold reason (repo: sample) (kind: ship) (hold-kind: captain)
- [ ] comma-hold - Comma-separated metadata, repo: sample, hold: waiting on the captain
EOF
  )
  out=$(undispatched_of "$dir")
  [ "$out" = "kind-only" ] || fail "hold matching is wrong, expected only kind-only, got: $out"
  pass "undispatched predicate: only a real hold reason excludes a row"
}

# Free-form body lines sit under a row and can say anything, including the word
# hold and things that look like list rows. They are not rows and never count.
test_lib_ignores_body_lines_and_absent_backlog() {
  local dir out
  dir=$(make_case lib-bodies <<'EOF'
## In flight
- [ ] ghost - Never spawned (repo: sample) (kind: ship)
  GATED on the other release. Do not resolve while only on stage.
  - a nested bullet in the body, not a backlog row
EOF
  )
  out=$(undispatched_of "$dir")
  [ "$out" = "ghost" ] || fail "body lines leaked into the predicate, got: $out"

  out=$(fm_supervision_undispatched "$TMP_ROOT/nope/backlog.md" "$TMP_ROOT/nope")
  [ -z "$out" ] || fail "absent backlog should report nothing, got: $out"
  pass "undispatched predicate: body lines and an absent backlog report nothing"
}

# --- fm-guard: the surface that gets read -----------------------------------

# The alarm has to fire with ZERO workers alive, which is exactly the state the
# watcher-liveness block exits early on, so it must be checked before that exit.
test_guard_fires_with_no_workers_at_all() {
  local dir out
  dir=$(make_case guard-fires <<'EOF'
## In flight
- [ ] ghost - Told the captain this was dispatched (repo: sample) (kind: ship)
EOF
  )
  out=$(run_guard "$dir")
  assert_contains "$out" "$BANNER" "guard stayed silent on a claimed-but-never-dispatched item"
  assert_contains "$out" "ghost" "guard banner did not name the offending item"
  assert_contains "$out" "1 backlog item(s) are in flight" "guard banner lost its count line"
  assert_contains "$out" "Do not report these as dispatched" "guard banner lost its remedy line"
  assert_not_contains "$out" "WATCHER DOWN" "no worker exists, so the watcher banner must not fire"
  pass "fm-guard undispatched: fires when no worker exists at all"
}

# The quiet case. A held item plus a genuinely spawned item is an ordinary,
# healthy fleet and must produce nothing from this alarm.
test_guard_silent_on_held_and_spawned() {
  local dir home out
  dir=$(make_case guard-silent <<'EOF'
## In flight
- [ ] spawned - Live worker (repo: sample) (kind: ship)
- [ ] parked - Parked after teardown (repo: sample) (kind: ship) (hold: awaiting captain decision) (hold-kind: captain)
EOF
  )
  home=$(case_home "$dir")
  fm_write_meta "$home/state/spawned.meta" "window=firstmate:fm-spawned" "kind=ship"
  touch "$home/state/.last-watcher-beat"

  out=$(run_guard "$dir")
  [ -z "$out" ] || fail "guard must stay silent on a held item and a spawned item, got: $out"
  pass "fm-guard undispatched: silent on a legitimately held item"
}

# A read-only session (another session holds the fleet lock) reports the gap
# instead of being told to repair it, matching the other read-only guard wording.
test_guard_read_only_reports_without_repair_instruction() {
  local dir out
  dir=$(make_case guard-read-only <<'EOF'
## In flight
- [ ] ghost - Never spawned (repo: sample) (kind: ship)
EOF
  )
  out=$(run_guard_read_only "$dir")
  assert_contains "$out" "$BANNER" "read-only guard dropped the undispatched alarm"
  assert_contains "$out" "report the gap, not repair it" "read-only guard lost its advisory wording"
  assert_not_contains "$out" "Do not report these as dispatched" \
    "read-only guard must not hand out the repair instruction"
  pass "fm-guard undispatched: read-only reports the gap without repair wording"
}

# The banner is bounded so a neglected backlog cannot flood every fleet command,
# but the count line still tells the truth about the total.
test_guard_banner_is_bounded() {
  local dir out listed
  {
    printf '## In flight\n'
    for i in 1 2 3 4 5 6 7; do
      printf -- '- [ ] ghost-%s - Never spawned (repo: sample) (kind: ship)\n' "$i"
    done
  } > "$TMP_ROOT/bounded-backlog.md"
  dir=$(make_case guard-bounded < "$TMP_ROOT/bounded-backlog.md")

  out=$(run_guard "$dir")
  assert_contains "$out" "7 backlog item(s) are in flight" "banner count must report the true total"
  assert_contains "$out" "and 2 more" "banner must say how many ids it withheld"
  listed=$(printf '%s\n' "$out" | grep -c 'ghost-' || true)
  [ "$listed" -eq 5 ] || fail "banner should list exactly 5 ids, listed $listed"
  pass "fm-guard undispatched: banner bounds the id list and reports the true count"
}

# tasks-axi's date gate is inactive ON and after its date, so a lapsed hold is
# dispatchable work again and AGENTS.md section 10 treats a cleared time gate as a
# dispatch trigger. Excluding it forever would hide the exact case the alarm is for.
test_lib_lapsed_hold_until_is_not_a_hold() {
  local dir out today past future
  today=$(date +%Y-%m-%d)
  past=$(date -u -r 0 +%Y-%m-%d 2>/dev/null || echo 1970-01-01)
  future=9999-12-31
  dir=$(make_case lib-hold-until <<EOF
## In flight
- [ ] lapsed - Gate has passed (repo: sample) (kind: ship) (hold: start after launch) (hold-kind: future) (hold-until: $past)
- [ ] today-gate - Gate arrives today, inactive on the day itself (repo: sample) (kind: ship) (hold: start after launch) (hold-kind: future) (hold-until: $today)
- [ ] still-gated - Gate is still ahead (repo: sample) (kind: ship) (hold: start after launch) (hold-kind: future) (hold-until: $future)
- [ ] open-hold - Held with no date at all (repo: sample) (kind: ship) (hold: awaiting captain decision) (hold-kind: captain)
EOF
  )
  out=$(undispatched_of "$dir")
  [ "$out" = "lapsed
today-gate" ] || fail "hold-until handling is wrong, expected the lapsed gates only, got: $out"
  pass "undispatched predicate: a lapsed hold-until is reported, a future one stays held"
}

# A hand-edited row must never steer a filesystem probe out of the state dir, and
# must never be able to hide itself by doing so.
test_lib_malformed_id_is_surfaced_not_used_as_a_path() {
  local dir home out
  dir=$(make_case lib-malformed <<'EOF'
## In flight
- [ ] ../outside - Hand-edited row (repo: sample) (kind: ship)
- [ ] ghost - Never spawned (repo: sample) (kind: ship)
EOF
  )
  home=$(case_home "$dir")
  # The path an unvalidated "$state/$id.meta" probe would have consulted. Its
  # presence must not suppress the row.
  fm_write_meta "$home/outside.meta" "window=firstmate:fm-outside" "kind=ship"

  out=$(undispatched_of "$dir")
  [ "$out" = "malformed backlog id: ..?outside
ghost" ] || fail "malformed id was not surfaced safely, got: $out"
  pass "undispatched predicate: a malformed id is reported, never used as a path"
}

# --- the teardown-to-filing window ------------------------------------------

# Filing the row Done is the step AFTER teardown, so the marker is what keeps the
# ordinary ship cleanup quiet. It must not be a permanent blindfold.
test_marker_silences_only_while_fresh() {
  local dir home out
  dir=$(make_case marker-window <<'EOF'
## In flight
- [ ] torn-down - Worker cleaned up, row not filed yet (repo: sample) (kind: ship)
- [ ] ghost - Recorded as started, never spawned (repo: sample) (kind: ship)
EOF
  )
  home=$(case_home "$dir")
  : > "$(completion_marker "$dir" torn-down)"

  out=$(undispatched_of "$dir")
  [ "$out" = "ghost" ] || fail "a freshly torn-down row should be silent while a never-spawned row fires, got: $out"

  # Expired: the same row must surface again rather than stay hidden forever.
  # The override is scoped to the command substitution's subshell.
  out=$(FM_SUP_COMPLETION_PENDING_MAX_AGE=0; undispatched_of "$dir")
  [ "$out" = "torn-down
ghost" ] || fail "an expired marker must stop excluding its row, got: $out"

  # Removed by the sweep once the row is filed: same result.
  rm -f "$(completion_marker "$dir" torn-down)"
  out=$(undispatched_of "$dir")
  [ "$out" = "torn-down
ghost" ] || fail "a removed marker must stop excluding its row, got: $out"
  pass "undispatched predicate: a teardown marker silences its row only while fresh"
}

# The marker set must stay bounded and self-clearing: filed rows and aged markers
# both get swept, so a home cannot accumulate blindfolds.
test_sweep_clears_filed_and_expired_markers() {
  local dir home
  dir=$(make_case marker-sweep <<'EOF'
## In flight
- [ ] still-in-flight - Torn down, not filed yet (repo: sample) (kind: ship)

## Done
- [x] filed - Already filed (repo: sample) (kind: ship) (done 2026-07-29)
EOF
  )
  home=$(case_home "$dir")
  : > "$(completion_marker "$dir" still-in-flight)"
  : > "$(completion_marker "$dir" filed)"

  fm_supervision_sweep_completion_pending "$home/data/backlog.md" "$home/state"
  assert_present "$(completion_marker "$dir" still-in-flight)" \
    "sweep must keep the marker of a row that is still in flight"
  assert_absent "$(completion_marker "$dir" filed)" \
    "sweep must drop the marker of a row that has been filed"

  # A hand-placed marker whose name is not a safe id could only blind the alarm,
  # and a glob-shaped one would otherwise match every row. It gets dropped.
  : > "$(completion_marker "$dir" '*')"
  fm_supervision_sweep_completion_pending "$home/data/backlog.md" "$home/state"
  assert_absent "$(completion_marker "$dir" '*')" \
    "sweep must drop a marker whose name is not a safe task id"
  assert_present "$(completion_marker "$dir" still-in-flight)" \
    "dropping an unsafe marker must not disturb a legitimate one"

  (
    FM_SUP_COMPLETION_PENDING_MAX_AGE=0
    fm_supervision_sweep_completion_pending "$home/data/backlog.md" "$home/state"
  )
  assert_absent "$(completion_marker "$dir" still-in-flight)" \
    "sweep must drop a marker past its max age"
  pass "undispatched predicate: the marker set is self-clearing and bounded"
}

# The regression this whole exclusion exists for: the real cleanup path is
# bin/fm-teardown.sh removing state/<id>.meta, then calling bin/fm-fleet-sync.sh,
# which calls bin/fm-guard.sh - all while the row is still in flight and unfiled.
test_real_teardown_path_is_quiet() {
  local dir home case_dir out
  dir=$(make_case teardown-quiet <<'EOF'
## In flight
- [ ] task-x1 - Ship task being cleaned up right now (repo: sample) (kind: ship)
EOF
  )
  home=$(case_home "$dir")
  case_dir="$dir/teardown"
  mkdir -p "$case_dir/fakebin"
  for tool in treehouse tmux gh-axi gh tasks-axi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fakebin/$tool"
    chmod +x "$case_dir/fakebin/$tool"
  done

  # A landed ship task: the worktree branch carries no work beyond origin/main,
  # so teardown's landed-work check allows the cleanup.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  fm_write_meta "$home/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  touch "$home/state/.last-watcher-beat"

  out=$(env FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_GUARD_GRACE=999 \
    PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" task-x1 2>&1) || fail "teardown failed on a landed ship task: $out"

  assert_not_contains "$out" "$BANNER" \
    "ordinary ship cleanup must not raise the claimed-but-never-dispatched alarm"
  assert_present "$(completion_marker "$dir" task-x1)" \
    "teardown must record that the row is awaiting its filing"

  # And still quiet on any guarded command run between cleanup and filing, which
  # is the normal next step - not just inside teardown's own fleet-sync call.
  out=$(run_guard "$dir")
  assert_not_contains "$out" "$BANNER" \
    "a guarded command between cleanup and filing must stay quiet too"
  pass "fm-guard undispatched: the real teardown-to-filing window is quiet"
}

# --- banner behavior --------------------------------------------------------

# The alarm persists until the agent acts, so without episode dedup its bordered
# banner would repaint on every fleet command and push the watcher alarm down.
test_guard_banner_dedups_per_episode() {
  local dir home out1 out2 out3 marker lines
  dir=$(make_case guard-dedup <<'EOF'
## In flight
- [ ] ghost - Never spawned (repo: sample) (kind: ship)
EOF
  )
  home=$(case_home "$dir")
  marker="$home/state/.guard-undispatched-banner"

  out1=$(run_guard "$dir")
  [ "$(count_text "$out1" "$BANNER")" -eq 1 ] || fail "first call did not print exactly one full banner: $out1"
  out2=$(run_guard "$dir")
  [ "$(count_text "$out2" "$BANNER")" -eq 0 ] || fail "second call repeated the full banner: $out2"
  assert_contains "$out2" "full banner already printed this episode" \
    "second call did not print the concise reminder"
  lines=$(awk 'END { print NR + 0 }' "$marker")
  [ "$lines" -le 1 ] || fail "undispatched banner marker must stay bounded to one line, got $lines"

  # A changed id set is a new episode, so a newly dropped item is never hidden
  # behind an already-announced one.
  printf -- '- [ ] second-ghost - Also never spawned (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  out3=$(run_guard "$dir")
  [ "$(count_text "$out3" "$BANNER")" -eq 1 ] || fail "a changed id set must start a new episode: $out3"
  assert_contains "$out3" "second-ghost" "new episode banner must name the newly dropped item"
  pass "fm-guard undispatched: full banner prints once per distinct id set"
}

# Once the agent acts, the episode ends, so a later recurrence is loud again.
test_guard_banner_rearms_after_condition_clears() {
  local dir home out
  dir=$(make_case guard-rearm <<'EOF'
## In flight
- [ ] ghost - Never spawned (repo: sample) (kind: ship)
EOF
  )
  home=$(case_home "$dir")
  run_guard "$dir" >/dev/null
  fm_write_meta "$home/state/ghost.meta" "window=firstmate:fm-ghost" "kind=ship"
  touch "$home/state/.last-watcher-beat"

  out=$(run_guard "$dir")
  [ -z "$out" ] || fail "guard should be silent once the item has a worker, got: $out"
  assert_absent "$home/state/.guard-undispatched-banner" \
    "a cleared condition must end the episode"

  rm -f "$home/state/ghost.meta"
  out=$(run_guard "$dir")
  [ "$(count_text "$out" "$BANNER")" -eq 1 ] || fail "a later recurrence must re-print the full banner: $out"
  pass "fm-guard undispatched: a cleared condition rearms the next episode"
}

# Same read-only contract the watcher banner has: observe, never write.
test_guard_read_only_never_mutates_state() {
  local dir home before after out
  dir=$(make_case guard-read-only-state <<'EOF'
## In flight
- [ ] ghost - Never spawned (repo: sample) (kind: ship)
- [ ] torn-down - Cleanup marker must survive a read-only pass (repo: sample) (kind: ship)
EOF
  )
  home=$(case_home "$dir")
  : > "$(completion_marker "$dir" torn-down)"

  out=$(run_guard_read_only "$dir")
  [ "$(count_text "$out" "$BANNER")" -eq 1 ] || fail "read-only guard should print the advisory banner: $out"
  assert_absent "$home/state/.guard-undispatched-banner" \
    "read-only guard must not create the undispatched banner marker"
  assert_absent "$home/state/.guard-undispatched-banner.lock" \
    "read-only guard must not create the undispatched banner lock"
  assert_present "$(completion_marker "$dir" torn-down)" \
    "read-only guard must not sweep completion-pending markers"

  # A writable call afterwards still owns the first full banner, and a read-only
  # call inside a claimed episode observes without touching the marker.
  out=$(run_guard "$dir")
  [ "$(count_text "$out" "$BANNER")" -eq 1 ] || fail "writable call should still get the full banner: $out"
  before=$(cat "$home/state/.guard-undispatched-banner")
  out=$(run_guard_read_only "$dir")
  after=$(cat "$home/state/.guard-undispatched-banner")
  assert_contains "$out" "full banner already printed this episode" \
    "read-only call during a claimed episode should print the concise reminder"
  [ "$after" = "$before" ] || fail "read-only call must not update an existing marker"
  pass "fm-guard undispatched: read-only observes without mutating any state file"
}

# The other alarms are independent in both directions; neither dedup silences the
# other, and the queued-wake warning is never suppressed.
test_guard_alarms_stay_independent() {
  local dir home out
  dir=$(make_case guard-independent <<'EOF'
## In flight
- [ ] ghost - Never spawned (repo: sample) (kind: ship)
- [ ] spawned - Live worker, but the watcher is down (repo: sample) (kind: ship)
EOF
  )
  home=$(case_home "$dir")
  fm_write_meta "$home/state/spawned.meta" "window=firstmate:fm-spawned" "kind=ship"
  printf 'signal: %s/state/spawned.status\n' "$home" > "$home/state/.wake-queue"

  out=$(run_guard "$dir")
  assert_contains "$out" "$BANNER" "the undispatched alarm must fire alongside the others"
  assert_contains "$out" "WATCHER DOWN" "the undispatched alarm must not suppress the watcher banner"
  assert_contains "$out" "queued wakes pending" "the undispatched alarm must not suppress the queued-wake warning"

  # Second pass: the undispatched episode is claimed, but the others are untouched.
  out=$(run_guard "$dir")
  assert_contains "$out" "queued wakes pending" \
    "undispatched dedup must never suppress the queued-wake warning"
  assert_not_contains "$out" "$BANNER" "the undispatched banner should be deduped by now"
  pass "fm-guard undispatched: alarms stay independent in both directions"
}

# A bad override must never leak a shell error into the middle of the banner or
# produce a banner that names no ids while claiming none were withheld.
test_guard_list_max_override_is_validated() {
  local dir out listed value
  {
    printf '## In flight\n'
    for i in 1 2 3 4 5 6 7; do
      printf -- '- [ ] ghost-%s - Never spawned (repo: sample) (kind: ship)\n' "$i"
    done
  } > "$TMP_ROOT/list-max-backlog.md"

  for value in abc '' 0 -3; do
    dir=$(make_case "guard-list-max-$(printf '%s' "${value:-empty}" | tr -c 'a-z0-9' '_')" < "$TMP_ROOT/list-max-backlog.md")
    out=$(run_guard_with "$dir" "FM_GUARD_UNDISPATCHED_LIST_MAX=$value")
    assert_contains "$out" "$BANNER" "override '$value' lost the banner"
    assert_contains "$out" "7 backlog item(s) are in flight" "override '$value' broke the true count"
    assert_not_contains "$out" "integer expression expected" "override '$value' leaked a shell error"
    assert_not_contains "$out" "head:" "override '$value' leaked a head error"
    listed=$(printf '%s\n' "$out" | grep -c 'ghost-' || true)
    [ "$listed" -ge 1 ] || fail "override '$value' produced a banner that named no ids"
    [ "$listed" -le 7 ] || fail "override '$value' listed more ids than exist"
  done
  pass "fm-guard undispatched: a bad list-max override is clamped, never leaked"
}

test_lib_reports_only_unheld_in_flight_without_meta
test_lib_hold_matching_is_exact
test_lib_lapsed_hold_until_is_not_a_hold
test_lib_malformed_id_is_surfaced_not_used_as_a_path
test_lib_ignores_body_lines_and_absent_backlog
test_marker_silences_only_while_fresh
test_sweep_clears_filed_and_expired_markers
test_guard_fires_with_no_workers_at_all
test_guard_silent_on_held_and_spawned
test_real_teardown_path_is_quiet
test_guard_read_only_reports_without_repair_instruction
test_guard_banner_is_bounded
test_guard_banner_dedups_per_episode
test_guard_banner_rearms_after_condition_clears
test_guard_read_only_never_mutates_state
test_guard_alarms_stay_independent
test_guard_list_max_override_is_validated
