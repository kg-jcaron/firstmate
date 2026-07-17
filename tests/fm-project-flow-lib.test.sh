#!/usr/bin/env bash
# Behavior tests for bin/fm-project-flow-lib.sh - the single owner of the
# fleet-private per-project custom delivery-workflow note convention.
#
# fm-brief.sh's own test covers brief injection end to end. This file covers the
# lib functions directly, including fm_project_flow_reminder, which is the loud
# at-dispatch reminder bin/fm-spawn.sh prints for a custom-flow ship task - the
# reminder is hard to exercise through a full spawn (it needs a live backend), so
# its text and gating are pinned here at the source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-project-flow-lib.sh
. "$ROOT/bin/fm-project-flow-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-flow-lib)

test_note_path_is_keyed_by_bare_name() {
  local got
  got=$(fm_project_flow_note_path "/x/data" "flowproj")
  assert_contains "$got" "/x/data/project-flows/flowproj.md" \
    "note path is not the documented data/project-flows/<name>.md convention"
  # A "projects/foo" or path-shaped argument resolves to the same bare-name note.
  got=$(fm_project_flow_note_path "/x/data" "projects/flowproj")
  assert_contains "$got" "/x/data/project-flows/flowproj.md" \
    "note path did not reduce a path-shaped project argument to its bare name"
  pass "fm-project-flow-lib: note path follows the bare-name convention"
}

test_note_existence_gating() {
  local data status
  data="$TMP_ROOT/data"
  mkdir -p "$data/project-flows"

  # Absent note: returns non-zero, prints nothing.
  status=0
  fm_project_flow_note "$data" "flowproj" >/dev/null || status=$?
  expect_code 1 "$status" "absent note must return non-zero"

  # Empty note is not a marker.
  : > "$data/project-flows/flowproj.md"
  status=0
  fm_project_flow_note "$data" "flowproj" >/dev/null || status=$?
  expect_code 1 "$status" "empty note must be treated as absent"

  # Non-empty note: returns 0 and prints the path.
  printf 'stage flow\n' > "$data/project-flows/flowproj.md"
  local got
  got=$(fm_project_flow_note "$data" "flowproj")
  expect_code 0 "$?" "present non-empty note must return 0"
  assert_contains "$got" "$data/project-flows/flowproj.md" \
    "present note did not print its own path"
  pass "fm-project-flow-lib: note existence is gated on a non-empty file"
}

test_reminder_fires_only_with_a_note() {
  local data out status
  data="$TMP_ROOT/reminder-data"
  mkdir -p "$data/project-flows"

  # No note: reminder is silent and returns non-zero.
  status=0
  out=$(fm_project_flow_reminder "$data" "flowproj") || status=$?
  expect_code 1 "$status" "reminder must return non-zero when no note exists"
  [ -z "$out" ] || fail "reminder must print nothing when no note exists (got: $out)"

  # With a note: reminder prints the loud CUSTOM_FLOW line naming the project and
  # steering away from the default pipeline.
  printf 'stage flow\n' > "$data/project-flows/flowproj.md"
  out=$(fm_project_flow_reminder "$data" "flowproj")
  expect_code 0 "$?" "reminder must return 0 when a note exists"
  assert_contains "$out" "CUSTOM_FLOW: flowproj" \
    "reminder did not name the project in a CUSTOM_FLOW line"
  assert_contains "$out" "data/project-flows/flowproj.md" \
    "reminder did not point at the note file"
  assert_contains "$out" "not the default no-mistakes-to-PR pipeline" \
    "reminder did not steer away from the default pipeline"
  pass "fm-project-flow-lib: reminder fires only with a note and carries the loud CUSTOM_FLOW line"
}

test_note_path_is_keyed_by_bare_name
test_note_existence_gating
test_reminder_fires_only_with_a_note
