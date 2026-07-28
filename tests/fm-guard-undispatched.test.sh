#!/usr/bin/env bash
# Behavior tests for the claimed-but-never-dispatched guard.
#
# The captain sends asks mid-turn, so firstmate can start an item, pivot to the
# interrupt, and never spawn the worker - then report the work as dispatched.
# On disk that leaves one deterministic signature: a data/backlog.md row under
# "In flight" that is NOT held and has no state/<id>.meta.
# Held rows are excluded on purpose. A deliberately parked item legitimately
# keeps an in-flight row after its worker is gone, and that is common enough
# that including it would make the alarm noise and get it ignored.
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

test_lib_reports_only_unheld_in_flight_without_meta
test_lib_hold_matching_is_exact
test_lib_ignores_body_lines_and_absent_backlog
test_guard_fires_with_no_workers_at_all
test_guard_silent_on_held_and_spawned
test_guard_read_only_reports_without_repair_instruction
test_guard_banner_is_bounded
