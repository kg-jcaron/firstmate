#!/usr/bin/env bash
# Static contract tests for conditional instruction owners introduced before the
# AGENTS.md reduction pass.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIAG="$ROOT/.agents/skills/diagnostic-reasoning/SKILL.md"
PROJECT="$ROOT/.agents/skills/project-management/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CODING="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"
RECOVERY="$ROOT/.agents/skills/stuck-crewmate-recovery/SKILL.md"
SECONDMATE="$ROOT/.agents/skills/secondmate-provisioning/SKILL.md"
SPEC="$ROOT/.agents/skills/spec-linear/SKILL.md"
CONFIG="$ROOT/docs/configuration.md"
AGENTS="$ROOT/AGENTS.md"
BRIEF="$ROOT/bin/fm-brief.sh"

test_new_skill_metadata_and_triggers() {
  local skill name count
  for pair in "diagnostic-reasoning:$DIAG" "project-management:$PROJECT"; do
    name=${pair%%:*}
    skill=${pair#*:}
    assert_present "$skill" "$name skill is missing"
    assert_grep "name: $name" "$skill" "$name skill metadata has the wrong name"
    assert_grep "user-invocable: false" "$skill" "$name skill must not be user-invocable"
    assert_grep "  internal: true" "$skill" "$name skill must be internal"
    count=$(grep -Fc -- "- \`$name\` -" "$ROOT/AGENTS.md")
    [ "$count" -eq 1 ] || fail "$name must have exactly one AGENTS.md trigger entry, found $count"
  done
  assert_grep 'Use before scoping a reported bug and before acting on a diagnostic report.' "$DIAG" \
    "diagnostic skill metadata lost its precise load trigger"
  assert_grep '`diagnostic-reasoning` - load before scoping a reported bug and before acting on a diagnostic report.' "$ROOT/AGENTS.md" \
    "AGENTS.md lost the diagnostic-reasoning trigger"
  assert_grep 'Use before adding, creating, removing, or initializing a project.' "$PROJECT" \
    "project-management skill metadata lost its precise load trigger"
  assert_grep '`project-management` - load before adding, creating, removing, or initializing a project.' "$ROOT/AGENTS.md" \
    "AGENTS.md lost the project-management trigger"
  pass "new internal skills have one precise AGENTS.md trigger each"
}

test_diagnostic_owner_covers_causal_procedure() {
  assert_grep "single owner of Firstmate's bug-diagnosis reasoning procedure" "$DIAG" \
    "diagnostic skill does not declare ownership"
  for phrase in \
    "end-to-end reproduction aligned with the real user path" \
    "initiating trigger" \
    "masking condition" \
    "visible symptom" \
    "proven path" \
    "relevant history" \
    "smallest counterfactual" \
    "disconfirming evidence"; do
    assert_grep "$phrase" "$DIAG" "diagnostic owner is missing '$phrase'"
  done
  assert_grep "evidence, not authorization to change code" "$DIAG" \
    "diagnostic owner lost the diagnosis-only authority boundary"
  pass "diagnostic-reasoning owns the approved evidence procedure"
}

test_project_management_owner_covers_guarded_operations() {
  assert_grep "single owner of Firstmate's project-management procedure" "$PROJECT" \
    "project-management skill does not declare ownership"
  for phrase in \
    'bin/fm-project-mode.sh' \
    '`no-mistakes`' \
    '`direct-PR`' \
    '`local-only`' \
    'Default it off' \
    'Creating a GitHub repository is outward-facing.' \
    "captain's explicit consent" \
    'Never issue a raw removal command from Firstmate.' \
    'no-mistakes init && no-mistakes doctor'; do
    assert_grep "$phrase" "$PROJECT" "project-management owner is missing '$phrase'"
  done
  pass "project-management owns registry, delivery posture, consent, initialization, and removal safety"
}

test_generic_effort_fallback_respects_precedence() {
  local section
  section=$(awk '
    /^Effort precedence is / { found = 1 }
    found && /^The supported launch-profile flags / { exit }
    found { print }
  ' "$HARNESS")
  assert_contains "$section" "explicit per-task captain instruction first" \
    "effort rubric lost per-task captain precedence"
  assert_contains "$section" "standing dispatch profile or secondmate pin" \
    "effort rubric lost standing configuration precedence"
  assert_contains "$section" 'Use `low` for well-understood work' \
    "effort rubric lost its low fallback"
  assert_contains "$section" '`xhigh` for ambiguous investigation or design' \
    "effort rubric lost its xhigh fallback"
  assert_contains "$section" "Choose intermediate levels proportionally" \
    "effort rubric lost proportional intermediate levels"
  assert_contains "$section" 'Never select `max` from this fallback' \
    "effort rubric permits max without an explicit captain preference"
  if printf '%s\n' "$section" | grep -qi sol; then
    fail "generic effort fallback must not contain Sol-specific policy"
  fi
  pass "generic effort fallback applies only below captain and standing configuration"
}

test_shared_authoring_requirements_are_owned() {
  assert_grep "review every affected supported primary harness and runtime backend" "$CODING" \
    "coding guidance lost the supported compatibility matrix review"
  assert_grep "prefer deterministic and idempotent enforcement over relying on agent memory alone" "$CODING" \
    "coding guidance lost deterministic idempotent enforcement"
  assert_grep "critical safety, routing, startup, and supervision infrastructure" "$CODING" \
    "coding guidance lost the critical infrastructure scope"
  pass "firstmate-coding-guidelines owns compatibility review and deterministic enforcement"
}

test_secondmate_registry_contract_stays_concise() {
  local guidance routing_section schema_line
  routing_section=$(awk '
    /^## Routing table$/ { found = 1 }
    found && /^## Charter and seed$/ { exit }
    found { print }
  ' "$SECONDMATE")
  guidance=$(awk '
    /^## Routing table$/ { found = 1 }
    found && /^## Backlog handoff$/ { exit }
    found { print }
  ' "$SECONDMATE")
  schema_line="- <id> - <one-sentence charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)"
  assert_contains "$routing_section" "$schema_line" \
    "secondmate routing table lost the parser-compatible single-line schema"
  assert_contains "$routing_section" "Each registry entry stays concise and single-line" \
    "secondmate routing table no longer requires concise single-line entries"
  assert_contains "$routing_section" "genuinely domain-specific hard rules" \
    "secondmate routing table no longer limits extra prose to domain-specific hard rules"
  assert_contains "$routing_section" "The home-seeded \`data/charter.md\` is the sole owner of boilerplate idle-by-default behavior, the normal delegation lifecycle, and standard escalation contracts" \
    "secondmate routing table lost the explicit charter ownership pointer"
  assert_contains "$routing_section" "no extra registry pointer field is needed" \
    "secondmate routing table no longer explains why the existing home field is the charter pointer"
  for phrase in \
    "go idle and wait silently" \
    "Act only on tasks" \
    "never spawn a survey" \
    "run normal firstmate bootstrap" \
    "escalation back to the main firstmate status file" \
    "requests-from-main-firstmate contract" \
    "waits for routed tasks, never self-initiating a survey or audit" \
    "marked supervisor requests return through status" \
    "unmarked captain messages stay conversational"; do
    if printf '%s\n' "$guidance" | grep -F "$phrase" >/dev/null; then
      fail "secondmate provisioning guidance restated charter boilerplate: $phrase"
    fi
  done
  pass "secondmate registry guidance keeps concise routes and points to the charter"
}

test_state_startup_and_ordinary_recovery_placement() {
  assert_grep "single owner of the top-level operational-home layout" "$CONFIG" \
    "configuration docs do not own the operational state layout"
  assert_grep "header is the single owner of session-start ordering" "$CONFIG" \
    "session-start mechanism is not assigned to the script header"
  assert_grep "Ordinary dead-direct-report recovery is owned by \`stuck-crewmate-recovery\`" "$CONFIG" \
    "D05 ordinary recovery placement is missing"
  assert_grep "## Session-start reconciliation for a dead ordinary direct report" "$RECOVERY" \
    "stuck-crewmate-recovery lacks the dead ordinary direct-report procedure"
  assert_grep "treehouse status" "$RECOVERY" \
    "ordinary recovery lost treehouse inventory inspection"
  assert_grep "recorded \`orca_worktree_id=\` and \`terminal=\`" "$RECOVERY" \
    "ordinary recovery lost Orca inventory inspection"
  assert_grep "session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window" "$AGENTS" \
    "AGENTS.md does not trigger ordinary dead-report recovery"
  pass "state, startup, and ordinary recovery have focused owners and triggers"
}

test_compressed_agents_owner_map() {
  assert_grep '`docs/configuration.md` is the single owner of the top-level operational-home layout' "$AGENTS" \
    "AGENTS.md lost the state-layout owner pointer"
  assert_grep 'header is the single owner of composed commands, ordering, and digest contents' "$AGENTS" \
    "AGENTS.md lost the session-start owner pointer"
  assert_grep '`docs/configuration.md` owns dispatch-profile and runtime-backend schemas' "$AGENTS" \
    "AGENTS.md lost the dispatch-schema owner pointer"
  assert_grep 'That skill owns registry syntax, delivery-mode selection' "$AGENTS" \
    "AGENTS.md lost the project-management owner pointer"
  assert_grep 'The delivery lifecycle is an always-loaded operational contract' "$AGENTS" \
    "AGENTS.md no longer owns the delivery lifecycle"
  assert_grep 'Fleet supervision is an always-loaded operational contract' "$AGENTS" \
    "AGENTS.md no longer owns fleet supervision"
  assert_grep '`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema' "$AGENTS" \
    "AGENTS.md lost the backlog-mechanics owner pointer"
  assert_grep '`bin/fm-brief.sh` and its help own scaffold syntax' "$AGENTS" \
    "AGENTS.md lost the brief-mechanics owner pointer"
  assert_grep '`docs/configuration.md` owns activation, generated state, cadence, wire protocol' "$AGENTS" \
    "AGENTS.md lost the X-mode mechanics owner pointer"
  pass "compressed AGENTS.md records the approved one-owner map"
}

test_compressed_agents_retains_authority_and_supervision_safety() {
  for phrase in \
    'A lock-refused session must not spawn, steer, merge, drain the wake queue' \
    'A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to change code.' \
    'The selected delivery path owns its own rigor.' \
    'When no-mistakes is selected, no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI; otherwise follow the faster path without adding an independent reviewer.' \
    'Never hold work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer authority for one from security, architecture, or risk alone.' \
    'A separate review or audit is allowed only when the captain explicitly requests that deliverable or the authorized task is a knowledge-only review; one named question remains scoped to that question.' \
    'If fast-path risk needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate.' \
    '**local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority' \
    'A status line is a wake event, not current state' \
    'keep exactly one live supervision cycle' \
    'Never broadly kill watchers' \
    'While `state/.afk` exists, the daemon owns supervision' \
    'post the final completion follow-up before teardown'; do
    assert_grep "$phrase" "$AGENTS" "compressed AGENTS.md lost safety phrase '$phrase'"
  done
  assert_no_grep 'Firstmate does not personally review code or deliverables' "$AGENTS" \
    "AGENTS.md retained the weaker duplicate review prohibition"
  assert_no_grep 'firstmate reviews your branch' "$AGENTS" \
    "AGENTS.md retained a personal branch-review requirement"
  assert_no_grep 'firstmate reviews, captain approves' "$BRIEF" \
    "generated brief retained a stacked personal-review requirement"
  if grep -q "$(printf '\342\200\224')" "$AGENTS"; then
    fail "AGENTS.md contains an em dash"
  fi
  pass "compressed AGENTS.md retains authority, supervision, AFK, and X safety"
}

# spec-linear stays captain-invocable, so its trigger cannot live in section 13
# (declared agent-only), and it no longer blocks model invocation, so its
# interactive safeguards have to survive the model-invoked path.
test_spec_linear_is_model_invocable_with_a_declared_trigger() {
  assert_no_grep 'disable-model-invocation' "$SPEC" \
    "spec-linear is still blocked from model invocation"
  assert_grep 'user-invocable: true' "$SPEC" \
    "spec-linear must stay captain-invocable"
  assert_grep 'Use before creating or substantially rewriting a Linear issue or project spec' "$SPEC" \
    "spec-linear metadata lost the trigger a model matches on"
  assert_grep 'Load `spec-linear` before creating or substantially rewriting a Linear issue or project spec' "$AGENTS" \
    "AGENTS.md lost the spec-linear load trigger"
  assert_grep 'firstmate runs this one itself because the flow needs the captain'"'"'s live participation' "$AGENTS" \
    "AGENTS.md must say why this planning deliverable is not delegated to a crewmate"
  assert_no_grep '`spec-linear` - load' "$AGENTS" \
    "spec-linear must not be listed among the agent-only reference skills"
  for phrase in \
    'do not enter it to satisfy some other task' \
    'stop and say so rather than syncing anything to Linear' \
    'Only the user'"'"'s own answer clears this checkpoint' \
    'Never modify an existing spec without that confirmation'; do
    assert_grep "$phrase" "$SPEC" "spec-linear lost an interactive safeguard: '$phrase'"
  done
  pass "spec-linear is model-invocable with a declared trigger and intact safeguards"
}

# The captain sends asks mid-turn, so the durable half of not dropping them is a
# capture rule firstmate reads at intake plus the deterministic guard check.
test_captain_ask_capture_rule_is_stated_at_intake() {
  local intake backlog_contract
  intake=$(awk '
    /^### Intake and authority$/ { found = 1; next }
    found && /^### / { exit }
    found { print }
  ' "$AGENTS")
  assert_contains "$intake" 'Record every captain ask in the backlog as it arrives, before acting on it' \
    "AGENTS.md intake lost the record-before-acting rule"
  assert_contains "$intake" 'A later ask adds work and never supersedes an earlier one unless the captain says so.' \
    "AGENTS.md intake lost the later-ask-does-not-supersede rule"
  assert_grep 'Never tell the captain work is dispatched before that confirmation.' "$AGENTS" \
    "AGENTS.md lost the confirm-before-claiming-dispatch rule"

  # Capturing every ask immediately only stays compatible with the
  # in-flight-with-no-worker alarm while firstmate refuses to record a row as
  # started without a worker, so the backlog contract owns that rule and section
  # 7 must not restate it. The rule constrains what firstmate RECORDS, because a
  # deliberately parked row legitimately keeps its in-flight row after teardown -
  # the very case the alarm's hold exclusion protects.
  backlog_contract=$(awk '
    /^## 10\. Backlog contract$/ { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$AGENTS")
  assert_contains "$backlog_contract" 'Firstmate never records an item as In flight without a live worker for it' \
    "AGENTS.md section 10 lost the never-record-In-flight-without-a-worker rule"
  assert_not_contains "$backlog_contract" 'An item is In flight only while a live worker exists for it' \
    "section 10 still asserts the absolute In-flight invariant, which contradicts the alarm's hold exclusion"
  assert_not_contains "$intake" 'Firstmate never records an item as In flight without a live worker for it' \
    "the In-flight recording rule has one owner in section 10 and must not be restated at intake"
  # Self-run work must be excluded from BOTH the dispatch sweep and the
  # undispatched alarm, which any active hold already does; the reason has to say
  # firstmate is working it so the row does not read as the captain's gate. The
  # kind is parked rather than captain because the decision surfaces and the
  # decision-hold gates key on the captain kind.
  assert_contains "$backlog_contract" 'is recorded as a `parked` hold whose reason states that firstmate is working the row itself and is not awaiting a captain decision' \
    "AGENTS.md section 10 lost the parked-hold routing for work firstmate performs itself"
  assert_contains "$backlog_contract" 'the `captain` hold kind below is the shape the decision surfaces and gates key on and stays reserved for decisions the captain actually owes' \
    "AGENTS.md section 10 lost the parked-versus-captain hold-kind distinction"
  assert_not_contains "$backlog_contract" 'is recorded as a captain-kind hold' \
    "section 10 still routes firstmate-run work to a captain-kind hold, which the decision surfaces read as a captain gate"
  assert_not_contains "$backlog_contract" 'stays Queued until a worker exists' \
    "section 10 still routes firstmate-run work to plain Queued, where the dispatch sweep can spawn it"
  pass "AGENTS.md states the captain-ask capture rule and the In-flight recording rule"
}

test_new_skill_metadata_and_triggers
test_spec_linear_is_model_invocable_with_a_declared_trigger
test_captain_ask_capture_rule_is_stated_at_intake
test_diagnostic_owner_covers_causal_procedure
test_project_management_owner_covers_guarded_operations
test_generic_effort_fallback_respects_precedence
test_shared_authoring_requirements_are_owned
test_secondmate_registry_contract_stays_concise
test_state_startup_and_ordinary_recovery_placement
test_compressed_agents_owner_map
test_compressed_agents_retains_authority_and_supervision_safety
