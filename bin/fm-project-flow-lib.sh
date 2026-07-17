#!/usr/bin/env bash
# fm-project-flow-lib.sh - fleet-private per-project custom delivery-workflow notes.
#
# THE PROBLEM this closes: a few projects ship through a custom delivery workflow
# (e.g. a mandatory local dev-server visual preview, a draft-PR-first step, a
# stage-branch merge) that is NOT the default no-mistakes-to-PR pipeline. That
# contract used to live only in curated prose (data/learnings.md), which a full
# session start loads but /bearings, /clear, and a post-compaction resume do NOT.
# A ship brief dispatched from such a session carried none of it, so the crewmate
# ran the wrong flow. The old safeguard was a prose rule telling the agent to
# remember to read the file first - a memory-based safeguard that fails under
# exactly the conditions where the knowledge is not loaded.
#
# THE MECHANISM (this lib) is the structural fix: a ship brief for a custom-flow
# project always carries that project's workflow contract, injected at scaffold
# time, and dispatch prints a loud reminder - both driven by a file on disk, not
# by the agent remembering. This lib is the SINGLE OWNER of the convention below;
# bin/fm-brief.sh (injection) and bin/fm-spawn.sh (dispatch reminder) both call
# these functions rather than re-deriving the path.
#
# THE CONVENTION (generic mechanism, fleet-private data): a project's custom
# delivery workflow lives in a note at
#     $FM_HOME/data/project-flows/<project-name>.md
# keyed by the project's bare name (the same name resolved by fm-project-mode.sh
# and used as the basename of the project checkout). data/ is gitignored as a
# whole, so these notes are fleet-private - the shared template carries the
# mechanism, never the list of which projects have custom flows. The EXISTENCE of
# a non-empty note is itself the marker: no project name is ever hardcoded in
# tracked bin/ code, so a generic install with no notes behaves exactly as before.
#
# ONE-OWNER RULE: the note file is the single source of truth for a project's
# custom delivery workflow. Firstmate keeps the canonical contract here and leaves
# only a one-line pointer wherever it used to live (data/learnings.md), so the
# injected brief and the human-readable record never drift. The project-management
# skill owns firstmate's authoring guidance; docs/configuration.md documents the
# convention for humans.
#
# No side effects on source. set -u / set -e safe.

# fm_project_flow_note_path <data-dir> <project-name>
#   Print the conventional note path for a project. Pure string transform; does
#   NOT check existence. Keyed by the bare project name (basename), so a caller
#   that passes "projects/foo" or "foo" resolves to the same note.
fm_project_flow_note_path() {
  local data=$1 name=$2
  printf '%s/project-flows/%s.md\n' "$data" "$(basename "$name")"
}

# fm_project_flow_note <data-dir> <project-name>
#   Print the note path and return 0 when a non-empty custom-flow note exists for
#   the project; print nothing and return 1 otherwise. An empty file does not
#   count as a marker (it would inject an empty mandatory section).
fm_project_flow_note() {
  local data=$1 name=$2 path
  path=$(fm_project_flow_note_path "$data" "$name")
  [ -s "$path" ] || return 1
  printf '%s\n' "$path"
}

# fm_project_flow_reminder <data-dir> <project-name>
#   Print the loud one-line dispatch reminder when the project has a custom-flow
#   note; print nothing and return 1 otherwise. The caller routes it to stderr so
#   it is unmissable in spawn output. The reminder fires from the note on disk,
#   not from the agent remembering, which is the whole point.
fm_project_flow_reminder() {
  local data=$1 name=$2 base
  fm_project_flow_note "$data" "$name" >/dev/null || return 1
  base=$(basename "$name")
  printf 'CUSTOM_FLOW: %s ships via a custom delivery workflow (data/project-flows/%s.md); the brief carries its full contract - follow that flow, not the default no-mistakes-to-PR pipeline.\n' "$base" "$base"
}
