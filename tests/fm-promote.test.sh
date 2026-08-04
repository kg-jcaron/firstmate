#!/usr/bin/env bash
# Behavior tests for bin/fm-promote.sh.
#
# The promotion path must produce ship instructions through the SAME scaffolding
# and custom-flow injection a fresh ship dispatch uses (bin/fm-brief.sh --promote,
# which owns bin/fm-project-flow-lib.sh injection). These tests pin that a promoted
# scout on a custom-flow project carries the injected flow contract, a promoted
# scout on a no-note project scaffolds the generic delivery-mode instructions, and
# the promotion-specific guarantees (scratch inventory, clean default-branch base,
# carry-over-only, ship branch, reproduced-bug-as-regression-test) survive - all
# while the meta flips scout->ship. fm-guard.sh output is advisory (|| true in the
# script), so its banners are sent to /dev/null here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-promote)

# Seed a home with a project registry (one project per delivery mode) and an
# optional fleet-private custom-flow note for flowproj.
seed_home() {
  local home=$1
  mkdir -p "$home/data/project-flows" "$home/state"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture (added 2026-07-01)
- local-proj [local-only] - fixture (added 2026-07-01)
- flowproj - custom flow fixture (added 2026-07-01)
EOF
  cat > "$home/data/project-flows/flowproj.md" <<'EOF'
Custom stage flow for flowproj:
1. Gate green, then start the dev server for the local visual preview owed to the captain.
2. Push the branch and open a DRAFT PR first.
3. On approval, merge to `stage_builds` and watch the $DEPLOY run.
EOF
}

# Write a scout meta for <id> pointing at <project> (absolute path, as fm-spawn records).
write_scout_meta() {
  local home=$1 id=$2 project=$3
  cat > "$home/state/$id.meta" <<EOF
window=fm-$id
worktree=/tmp/wt/$id
project=/Users/fixture/projects/$project
harness=claude
kind=scout
mode=no-mistakes
EOF
}

run_promote() {  # <home> <id>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-promote.sh" "$2" 2>/dev/null
}

# A promoted scout on a custom-flow project must carry that project's full flow
# contract as its one Definition of done, injected verbatim (backticks and "$"
# survive), with the generic delivery-mode gate absent - identical to a fresh
# ship dispatch. The meta must flip scout->ship.
test_promote_injects_custom_flow() {
  local home id brief status
  home="$TMP_ROOT/custom-flow"
  seed_home "$home"
  id="promote-flow-a1"
  write_scout_meta "$home" "$id" flowproj
  run_promote "$home" "$id" >/dev/null; status=$?
  expect_code 0 "$status" "promoting a custom-flow scout should exit 0"
  brief="$home/data/$id/promote.md"
  assert_present "$brief" "promotion did not scaffold promote.md"
  assert_grep "# Definition of done - MANDATORY custom delivery workflow" "$brief" \
    "promoted custom-flow brief missing the mandatory-flow Definition of done heading"
  assert_grep "only definition of done" "$brief" \
    "promoted custom-flow brief did not claim the flow as its one definition of done"
  assert_grep "local visual preview owed to the captain" "$brief" \
    "promoted custom-flow brief lost the dev-server preview step from the note"
  assert_grep "open a DRAFT PR first" "$brief" \
    "promoted custom-flow brief lost the draft-PR-first step from the note"
  assert_grep "merge to \`stage_builds\`" "$brief" \
    "promoted custom-flow brief lost the stage-merge step from the note"
  # shellcheck disable=SC2016 # Literal "$DEPLOY" must stay unexpanded - that is the assertion.
  assert_grep 'watch the $DEPLOY run' "$brief" \
    "promoted custom-flow brief re-evaluated a \"\$\" in the note body"
  assert_no_grep "complete only when committed on your branch" "$brief" \
    "promoted custom-flow brief kept the generic stop-after-committing gate"
  assert_grep "kind=ship" "$home/state/$id.meta" "promotion did not flip meta to ship"
  assert_no_grep "kind=scout" "$home/state/$id.meta" "promotion left kind=scout in meta"
  pass "fm-promote.sh: a promoted custom-flow scout carries the injected flow contract"
}

# A promoted scout on a project with NO custom-flow note must scaffold the generic
# delivery-mode instructions unchanged: no injected section, generic DOD intact.
test_promote_no_note_scaffolds_generic() {
  local home id brief status
  home="$TMP_ROOT/no-note"
  seed_home "$home"
  id="promote-plain-a2"
  write_scout_meta "$home" "$id" plainproj  # absent from registry -> no-mistakes, no note
  run_promote "$home" "$id" >/dev/null; status=$?
  expect_code 0 "$status" "promoting a no-note scout should exit 0"
  brief="$home/data/$id/promote.md"
  assert_present "$brief" "promotion did not scaffold promote.md for a no-note project"
  assert_no_grep "MANDATORY custom delivery workflow" "$brief" \
    "no-note promotion leaked a custom-flow section"
  assert_no_grep "only definition of done" "$brief" \
    "no-note promotion leaked custom-flow definition-of-done wording"
  assert_grep "# Definition of done" "$brief" \
    "no-note promotion lost its Definition of done section"
  assert_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "no-note promotion lost the no-mistakes delivery-mode Definition of done"
  pass "fm-promote.sh: a no-note promotion scaffolds generic delivery-mode instructions"
}

# The promotion-specific guarantees from AGENTS.md section 7 must survive in the
# generated instructions regardless of custom-flow injection.
test_promote_preserves_promotion_guarantees() {
  local home id brief
  home="$TMP_ROOT/guarantees"
  seed_home "$home"
  id="promote-guarantees-a3"
  write_scout_meta "$home" "$id" flowproj
  run_promote "$home" "$id" >/dev/null
  brief="$home/data/$id/promote.md"
  assert_grep "Inventory your scratch state" "$brief" \
    "promotion brief lost the scratch-state inventory step"
  # shellcheck disable=SC2016 # Literal backticks are brief markdown, not expansions.
  assert_grep 'run `git status` and `git log --oneline`' "$brief" \
    "promotion brief lost the git status/log inventory commands"
  assert_grep "Return to a clean base off the current default branch" "$brief" \
    "promotion brief lost the clean default-branch base instruction"
  assert_grep "carrying over ONLY the intended fix changes" "$brief" \
    "promotion brief lost the carry-over-only-intended-changes instruction"
  assert_grep "must NOT ride along" "$brief" \
    "promotion brief lost the no-scratch-riding-along guarantee"
  assert_grep "becomes the regression test for this fix" "$brief" \
    "promotion brief lost the reproduced-bug-as-regression-test guarantee"
  # shellcheck disable=SC2016 # Literal backticks/branch name are brief markdown.
  assert_grep 'create your ship branch: `git checkout -b fm/promote-guarantees-a3`' "$brief" \
    "promotion brief lost the ship-branch creation step"
  # The promotion brief is self-contained: no literal {TASK} placeholder survives,
  # and the Task section points at the scout's own brief.md and report.md.
  # shellcheck disable=SC2016 # Literal {TASK} is the placeholder we assert is absent.
  assert_no_grep '{TASK}' "$brief" \
    "promotion brief left an unsubstituted {TASK} placeholder"
  assert_grep "recorded in $home/data/$id/brief.md and $home/data/$id/report.md" "$brief" \
    "promotion brief lost the self-contained pointer to the scout's brief.md and report.md"
  pass "fm-promote.sh: promotion guarantees survive in the generated instructions"
}

# direct-PR and local-only promotions must carry the mode-specific Definition of
# done and must NOT append the no-mistakes doctor/init Setup step.
test_promote_preserves_delivery_mode() {
  local home id brief
  home="$TMP_ROOT/modes"
  seed_home "$home"

  id="promote-direct-a4"
  write_scout_meta "$home" "$id" direct-proj
  run_promote "$home" "$id" >/dev/null
  brief="$home/data/$id/promote.md"
  assert_grep "This project ships **direct-PR**" "$brief" \
    "direct-PR promotion lost its delivery-mode Definition of done"
  assert_no_grep "Run \`no-mistakes doctor\`" "$brief" \
    "direct-PR promotion wrongly added the no-mistakes doctor/init step"

  id="promote-local-a5"
  write_scout_meta "$home" "$id" local-proj
  run_promote "$home" "$id" >/dev/null
  brief="$home/data/$id/promote.md"
  assert_grep "This project ships **local-only**" "$brief" \
    "local-only promotion lost its delivery-mode Definition of done"
  assert_no_grep "Run \`no-mistakes doctor\`" "$brief" \
    "local-only promotion wrongly added the no-mistakes doctor/init step"
  pass "fm-promote.sh: promotion preserves the project's delivery mode"
}

# A non-scout task must be refused without flipping meta or writing instructions.
test_promote_refuses_non_scout() {
  local home id status
  home="$TMP_ROOT/non-scout"
  seed_home "$home"
  id="promote-ship-a6"
  cat > "$home/state/$id.meta" <<EOF
project=/Users/fixture/projects/flowproj
kind=ship
EOF
  run_promote "$home" "$id" >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "promoting a non-scout task must fail"
  assert_absent "$home/data/$id/promote.md" "a refused promotion still wrote instructions"
  pass "fm-promote.sh: refuses to promote a non-scout task"
}

# A scout meta with no project= cannot resolve delivery mode, so promotion must
# fail loudly rather than scaffold generic instructions against the wrong project.
test_promote_requires_project() {
  local home id status
  home="$TMP_ROOT/no-project"
  seed_home "$home"
  id="promote-noproj-a7"
  cat > "$home/state/$id.meta" <<EOF
window=fm-$id
kind=scout
EOF
  run_promote "$home" "$id" >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "promotion with no recorded project must fail"
  assert_grep "kind=scout" "$home/state/$id.meta" "a failed promotion still flipped meta to ship"
  pass "fm-promote.sh: refuses to promote when no project is recorded"
}

test_promote_injects_custom_flow
test_promote_no_note_scaffolds_generic
test_promote_preserves_promotion_guarantees
test_promote_preserves_delivery_mode
test_promote_refuses_non_scout
test_promote_requires_project
