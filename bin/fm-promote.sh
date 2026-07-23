#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown
# protection again, and scaffolds the ship instructions through bin/fm-brief.sh
# --promote (which resolves the project's delivery mode and injects any custom
# delivery-workflow contract, exactly like a fresh ship dispatch) to
# data/<task-id>/promote.md. After promoting, send the crewmate a one-line pointer
# to those instructions via fm-send.sh; they direct it to inventory scratch state,
# reset to a clean default-branch base, carry over only the intended fix, create
# branch fm/<task-id>, implement, then report done according to the delivery flow.
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

# Resolve the project from the scout's recorded metadata so the ship instructions
# get the same delivery-mode selection and custom-flow injection a fresh ship
# dispatch would. project= is an absolute path; fm-brief keys on its bare name.
PROJECT_PATH=$(grep '^project=' "$META" | head -n1 | cut -d= -f2-)
[ -n "$PROJECT_PATH" ] || { echo "error: no project recorded in $META; cannot scaffold ship instructions" >&2; exit 1; }
PROJECT_NAME=$(basename "$PROJECT_PATH")

# Scaffold the ship instructions BEFORE flipping the meta, so a scaffold failure
# leaves the task an untouched scout. fm-brief refuses to overwrite, so clear a
# stale promote.md from an earlier attempt first.
PROMOTE_BRIEF="$DATA/$ID/promote.md"
rm -f "$PROMOTE_BRIEF"
FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-brief.sh" "$ID" "$PROJECT_NAME" --promote >/dev/null

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
echo "ship instructions scaffolded at $PROMOTE_BRIEF"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID 'You are promoted from scout to ship: read and follow your ship instructions at $PROMOTE_BRIEF.'"
