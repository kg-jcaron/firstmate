#!/usr/bin/env bash
# fm-tasktmp-lib.sh - the per-task temp root path.
#
# Every spawned task gets one disposable temp root. bin/fm-spawn.sh creates it
# (with Go's build temp nested at gotmp/), records it as tasktmp= in the task's
# state/<id>.meta, and bin/fm-teardown.sh removes the whole root at cleanup by
# reading that recorded value rather than recomputing the path.
#
# bin/fm-brief.sh needs the same path a step EARLIER than spawn: the generated
# brief tells the crewmate to redirect verbose command output there instead of
# printing whole build, test, lint, and CI logs into its context. The brief is
# scaffolded before spawn runs, so it cannot read tasktmp= from meta and would
# otherwise have to restate the path literal. This library exists so the literal
# has exactly one owner and the two scripts cannot drift apart.
#
# Sourced by bin/fm-spawn.sh, bin/fm-brief.sh, and the tests. No side effects on
# source. set -u / set -e safe.

# fm_task_tmp_dir <task-id>: print the task's temp root. The path is
# deterministic from the task id alone, which is what lets the brief name it
# before spawn has created it.
fm_task_tmp_dir() {  # <task-id>
  printf '/tmp/fm-%s\n' "$1"
}
