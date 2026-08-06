#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# Literal tab and carriage return, so heading fixtures and their assertions can
# name whitespace no editor renders visibly.
TAB=$'\t'
CR=$'\r'

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "Never add a co-author trailer naming an AI model or assistant" "$brief" \
      "$id: brief missing the AI co-author trailer ban"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  # The apostrophe in "firstmate's authority check" is now structurally safe
  # (no `$(...)` wrapper around the heredoc), so it renders verbatim instead of
  # being reworded or escaped away. test_no_heredoc_in_command_substitution
  # guards the structure that makes it safe.
  assert_grep "firstmate's authority check" "$brief" \
    "no-mistakes DOD lost the apostrophe prose that the structural fix makes parse-safe"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe"
}

# Print the numbered Rules block of a generated brief: everything between the
# `# Rules` heading and the next `# ` heading. The Setup block is numbered too, so
# a rule cross-reference must resolve inside this range and nowhere else.
rules_block() {
  awk '/^# Rules$/{inside=1; next} inside && /^# /{exit} inside' "$1"
}

# Every `(rule N)` cross-reference in a generated brief must resolve to a real
# numbered rule, and the one pointing at needs-decision escalation must land on the
# decision-belongs-to-a-human rule specifically. The Rules blocks are hand-numbered
# and duplicated across the scout and ship heredocs, so inserting a rule silently
# misdirects crewmates unless the correspondence is pinned.
assert_rule_cross_references_resolve() {
  local brief=$1 label=$2 block refs n
  block=$(rules_block "$brief")
  [ -n "$block" ] || fail "$label: brief has no numbered Rules block"
  refs=$(grep -oE '\(rule [0-9]+\)' "$brief" | grep -oE '[0-9]+' | sort -u)
  [ -n "$refs" ] || return 0
  for n in $refs; do
    printf '%s\n' "$block" | grep -qE "^$n\. " \
      || fail "$label: brief cites (rule $n) but its Rules block has no rule $n"$'\n'"--- rules ---"$'\n'"$block"
  done
  n=$(grep -oE 'escalate to firstmate \(rule [0-9]+\)' "$brief" | grep -oE '[0-9]+' | head -1)
  if [ -n "$n" ]; then
    # The ship and scout blocks word this rule's owner differently ("belongs to a
    # human" vs "belongs above the implementation worker"), so match the rule by
    # what it does - open a needs-decision - rather than by either phrasing.
    printf '%s\n' "$block" | grep -qE "^$n\. If a decision belongs" \
      || fail "$label: 'escalate to firstmate (rule $n)' does not point at the needs-decision rule"$'\n'"--- rules ---"$'\n'"$block"
  fi
}

test_rule_cross_references_stay_pinned_to_their_rule() {
  local home id
  home="$TMP_ROOT/rule-xref-home"
  mkdir -p "$home/data"

  id="brief-xref-nomistakes-r1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1 \
    || fail "no-mistakes ship brief scaffold exited non-zero"
  assert_grep "escalate to firstmate (rule" "$home/data/$id/brief.md" \
    "no-mistakes ship brief lost its needs-decision cross-reference"
  assert_rule_cross_references_resolve "$home/data/$id/brief.md" "no-mistakes ship"

  id="brief-xref-scout-r2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1 \
    || fail "scout brief scaffold exited non-zero"
  assert_rule_cross_references_resolve "$home/data/$id/brief.md" "scout"

  id="brief-xref-promote-r3"
  mkdir -p "$home/data/$id"
  printf 'original scout brief\n' > "$home/data/$id/brief.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --promote >/dev/null 2>&1 \
    || fail "--promote scaffold exited non-zero"
  assert_grep "escalate to firstmate (rule" "$home/data/$id/promote.md" \
    "--promote brief lost its needs-decision cross-reference"
  assert_rule_cross_references_resolve "$home/data/$id/promote.md" "promote"

  pass "fm-brief.sh: every (rule N) cross-reference resolves to its intended rule"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

# A ship brief for a project WITH a fleet-private custom-flow note must carry the
# note's full contract as the brief's own Definition of done, and must NOT depend
# on data/learnings.md having been loaded. The note body is captain free text, so
# it also exercises the verbatim-injection safety: backticks, "$" and a literal
# EOF line in the note must survive into the brief unexecuted.
test_custom_flow_note_injected_into_ship_brief() {
  local home id brief note
  home="$TMP_ROOT/custom-flow-home"
  mkdir -p "$home/data/project-flows"
  note="$home/data/project-flows/flowproj.md"
  cat > "$note" <<'EOF'
Custom stage flow for flowproj:
1. Gate green, then start the dev server (`cd web && pnpm dev`) for the local visual preview owed to the captain.
2. Push the branch and open a DRAFT PR first, before the local review.
3. On approval, merge to `stage_builds` and watch the $DEPLOY run.
EOF
  id="brief-custom-flow-e1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "custom-flow ship brief was not scaffolded"
  assert_grep "# Definition of done - MANDATORY custom delivery workflow" "$brief" \
    "custom-flow brief missing the mandatory-flow Definition of done heading"
  assert_grep "only definition of done" "$brief" \
    "custom-flow brief did not claim the flow as the task's one definition of done"
  assert_grep "local visual preview owed to the captain" "$brief" \
    "custom-flow brief lost the dev-server preview step from the note"
  assert_grep "open a DRAFT PR first" "$brief" \
    "custom-flow brief lost the draft-PR-first step from the note"
  assert_grep "merge to \`stage_builds\`" "$brief" \
    "custom-flow brief lost the stage-merge step from the note"
  # Verbatim safety: the note's own backticks / "$" survive unexecuted.
  # shellcheck disable=SC2016 # Literal "$DEPLOY" must stay unexpanded - that is the assertion.
  assert_grep 'watch the $DEPLOY run' "$brief" \
    "custom-flow brief re-evaluated a \"\$\" in the note body instead of writing it verbatim"
  # The flow's own contract is the brief's ONE definition of done, and the
  # generic delivery-mode gate that used to follow it is gone.
  assert_no_grep "complete only when committed on your branch" "$brief" \
    "custom-flow brief still carries the generic stop-after-committing gate"
  assert_grep "## Reporting completion" "$brief" \
    "custom-flow brief lost the status-protocol bridge to the flow's own endpoint"
  pass "fm-brief.sh: custom-flow note is injected verbatim as the one definition of done"
}

# The observed 2026-08-04 failure: a custom-flow brief that also carried the
# generic delivery-mode Definition of done ended with a concrete "complete once
# committed" instruction, so workers committed and stopped short of the flow's
# own draft-PR step. Every delivery mode, for both a fresh ship brief and a
# --promote brief, must now emit exactly one definition of done.
# assert_one_dod <file> <label>: the file must carry exactly one
# "# Definition of done" heading, so no two completion contracts can compete.
assert_one_dod() {
  local count
  count=$(grep -c '^# Definition of done' "$1") || count=0
  [ "$count" = 1 ] || fail "$2 must carry exactly one Definition of done heading (found $count)"
}

# rule1_marker <mode> <id>: the rule 1 fragment unique to that delivery mode.
# Rule 1 stays mode-derived even under a custom flow, so asserting it per
# iteration is what stops a loop over modes from silently collapsing onto the
# no-mistakes fallback (an unparsable registry line) while still passing.
# shellcheck disable=SC2016 # The backticks are literal brief markdown being matched, not a command substitution.
rule1_marker() {
  case "$1" in
    direct-PR)  printf 'push only your `fm/%s` branch' "$2" ;;
    local-only) printf 'Never push to any remote and never open a PR' ;;
    *)          printf 'Never push to the default branch. Never merge a PR.' ;;
  esac
}

# generic_dod_marker <mode>: a line unique to that mode's generic Definition of
# done, so a no-flow brief proves which mode's contract it actually carries.
generic_dod_marker() {
  case "$1" in
    direct-PR)  printf 'This project ships **direct-PR**' ;;
    local-only) printf 'This project ships **local-only**' ;;
    *)          printf 'Firstmate will then instruct you to run /no-mistakes' ;;
  esac
}

test_custom_flow_replaces_generic_definition_of_done() {
  local home id brief mode n
  n=0
  for mode in no-mistakes direct-PR local-only; do
    n=$((n + 1))
    home="$TMP_ROOT/flow-one-dod-home-$n"
    mkdir -p "$home/data/project-flows"
    printf -- '- flowproj [%s] - flow project (added 2026-08-04)\n' "$mode" > "$home/data/projects.md"
    printf 'Custom flow: open the draft PR, then present the preview.\n' \
      > "$home/data/project-flows/flowproj.md"

    id="brief-one-dod-$n"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$mode custom-flow ship brief was not scaffolded"
    assert_grep "$(rule1_marker "$mode" "$id")" "$brief" \
      "$mode custom-flow ship brief did not resolve to the $mode delivery mode"
    assert_grep "Custom flow: open the draft PR" "$brief" \
      "$mode custom-flow ship brief lost the flow contract"
    assert_no_grep "complete only when committed on your branch" "$brief" \
      "$mode custom-flow ship brief kept the generic stop-after-committing gate"
    assert_no_grep "$(generic_dod_marker "$mode")" "$brief" \
      "$mode custom-flow ship brief kept the generic delivery-mode Definition of done"
    assert_one_dod "$brief" "$mode custom-flow ship brief"

    id="promote-one-dod-$n"
    mkdir -p "$home/data/$id"
    printf 'original scout brief\n' > "$home/data/$id/brief.md"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj --promote >/dev/null 2>&1
    brief="$home/data/$id/promote.md"
    assert_present "$brief" "$mode custom-flow promote brief was not scaffolded"
    assert_grep "$(rule1_marker "$mode" "$id")" "$brief" \
      "$mode custom-flow promote brief did not resolve to the $mode delivery mode"
    assert_no_grep "complete only when committed on your branch" "$brief" \
      "$mode custom-flow promote brief kept the generic stop-after-committing gate"
    assert_no_grep "$(generic_dod_marker "$mode")" "$brief" \
      "$mode custom-flow promote brief kept the generic delivery-mode Definition of done"
    assert_one_dod "$brief" "$mode custom-flow promote brief"
  done

  # The same three modes with no note keep their own generic contract intact,
  # named line by line so a collapsed loop or a silently reworded generic
  # Definition of done cannot pass.
  n=0
  for mode in no-mistakes direct-PR local-only; do
    n=$((n + 1))
    home="$TMP_ROOT/plain-one-dod-home-$n"
    mkdir -p "$home/data"
    printf -- '- plainproj [%s] - plain project (added 2026-08-04)\n' "$mode" > "$home/data/projects.md"
    id="brief-plain-dod-$n"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" plainproj >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_grep "$(rule1_marker "$mode" "$id")" "$brief" \
      "$mode brief with no custom flow did not resolve to the $mode delivery mode"
    assert_grep "$(generic_dod_marker "$mode")" "$brief" \
      "$mode brief with no custom flow lost its own generic Definition of done"
    assert_grep "complete only when committed on your branch" "$brief" \
      "$mode brief with no custom flow lost its generic Definition of done gate"
    assert_no_grep "MANDATORY custom delivery workflow" "$brief" \
      "$mode brief with no custom flow leaked a custom-flow Definition of done"
    assert_no_grep "## Reporting completion" "$brief" \
      "$mode brief with no custom flow leaked the custom-flow completion bridge"
  done
  pass "fm-brief.sh: a custom flow replaces the generic Definition of done, one per brief"
}

# The precedence sentence is the only thing that resolves a conflict between the
# flow and the still-mode-derived rule 1: a local-only project carrying a
# PR-opening custom flow reads "never push and never open a PR" alongside a flow
# that pushes and opens a draft PR. The brief must say which one wins, and must
# never claim the generic delivery-mode instructions are absent, because rule 1
# is one of them and is still emitted.
test_custom_flow_states_precedence_over_mode_rules() {
  local home id brief
  home="$TMP_ROOT/flow-precedence-home"
  mkdir -p "$home/data/project-flows"
  printf -- '- flowproj [local-only] - flow project (added 2026-08-04)\n' > "$home/data/projects.md"
  printf 'Push the branch and open a DRAFT PR, then merge to the stage branch.\n' \
    > "$home/data/project-flows/flowproj.md"
  id="brief-flow-precedence"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "local-only custom-flow brief was not scaffolded"
  assert_grep "Never push to any remote and never open a PR" "$brief" \
    "local-only custom-flow brief lost its mode-derived rule 1 safety boundary"
  assert_grep "This section WINS over every other instruction in this brief" "$brief" \
    "custom-flow brief has no precedence rule to resolve a conflicting mode-derived rule"
  assert_grep "completion instruction elsewhere here disagrees with this contract" "$brief" \
    "custom-flow brief precedence rule does not cover conflicting delivery-mode instructions"
  assert_no_grep "deliberately absent from this brief" "$brief" \
    "custom-flow brief still claims the generic delivery-mode instructions are absent"
  pass "fm-brief.sh: a custom flow declares precedence over the mode-derived rules"
}

# dod_section <file>: the brief's Definition of done section. It is always the
# last section, so everything from its heading to end of file, under either the
# generic heading or the custom-flow rename.
dod_section() {
  awk '/^# Definition of done/ { inside = 1 } inside' "$1"
}

# The affirmative pipeline trigger removed in d5aa5bc must not return in ANY
# spelling. A fixed-string guard on the sentence that happened to be removed is
# not that invariant: a reworded, unbackticked reinstatement such as "run
# /no-mistakes at the workflow validation step" sails straight past it, and the
# unbackticked form is already the house style elsewhere in the same scaffold.
# So instead of pinning one wording, this partitions every line of the injected
# section that mentions the pipeline at all against the declared set of sentences
# that only CONSTRAIN a run; any other line, however worded, is reported.
# The captain's note body is deliberately out of scope, because a flow is free to
# name its own pipeline step - assert_no_pipeline_trigger therefore requires the
# fixture note to mention neither the pipeline nor no-mistakes, so scaffold text
# is the only thing this partition can see.
declared_pipeline_lines() {
  cat <<'EOF'
Follow it exactly, and do not fall back to the default no-mistakes-to-PR pipeline.
## Validation pipeline rules
These rules bind you only where a step of the workflow above has you run the no-mistakes pipeline; where it does not, this task has no pipeline run and you do not start one.
You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
Do not hand-edit, commit, abort, or restart while a run is active, and do not fix findings yourself - the pipeline applies every fix.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
EOF
}

# undeclared_pipeline_lines <brief>: print every line of the injected Definition
# of done that references the pipeline and is not one of the declared constraining
# sentences. Empty output means the brief starts no pipeline run of its own.
undeclared_pipeline_lines() {
  local brief=$1 declared line
  declared=$(declared_pipeline_lines)
  while IFS= read -r line; do
    case "$line" in
      *no-mistakes*|*pipeline*|*Pipeline*) ;;
      *) continue ;;
    esac
    printf '%s\n' "$declared" | grep -Fxq -- "$line" && continue
    printf '%s\n' "$line"
  done < <(dod_section "$brief")
}

assert_no_pipeline_trigger() {
  local brief=$1 note=$2 label=$3 undeclared
  if grep -qE 'no-mistakes|pipeline|Pipeline' "$note"; then
    fail "$label: the fixture note mentions the pipeline, so this guard could not tell scaffold text from captain content"
  fi
  undeclared=$(undeclared_pipeline_lines "$brief")
  [ -z "$undeclared" ] \
    || fail "$label instructs a pipeline run its workflow never asked for:"$'\n'"$undeclared"
}

# Control for assert_no_pipeline_trigger: the partition must reject the exact
# sentence removed in d5aa5bc AND rewordings of it that no fixed-string guard
# would catch. Without this the assertions in the tests below could be vacuous.
test_pipeline_trigger_guard_rejects_every_reinstated_trigger() {
  local home id brief mutated reinstated
  home="$TMP_ROOT/flow-trigger-guard-home"
  mkdir -p "$home/data/project-flows"
  printf -- '- flowproj [no-mistakes] - flow project (added 2026-08-06)\n' > "$home/data/projects.md"
  printf 'Open the draft PR, then present the preview.\n' > "$home/data/project-flows/flowproj.md"
  id="brief-flow-trigger-guard"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "custom-flow brief was not scaffolded"
  assert_no_pipeline_trigger "$brief" "$home/data/project-flows/flowproj.md" \
    "the no-mistakes custom-flow brief"
  mutated="$TMP_ROOT/flow-trigger-guard-mutated.md"
  # shellcheck disable=SC2016  # These are literal brief-text reinstatements being rejected, not commands.
  for reinstated in \
    'This project'"'"'s registered delivery mode is **no-mistakes**, so the pipeline is this task'"'"'s default validation: run `/no-mistakes` at the workflow'"'"'s validation step unless the workflow above puts its own validation in that place or tells you not to run the pipeline.' \
    'Run /no-mistakes at the workflow validation step.' \
    'Invoke the pipeline to validate this task before the preview.' \
    'The no-mistakes pipeline is this task'"'"'s validation step.'
  do
    cp "$brief" "$mutated"
    printf '%s\n' "$reinstated" >> "$mutated"
    [ -n "$(undeclared_pipeline_lines "$mutated")" ] \
      || fail "the pipeline-trigger partition accepted a reinstated trigger: $reinstated"
  done
  pass "fm-brief.sh: the pipeline-trigger guard rejects a reinstated trigger in any wording"
}

# The pipeline-ownership and authority rules are not completion gates, so
# replacing the generic Definition of done must not drop them: a custom-flow
# project in no-mistakes mode still runs `no-mistakes doctor` in Setup and may
# run the pipeline. They stay out of the two modes that have no pipeline.
test_custom_flow_keeps_no_mistakes_pipeline_guardrails() {
  local home id brief mode n
  n=0
  for mode in no-mistakes direct-PR local-only; do
    n=$((n + 1))
    home="$TMP_ROOT/flow-guardrail-home-$n"
    mkdir -p "$home/data/project-flows"
    printf -- '- flowproj [%s] - flow project (added 2026-08-04)\n' "$mode" > "$home/data/projects.md"
    printf 'Gate green, then open the draft PR.\n' > "$home/data/project-flows/flowproj.md"
    id="brief-flow-guardrail-$n"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$mode custom-flow brief was not scaffolded"
    assert_grep "$(rule1_marker "$mode" "$id")" "$brief" \
      "$mode custom-flow brief did not resolve to the $mode delivery mode"
    if [ "$mode" = no-mistakes ]; then
      assert_grep "## Validation pipeline rules" "$brief" \
        "custom-flow brief dropped the no-mistakes pipeline rules section"
      assert_grep "Do not hand-edit, commit, abort, or restart while a run is active" "$brief" \
        "custom-flow brief dropped the prohibition on hand-fixing an active run"
      assert_grep "Avoid \`--yes\`" "$brief" \
        "custom-flow brief dropped the --yes prohibition that protects captain authority"
      # The workflow alone decides whether a run happens. An affirmative
      # "run it at the validation step" sentence emitted after the flow is the
      # instruction-ordering shape this whole change removes, so the rules must
      # bind conditionally and start nothing.
      assert_grep "bind you only where a step of the workflow above has you run the no-mistakes pipeline" "$brief" \
        "the pipeline rules no longer bind conditionally on the workflow's own choice"
      assert_grep "this task has no pipeline run and you do not start one" "$brief" \
        "a custom-flow brief no longer tells the crewmate to start no pipeline of its own"
    else
      assert_no_grep "## Validation pipeline rules" "$brief" \
        "$mode custom-flow brief carries pipeline rules for a mode with no pipeline"
      assert_no_grep "Avoid \`--yes\`" "$brief" \
        "$mode custom-flow brief carries the --yes rule for a mode with no pipeline"
    fi
    # Spelling-independent for every mode: no affirmative instruction to START a
    # run may survive, whichever words a future edit reaches for.
    assert_no_pipeline_trigger "$brief" "$home/data/project-flows/flowproj.md" \
      "$mode custom-flow brief"
  done
  pass "fm-brief.sh: no-mistakes pipeline rules survive a custom Definition of done"
}

# Which briefs carry the pipeline-ownership and --yes rules must depend on the
# resolved delivery mode, never on the Setup section's `no-mistakes doctor` line.
# That line's job is placing a Setup list item, so using it as a stand-in for "the
# mode is no-mistakes" means moving, dropping, or unconditioning a Setup item
# silently changes which crewmates receive the authority guardrails - the same
# silent-vanishing shape the mechanical/completion split exists to prevent, one
# condition further down.
# setup_doctor_line_misuses <script>: print every reference to that variable that
# is not its own assignment or a Setup list item. Empty output means the two
# concerns are independent.
# shellcheck disable=SC2016  # single quotes are deliberate: these are grep patterns matching the script's own literal "$NM_INIT_LINE" text, not expansions.
setup_doctor_line_misuses() {
  grep -n 'NM_INIT_LINE' "$1" \
    | grep -v ':[[:space:]]*#' \
    | grep -vE ':[[:space:]]*NM_INIT_LINE=' \
    | grep -vE ':[[:space:]]*(SETUP2|SETUP2_PROMOTE)=' \
    | grep -vE ':[[:space:]]*\[ -n "\$NM_INIT_LINE" \] && SETUP2_PROMOTE=' \
    | grep -vE ':[0-9]+\. \$NM_INIT_LINE"?$' \
    || true
}

test_pipeline_rules_do_not_hang_on_the_setup_doctor_line() {
  local coupled
  [ -z "$(setup_doctor_line_misuses "$ROOT/bin/fm-brief.sh")" ] || fail \
    "the Setup doctor line decides something beyond its Setup list item:"$'\n'"$(setup_doctor_line_misuses "$ROOT/bin/fm-brief.sh")"
  # Control: the coupling this guard exists to reject must actually be reported,
  # reproduced from the real script rather than a hand-written fixture.
  coupled="$TMP_ROOT/fm-brief-coupled.sh"
  # shellcheck disable=SC2016  # single quotes are deliberate: the replacement text is the script's own literal condition, not an expansion.
  sed 's/if \[ "\$NM_MODE" -eq 1 \]; then/if [ -n "$NM_INIT_LINE" ]; then/' \
    "$ROOT/bin/fm-brief.sh" > "$coupled"
  ! cmp -s "$ROOT/bin/fm-brief.sh" "$coupled" \
    || fail "the coupling control did not change the script, so it proves nothing"
  [ -n "$(setup_doctor_line_misuses "$coupled")" ] \
    || fail "the guard accepted a script that gates the pipeline rules on the Setup doctor line"
  pass "fm-brief.sh: the pipeline rules are gated on the delivery mode, not a Setup list item"
}

# A custom flow replaces the delivery mode's COMPLETION gate and nothing else.
# Three rounds of review each lost a different mode-derived rule to that
# replacement - first the precedence clause, then the pipeline-ownership rules,
# then local-only's clean-fast-forward rule, whose absence produces exactly the
# diverged branch bin/fm-merge-local.sh refuses - so the guard below is a
# partition rather than a check on any one sentence.
# completion_gate_lines <mode> <id>: the exact generic Definition-of-done lines a
# custom flow is ALLOWED to drop, because each one tells the crewmate when the
# task is complete. Declaring the replaceable lines instead of the surviving ones
# is what makes this structural: a mechanical rule added to a mode later fails
# here until it is either carried into the custom-flow brief or deliberately
# declared a completion gate.
# One entry is droppable for a different, recorded reason: direct-PR's "Do NOT run
# /no-mistakes." is a tooling prohibition, the same mechanical category as the
# fast-forward rule, and it is listed here only because the injected lead already
# carries its substance ("do not fall back to the default no-mistakes-to-PR
# pipeline"). Recording that keeps the partition honest - the next reader can tell
# a covered-elsewhere line from the silent drift this guard exists to catch.
# This case list doubles as the declaration of how a brief for a project with NO
# note reads, because every non-blank line of a generic Definition of done must be
# either declared here or carried into the custom-flow one. Three deliberate
# differences from the pre-change output live in it, and nothing else may:
#  - no-mistakes: the pipeline-ownership and --yes sentences were strengthened.
#  - no-mistakes: the CI-green return point moved out of the completion line into
#    the pipeline rules, because it says how far a run is driven, not when the task
#    is done; the `checks green` ready token stayed behind on the completion line.
#  - direct-PR: the tooling prohibition and the merge-authority handover, once one
#    line, are now two, which is also the repo's one-sentence-per-line rule.
completion_gate_lines() {
  case "$1" in
    direct-PR)
      cat <<EOF
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$2\`. Do NOT push, do NOT open a PR, do NOT merge.
When it is implemented and committed, append \`done: ready in branch fm/$2\` to the status file and stop.
EOF
      ;;
    *)
      cat <<EOF
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
After /no-mistakes reports CI green, append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      ;;
  esac
}

# unreplaced_mode_lines <plain-brief> <flow-brief> <mode> <id>: print every line
# of the plain brief's Definition of done that the custom-flow brief's Definition
# of done dropped and that is NOT a declared completion-gate line. Empty output
# means the flow replaced exactly the completion gate.
# Survival is looked for inside the custom-flow Definition of done, not anywhere in
# the brief: the property being proved is that the mode's mechanical rules reach
# the crewmate in the section that replaced the gate, so a future mode-derived
# sentence that also happens to appear in Setup, Rules, or project memory must not
# count as carried once the mechanics subsection has dropped it.
unreplaced_mode_lines() {
  local plain=$1 flow=$2 allow flow_dod line
  allow=$(completion_gate_lines "$3" "$4")
  flow_dod=$(dod_section "$flow")
  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || continue
    printf '%s\n' "$flow_dod" | grep -Fxq -- "$line" && continue
    printf '%s\n' "$allow" | grep -Fxq -- "$line" && continue
    printf '%s\n' "$line"
  done < <(dod_section "$plain")
}

# mechanics_section <file>: the body of the injected branch-and-handover
# subsection, or nothing when the mode contributes no mechanics.
mechanics_section() {
  awk '/^## Branch and handover mechanics$/ { inside = 1; next } inside && /^## / { exit } inside' "$1"
}

test_custom_flow_keeps_mode_branch_and_handover_mechanics() {
  local home plain_home id brief plain mode n dropped sect
  local ff_brief="" ff_plain="" ff_id=""
  local nm_brief="" nm_plain="" nm_id=""
  n=0
  for mode in no-mistakes direct-PR local-only; do
    n=$((n + 1))
    home="$TMP_ROOT/flow-mechanics-home-$n"
    plain_home="$TMP_ROOT/flow-mechanics-plain-home-$n"
    mkdir -p "$home/data/project-flows" "$plain_home/data"
    printf -- '- proj [%s] - flow project (added 2026-08-06)\n' "$mode" > "$home/data/projects.md"
    cp "$home/data/projects.md" "$plain_home/data/projects.md"
    printf 'Open the draft PR, then present the preview.\n' > "$home/data/project-flows/proj.md"
    # Same task id in both homes, so `fm/<id>` renders identically and the two
    # Definition-of-done sections are comparable line by line.
    id="brief-mechanics-$n"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" proj >/dev/null 2>&1
    FM_HOME="$plain_home" "$ROOT/bin/fm-brief.sh" "$id" proj >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    plain="$plain_home/data/$id/brief.md"
    assert_present "$brief" "$mode custom-flow brief was not scaffolded"
    assert_present "$plain" "$mode no-flow brief was not scaffolded"
    # Non-vacuous: both briefs really carry this mode's contract, and only the
    # custom-flow one replaced the gate.
    assert_grep "$(rule1_marker "$mode" "$id")" "$brief" \
      "$mode custom-flow brief did not resolve to the $mode delivery mode"
    assert_grep "$(generic_dod_marker "$mode")" "$plain" \
      "$mode no-flow brief lost its own generic Definition of done"
    assert_no_grep "$(generic_dod_marker "$mode")" "$brief" \
      "$mode custom-flow brief kept the generic delivery-mode Definition of done"

    dropped=$(unreplaced_mode_lines "$plain" "$brief" "$mode" "$id")
    [ -z "$dropped" ] || fail \
      "$mode custom-flow brief dropped mode-derived lines that are not completion gates:"$'\n'"$dropped"

    case "$mode" in
      direct-PR)
        assert_grep "## Branch and handover mechanics" "$brief" \
          "direct-PR custom-flow brief has no branch-and-handover subsection"
        assert_line "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
          "direct-PR custom-flow brief lost the merge-authority handover"
        # The one allow-list entry that is a mechanical rule rather than a
        # completion gate is droppable only because the lead carries its
        # substance, so that sentence must actually be there.
        assert_line "Follow it exactly, and do not fall back to the default no-mistakes-to-PR pipeline." "$brief" \
          "direct-PR custom-flow brief dropped the lead sentence that carries the mode's do-not-run-the-pipeline prohibition"
        ;;
      local-only)
        assert_grep "## Branch and handover mechanics" "$brief" \
          "local-only custom-flow brief has no branch-and-handover subsection"
        assert_line "Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward." "$brief" \
          "local-only custom-flow brief lost the clean-fast-forward and rebase rule bin/fm-merge-local.sh requires"
        assert_line "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
          "local-only custom-flow brief lost the guarded-landing handover"
        ff_brief=$brief
        ff_plain=$plain
        ff_id=$id
        ;;
      *)
        assert_no_grep "## Branch and handover mechanics" "$brief" \
          "no-mistakes mode contributes no branch or handover mechanics, so no such subsection may be emitted"
        nm_brief=$brief
        nm_plain=$plain
        nm_id=$id
        ;;
    esac

    # Whatever survives must never read as a second completion contract.
    sect=$(mechanics_section "$brief")
    if [ -n "$sect" ]; then
      printf '%s\n' "$sect" | grep -Fq "none of them decides when the task is done" \
        || fail "$mode branch-and-handover subsection does not disclaim deciding completion"
      if printf '%s\n' "$sect" | grep -qE 'done:|complete only when|task is complete'; then
        fail "$mode branch-and-handover subsection reintroduced a completion gate"
      fi
    fi
    assert_one_dod "$brief" "$mode custom-flow brief with surviving mode mechanics"
  done

  # Controls: the partition above must actually fire, in both directions. A
  # surviving mechanical rule deleted from the custom-flow brief, and a NEW
  # mode-derived rule the injection does not carry, must each be reported -
  # otherwise the next mode rule could vanish exactly as the fast-forward rule did.
  local mutated_flow="$TMP_ROOT/flow-mechanics-mutated-flow.md"
  local mutated_plain="$TMP_ROOT/flow-mechanics-mutated-plain.md"
  grep -Fv "rebase onto it so the eventual merge stays a fast-forward" "$ff_brief" > "$mutated_flow"
  [ -n "$(unreplaced_mode_lines "$ff_plain" "$mutated_flow" local-only "$ff_id")" ] \
    || fail "the mechanics partition accepted a custom-flow brief with the fast-forward rule removed"
  cp "$ff_plain" "$mutated_plain"
  printf 'Sign every commit on your branch with the release key.\n' >> "$mutated_plain"
  [ -n "$(unreplaced_mode_lines "$mutated_plain" "$ff_brief" local-only "$ff_id")" ] \
    || fail "the mechanics partition accepted a new mode-derived rule missing from the custom-flow brief"
  # Scope control: the same rule reinstated ABOVE the Definition of done is still
  # dropped from the section that replaced the gate, so the partition must keep
  # reporting it. Searching the whole brief would call it carried, and a future
  # mode-derived sentence that also appears in Setup, Rules, or project memory
  # would then mask its removal from the mechanics subsection.
  local misplaced_flow="$TMP_ROOT/flow-mechanics-misplaced-flow.md"
  awk -v rule="Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward." '
    /^# Definition of done/ && !inserted { print rule; inserted = 1 }
    { print }
  ' "$mutated_flow" > "$misplaced_flow"
  grep -Fxq -- "Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward." "$misplaced_flow" \
    || fail "the scope control fixture does not carry the reinstated rule at all, so it proves nothing"
  [ -n "$(unreplaced_mode_lines "$ff_plain" "$misplaced_flow" local-only "$ff_id")" ] \
    || fail "the mechanics partition counted a mechanical rule as carried while it sat outside the Definition of done"
  # The same control in no-mistakes mode, where the mechanical rule at issue is the
  # CI-green return point rather than a branch rule. It reached the crewmate inside
  # the completion line until that whole line was declared droppable, so proving the
  # partition reports its removal is what stops it being lost that way a second time.
  local mutated_nm="$TMP_ROOT/flow-mechanics-mutated-nm.md"
  grep -Fv "never sit watching it keep monitoring in the background until merge" "$nm_brief" > "$mutated_nm"
  [ -n "$(unreplaced_mode_lines "$nm_plain" "$mutated_nm" no-mistakes "$nm_id")" ] \
    || fail "the mechanics partition accepted a custom-flow brief with the CI-green return point removed"
  pass "fm-brief.sh: a custom flow replaces the mode's completion gate and keeps its mechanics"
}

# The generic no-mistakes completion line used to carry a mechanical rule inside
# itself - return when the run reports CI green, do not watch it until merge - and
# declaring that whole line droppable dropped the mechanical half with the gate.
# The two halves now live apart, and the split only holds if both directions do:
# the return point is a pipeline rule and must survive into a custom-flow brief
# (proved by the mechanics partition and its control above), while the `checks
# green` ready token must NOT, because a custom flow may run no pipeline at all and
# a brief that asks for a token the task can never emit leaves firstmate matching a
# status line that never arrives.
# pipeline_ready_token: the free-text token other components key on to recognize a
# no-mistakes run that reached CI green.
pipeline_ready_token() { printf 'checks green'; }

# ready_token_lines <file>: every line of a brief that asks for that token. Empty
# output means the brief promises firstmate no pipeline-only ready signal.
ready_token_lines() {
  grep -F -- "$(pipeline_ready_token)" "$1" || true
}

test_ci_ready_token_stays_on_the_pipeline_path() {
  local home plain_home id brief plain note token mode n mutated
  token=$(pipeline_ready_token)
  # Non-vacuity: this is the live cross-component token, not a string only this
  # test believes in. Its consumers are the crew-state reconciler and the
  # captain-relevant classifier.
  grep -Fq "$token" "$ROOT/bin/fm-crew-state.sh" \
    || fail "bin/fm-crew-state.sh no longer keys on '$token', so this guard protects a dead token"
  grep -Fq "$token" "$ROOT/bin/fm-classify-lib.sh" \
    || fail "bin/fm-classify-lib.sh no longer keys on '$token', so this guard protects a dead token"

  n=0
  for mode in no-mistakes direct-PR local-only; do
    n=$((n + 1))
    home="$TMP_ROOT/flow-ready-token-home-$n"
    mkdir -p "$home/data/project-flows"
    printf -- '- flowproj [%s] - flow project (added 2026-08-06)\n' "$mode" > "$home/data/projects.md"
    note="$home/data/project-flows/flowproj.md"
    # A flow that declines the pipeline: it names no validation run of its own, so
    # its crewmate has no run to report CI green for.
    printf 'Open the DRAFT PR, then present the local preview and wait for the captain.\n' > "$note"
    if grep -qE 'no-mistakes|pipeline|CI|checks' "$note"; then
      fail "the fixture note names a pipeline run, so this guard could not tell scaffold text from captain content"
    fi
    id="brief-ready-token-$n"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$mode custom-flow brief was not scaffolded"
    [ -z "$(ready_token_lines "$brief")" ] || fail \
      "$mode custom-flow brief asks for the no-mistakes ready token its workflow can never emit:"$'\n'"$(ready_token_lines "$brief")"
    if [ "$mode" = no-mistakes ]; then
      # The other half of the split: the mechanical rule is present, in the section
      # that only binds where the workflow itself runs the pipeline.
      printf '%s\n' "$(dod_section "$brief")" | grep -Fq "CI green is a run's return point" \
        || fail "the no-mistakes custom-flow brief lost the CI-green return point that keeps a crewmate off a run it should have handed back"
    fi
  done

  # And the pipeline path still carries it: a plain no-mistakes brief keeps the
  # token on its completion line, so the split moved the mechanical rule without
  # breaking the signal firstmate reconciles against.
  plain_home="$TMP_ROOT/flow-ready-token-plain-home"
  mkdir -p "$plain_home/data"
  printf -- '- plainproj [no-mistakes] - plain project (added 2026-08-06)\n' > "$plain_home/data/projects.md"
  id="brief-ready-token-plain"
  FM_HOME="$plain_home" "$ROOT/bin/fm-brief.sh" "$id" plainproj >/dev/null 2>&1
  plain="$plain_home/data/$id/brief.md"
  assert_present "$plain" "plain no-mistakes brief was not scaffolded"
  assert_grep "done: PR {url} $token" "$plain" \
    "the plain no-mistakes brief lost the ready token bin/fm-crew-state.sh reconciles against"
  printf '%s\n' "$(dod_section "$plain")" | grep -Fq "CI green is a run's return point" \
    || fail "the plain no-mistakes brief lost the CI-green return point when it moved out of the completion line"

  # Control: the guard must report a token reinstated into a custom-flow brief,
  # rather than passing because it looks at the wrong file or the wrong string.
  mutated="$TMP_ROOT/flow-ready-token-mutated.md"
  cp "$TMP_ROOT/flow-ready-token-home-1/data/brief-ready-token-1/brief.md" "$mutated"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks are literal brief-text markdown being reinstated, not a command.
  printf 'Append `done: PR {url} %s` and stop.\n' "$token" >> "$mutated"
  [ -n "$(ready_token_lines "$mutated")" ] \
    || fail "the ready-token guard accepted a custom-flow brief that asks for the pipeline ready token"
  pass "fm-brief.sh: the CI-ready return point survives while its pipeline-only token does not"
}

# Rule 5 sends the crewmate to the section that holds this brief's `done:` gate.
# The custom-flow injection renames that heading, so the pointer must follow the
# rename and the gate must live under it - the original defect was exactly a
# crewmate resolving a completion pointer to the wrong section.
# assert_gate_under_anchor <file> <anchor-heading-text> <label>: the completion
# bridge must be reached while still inside the named section. Any top-level
# heading in between closes that section, and reaching end of file without ever
# seeing the bridge fails too - an ordering guard that can only fail on the
# heading it happens to look for would report coverage it does not have.
# Fenced blocks are skipped for the same reason bin/fm-brief.sh skips them: a
# shell comment inside a fence is not a markdown heading and closes nothing.
# An `===` underline over a text line is a top-level heading too, so the guard
# tracks the previous line and fails on that shape as well - checking only `^# `
# would pass on a brief an underline-style note had already broken.
# A tab after the hashes opens a heading just as a space does, and a trailing
# carriage return would push the underline past this guard's end anchor, so the
# heading match allows either whitespace and every line is read `\r`-stripped -
# otherwise a note in either of those shapes could break the anchor unreported.
# A bare `#` is an empty top-level heading and closes the section as surely as a
# titled one, so the match ends at whitespace OR end of line; requiring text after
# the hashes is the blind spot that let that shape through unreported.
assert_gate_under_anchor() {
  awk -v anchor="# $2" '
    { sub(/\r$/, "", $0) }
    /^[ \t]*(```|~~~)/ { fence = !fence; prev = ""; next }
    fence { next }
    $0 == anchor { seen = 1; prev = ""; next }
    seen && /^#([ \t]|$)/ { exit 1 }
    seen && prev != "" && /^[ \t]*=+[ \t]*$/ { exit 1 }
    seen && $0 == "## Reporting completion" { found = 1; exit 0 }
    { prev = ($0 ~ /^[ \t]*$/) ? "" : $0 }
    END { if (!seen || !found) exit 1 }
  ' "$1" || fail "$3"
}

test_rule5_points_at_the_heading_holding_the_done_gate() {
  local home id brief anchor
  home="$TMP_ROOT/flow-anchor-home"
  mkdir -p "$home/data/project-flows"
  printf -- '- flowproj [no-mistakes] - flow project (added 2026-08-04)\n' > "$home/data/projects.md"
  printf 'Open the draft PR, then present the preview.\n' > "$home/data/project-flows/flowproj.md"
  id="brief-flow-anchor"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "custom-flow brief was not scaffolded"
  anchor="Definition of done - MANDATORY custom delivery workflow"
  assert_grep "gate under $anchor." "$brief" \
    "rule 5 still points at the generic heading a custom-flow brief no longer has"
  # The bridge that defines the gate is a subsection of that heading, so nothing
  # sits between rule 5's pointer and the gate it promises.
  assert_grep "## Reporting completion" "$brief" \
    "the completion bridge is not a subsection of the renamed Definition of done"
  assert_gate_under_anchor "$brief" "$anchor" \
    "the \`done:\` gate does not live under the heading rule 5 names"

  id="brief-plain-anchor"
  mkdir -p "$home/data"
  printf -- '- plainproj [no-mistakes] - plain project (added 2026-08-04)\n' >> "$home/data/projects.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" plainproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "gate under Definition of done." "$brief" \
    "a no-flow brief lost rule 5's pointer at its generic Definition of done"
  pass "fm-brief.sh: rule 5 names the heading that holds this brief's done gate"
}

# Every real flow note on disk opens with its own `# <project> custom delivery
# workflow` heading, which is the ordinary shape for a captain-authored markdown
# note. Injected verbatim, that heading CLOSES the Definition of done section and
# strands the completion gate under the note's heading instead - the same
# wrong-section resolution this whole change exists to stop. The scaffold demotes
# the note's headings on the way in, and this fixture mirrors a real note's shape
# (an H1 opener, H2 sections, and a fenced block whose shell comment must not be
# mistaken for a heading) so that demotion is exercised.
# assert_line / assert_no_line <exact-line> <file> <msg>: whole-line matching,
# because assert_grep is a substring match and "## x" is a substring of "### x" -
# a heading-depth assertion written with it would pass at the wrong depth.
assert_line() {
  grep -Fxq -- "$1" "$2" || fail "$3"
}

assert_no_line() {
  ! grep -Fxq -- "$1" "$2" || fail "$3"
}

test_custom_flow_note_with_its_own_headings_keeps_the_gate_under_the_anchor() {
  local home id brief anchor
  home="$TMP_ROOT/flow-note-headings-home"
  mkdir -p "$home/data/project-flows"
  printf -- '- flowproj [no-mistakes] - flow project (added 2026-08-04)\n' > "$home/data/projects.md"
  cat > "$home/data/project-flows/flowproj.md" <<'EOF'
# flowproj custom delivery workflow

flowproj does NOT use the default pipeline. Follow this flow.

## Flow

1. Open the DRAFT PR, then present the local preview.
2. Merge to `stage_builds` and watch the deploy:

```sh
# not a heading: a shell comment inside a fence
git push
```

## Tickets

Linear team flowproj, keys FLW-*.
EOF
  id="brief-flow-note-headings"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "custom-flow brief with a headed note was not scaffolded"
  anchor="Definition of done - MANDATORY custom delivery workflow"
  assert_gate_under_anchor "$brief" "$anchor" \
    "a note carrying its own heading stranded the \`done:\` gate outside the section rule 5 names"
  assert_one_dod "$brief" "custom-flow brief with a headed note"
  # The note's content survives; only its heading depth changes, so it nests
  # under the scaffold's Definition of done instead of closing it.
  assert_line "## flowproj custom delivery workflow" "$brief" \
    "the note's own top-level heading was not demoted under the Definition of done"
  assert_line "### Flow" "$brief" \
    "the note's section headings were not demoted with its top-level heading"
  assert_line "### Tickets" "$brief" \
    "the note's later section headings were not demoted"
  assert_line "# not a heading: a shell comment inside a fence" "$brief" \
    "a shell comment inside a fenced block was rewritten as if it were a heading"
  assert_grep "Open the DRAFT PR, then present the local preview." "$brief" \
    "the headed note lost its flow steps"
  assert_no_line "# flowproj custom delivery workflow" "$brief" \
    "the note's top-level heading still closes the Definition of done section"
  pass "fm-brief.sh: a note carrying its own headings still nests under the anchor"
}

# Nothing constrains a captain-authored note to `#` headings, and an underline
# (setext) heading closes the anchor section exactly as an unprefixed `#` line
# does, so demoting only ATX headings would re-open this defect for the next note
# written in that style. The note body must otherwise survive untouched, so this
# fixture also carries a list, an indented continuation, a fenced shell comment,
# and a trailing horizontal rule that must NOT be read as a heading underline.
test_custom_flow_note_with_underline_headings_keeps_the_gate_under_the_anchor() {
  local home id brief anchor
  home="$TMP_ROOT/flow-note-underline-home"
  mkdir -p "$home/data/project-flows"
  printf -- '- flowproj [no-mistakes] - flow project (added 2026-08-04)\n' > "$home/data/projects.md"
  cat > "$home/data/project-flows/flowproj.md" <<'EOF'
flowproj custom delivery workflow
================================

flowproj ships through this flow, not the default pipeline.

Flow
----

1. Open the DRAFT PR, then present the local preview.
   - keep the PR in draft until stage-verified
2. Merge to `stage_builds` and watch the deploy:

```sh
# not a heading: a shell comment inside a fence
git push
```

Say "on stage" only once the deploy is green.

---
EOF
  id="brief-flow-note-underline"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "custom-flow brief with an underline-headed note was not scaffolded"
  anchor="Definition of done - MANDATORY custom delivery workflow"
  assert_gate_under_anchor "$brief" "$anchor" \
    "an underline-style note heading stranded the \`done:\` gate outside the section rule 5 names"
  assert_one_dod "$brief" "custom-flow brief with an underline-headed note"
  # The underline headings are rewritten in `#` form at the demoted depth, so no
  # bare underline survives to close the section.
  assert_line "## flowproj custom delivery workflow" "$brief" \
    "the note's underline-style top-level heading was not demoted under the Definition of done"
  assert_line "### Flow" "$brief" \
    "the note's underline-style section heading was not demoted"
  assert_no_line "================================" "$brief" \
    "the note's top-level heading underline survived and still closes the Definition of done section"
  assert_no_line "flowproj custom delivery workflow" "$brief" \
    "the note's heading text was left as bare prose above its underline"
  # Everything that is not a heading is untouched, including the list, the
  # indented continuation, the fenced shell comment, and the trailing rule.
  assert_line "1. Open the DRAFT PR, then present the local preview." "$brief" \
    "the underline-headed note lost its flow steps"
  assert_line "   - keep the PR in draft until stage-verified" "$brief" \
    "an indented list continuation was rewritten while demoting headings"
  assert_line "# not a heading: a shell comment inside a fence" "$brief" \
    "a shell comment inside a fenced block was rewritten as if it were a heading"
  assert_line "---" "$brief" \
    "a trailing horizontal rule was consumed as a heading underline"
  pass "fm-brief.sh: an underline-style note heading is demoted and never closes the anchor"
}

# A leading `---` is only YAML front matter when the whole shape is there AND the
# region is bounded the way real front matter is. Reading any leading `---` as an
# opener disabled demotion for the ENTIRE note, and letting the terminator search
# run to end of file did the same to a whole prefix whenever an unterminated block
# sat above a later horizontal rule, and an undemoted top-level heading closes the
# anchor section again - the exact wrong-section resolution this change exists to
# stop. Each fixture below is a note shape a captain could plausibly write. The
# three `*-then-rule` shapes are the combination a terminator search bounded only by
# end of file swallows whole, and the two compact ones isolate one bound each - the
# ATX heading in `heading-then-rule`, the heading underline in
# `underline-then-rule` - so neither bound can be dropped without a named failure.
test_custom_flow_note_leading_dashes_still_demote_headings() {
  local home id brief anchor n shape
  home="$TMP_ROOT/flow-note-frontmatter-home"
  mkdir -p "$home/data/project-flows"
  printf -- '- flowproj [no-mistakes] - flow project (added 2026-08-06)\n' > "$home/data/projects.md"
  anchor="Definition of done - MANDATORY custom delivery workflow"
  n=0
  for shape in rule unterminated blank-then-rule heading-then-rule underline-then-rule; do
    n=$((n + 1))
    case "$shape" in
      rule)
        # A horizontal rule above the title, closed by a second rule further down.
        cat > "$home/data/project-flows/flowproj.md" <<'EOF'
---
# flowproj custom delivery workflow

## Flow

1. Open the DRAFT PR, then present the local preview.

---
EOF
        ;;
      blank-then-rule)
        # Keys, then a blank line, then the note - and a horizontal rule further
        # down that an unbounded terminator search reads as the block's close.
        cat > "$home/data/project-flows/flowproj.md" <<'EOF'
---
owner: captain
updated: 2026-08-06

# flowproj custom delivery workflow

## Flow

1. Open the DRAFT PR, then present the local preview.

---

Notes at the bottom.
EOF
        ;;
      heading-then-rule)
        # The same unclosed block written compactly, with no blank line anywhere
        # above the later rule, so only the heading itself can bound the region.
        cat > "$home/data/project-flows/flowproj.md" <<'EOF'
---
owner: captain
# flowproj custom delivery workflow
## Flow
1. Open the DRAFT PR, then present the local preview.
---
Notes at the bottom.
EOF
        ;;
      underline-then-rule)
        # The same compact shape written entirely in underline headings, so no ATX
        # heading appears before the later rule and only the underline can bound
        # the region.
        cat > "$home/data/project-flows/flowproj.md" <<'EOF'
---
owner: captain
flowproj custom delivery workflow
================================
Flow
----
1. Open the DRAFT PR, then present the local preview.
---
Notes at the bottom.
EOF
        ;;
      *)
        # A front-matter block the captain never terminated.
        cat > "$home/data/project-flows/flowproj.md" <<'EOF'
---
owner: captain
# flowproj custom delivery workflow

## Flow

1. Open the DRAFT PR, then present the local preview.
EOF
        ;;
    esac
    id="brief-flow-frontmatter-$n"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$shape custom-flow brief was not scaffolded"
    assert_gate_under_anchor "$brief" "$anchor" \
      "a note opening with \`---\` ($shape) stranded the \`done:\` gate outside the section rule 5 names"
    assert_line "## flowproj custom delivery workflow" "$brief" \
      "a note opening with \`---\` ($shape) kept its top-level heading undemoted"
    assert_line "### Flow" "$brief" \
      "a note opening with \`---\` ($shape) kept its section heading undemoted"
    assert_no_line "# flowproj custom delivery workflow" "$brief" \
      "a note opening with \`---\` ($shape) still closes the Definition of done section"
    assert_grep "Open the DRAFT PR, then present the local preview." "$brief" \
      "the note lost its flow steps while its leading \`---\` was classified"
    assert_one_dod "$brief" "$shape custom-flow brief"
  done

  # A real, complete front-matter block is still passed through verbatim - the
  # delimiters must not be rewritten as headings - while the body below it demotes.
  cat > "$home/data/project-flows/flowproj.md" <<'EOF'
---
owner: captain
updated: 2026-08-06
---
# flowproj custom delivery workflow

1. Open the DRAFT PR, then present the local preview.
EOF
  id="brief-flow-frontmatter-real"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "front-matter custom-flow brief was not scaffolded"
  assert_gate_under_anchor "$brief" "$anchor" \
    "a note with real front matter stranded the \`done:\` gate outside the section rule 5 names"
  assert_line "owner: captain" "$brief" \
    "a real front-matter key was not passed through verbatim"
  assert_line "## flowproj custom delivery workflow" "$brief" \
    "the body below real front matter was not demoted"
  pass "fm-brief.sh: a leading \`---\` never disables heading demotion for the note"
}

# An ATX heading indented one to three spaces is a heading in CommonMark, so it
# must be demoted too; four spaces is an indented code block and `#tag` with no
# following space is a hashtag, and both must still pass through untouched.
test_custom_flow_note_indented_headings_are_demoted() {
  local home id brief anchor
  home="$TMP_ROOT/flow-note-indented-home"
  mkdir -p "$home/data/project-flows"
  printf -- '- flowproj [no-mistakes] - flow project (added 2026-08-06)\n' > "$home/data/projects.md"
  cat > "$home/data/project-flows/flowproj.md" <<'EOF'
  # flowproj custom delivery workflow

   ## Flow

1. Open the DRAFT PR, then present the local preview.

    # indented four spaces: a code block, not a heading

 #flowproj is a hashtag, not a heading

 ###### already at the floor
EOF
  id="brief-flow-indented-headings"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "custom-flow brief with indented note headings was not scaffolded"
  anchor="Definition of done - MANDATORY custom delivery workflow"
  assert_gate_under_anchor "$brief" "$anchor" \
    "an indented note heading stranded the \`done:\` gate outside the section rule 5 names"
  assert_one_dod "$brief" "custom-flow brief with indented note headings"
  assert_line "## flowproj custom delivery workflow" "$brief" \
    "a one-to-three-space indented top-level heading escaped demotion"
  assert_line "### Flow" "$brief" \
    "a one-to-three-space indented section heading escaped demotion"
  assert_no_line "  # flowproj custom delivery workflow" "$brief" \
    "the indented top-level heading survived and still closes the Definition of done section"
  assert_line "    # indented four spaces: a code block, not a heading" "$brief" \
    "a four-space indented code block was rewritten as a heading"
  assert_line " #flowproj is a hashtag, not a heading" "$brief" \
    "a hashtag with no space after the hashes was rewritten as a heading"
  assert_line " ###### already at the floor" "$brief" \
    "an H6 heading was pushed past the H6 floor markdown has no level for"
  pass "fm-brief.sh: an indented ATX note heading is demoted, code blocks and hashtags are not"
}

# Two more shapes a captain-authored note can carry, each of which markdown renders
# as a top-level heading and each of which therefore closes the anchor section if it
# escapes demotion: a tab rather than a space after the hashes, and a note written
# with CRLF line endings whose underline heading sits past a carriage return.
test_custom_flow_note_tab_and_crlf_headings_are_demoted() {
  local home id brief anchor
  home="$TMP_ROOT/flow-note-whitespace-home"
  mkdir -p "$home/data/project-flows"
  printf -- '- flowproj [no-mistakes] - flow project (added 2026-08-06)\n' > "$home/data/projects.md"
  anchor="Definition of done - MANDATORY custom delivery workflow"

  # A tab after the hashes opens an ATX heading in CommonMark exactly as a space
  # does. The hashtag passthrough must survive it: `#tag` has no whitespace at all.
  printf '#\tflowproj custom delivery workflow\n\n##\tFlow\n\n1. Open the DRAFT PR, then present the local preview.\n\n#flowproj is a hashtag, not a heading\n' \
    > "$home/data/project-flows/flowproj.md"
  id="brief-flow-tab-heading"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "custom-flow brief with a tab-separated note heading was not scaffolded"
  assert_gate_under_anchor "$brief" "$anchor" \
    "a tab-separated note heading stranded the \`done:\` gate outside the section rule 5 names"
  assert_one_dod "$brief" "custom-flow brief with a tab-separated note heading"
  assert_line "##${TAB}flowproj custom delivery workflow" "$brief" \
    "a tab-separated top-level heading escaped demotion"
  assert_line "###${TAB}Flow" "$brief" \
    "a tab-separated section heading escaped demotion"
  assert_no_line "#${TAB}flowproj custom delivery workflow" "$brief" \
    "the tab-separated top-level heading survived and still closes the Definition of done section"
  assert_line "#flowproj is a hashtag, not a heading" "$brief" \
    "a hashtag with no whitespace after the hashes was rewritten as a heading"

  # A CRLF note: the underline rules anchor at end of line, so a carriage return
  # left in place hides the underline and leaves the note's H1 standing.
  printf 'flowproj custom delivery workflow\r\n================================\r\n\r\nflowproj ships through this flow.\r\n\r\n1. Open the DRAFT PR, then present the local preview.\r\n' \
    > "$home/data/project-flows/flowproj.md"
  id="brief-flow-crlf-heading"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "custom-flow brief with a CRLF note was not scaffolded"
  assert_gate_under_anchor "$brief" "$anchor" \
    "a CRLF note heading stranded the \`done:\` gate outside the section rule 5 names"
  assert_one_dod "$brief" "custom-flow brief with a CRLF note"
  assert_line "## flowproj custom delivery workflow" "$brief" \
    "a CRLF underline-style top-level heading escaped demotion"
  assert_no_line "================================${CR}" "$brief" \
    "the CRLF note's heading underline survived and still closes the Definition of done section"
  assert_no_line "flowproj custom delivery workflow${CR}" "$brief" \
    "the CRLF note's heading text was left as bare prose above its underline"
  assert_no_line "flowproj custom delivery workflow" "$brief" \
    "the CRLF note's heading text was left as bare prose with its carriage return stripped"
  assert_line "1. Open the DRAFT PR, then present the local preview." "$brief" \
    "the CRLF note lost its flow steps, or kept a carriage return the brief has no use for"
  pass "fm-brief.sh: tab-separated and CRLF note headings are demoted under the anchor"
}

# A `#` with nothing after it is an empty heading in CommonMark, not a hashtag, so
# it closes the anchor section exactly as a titled heading does. It reaches the
# brief through two different paths - the note body, and a real front-matter block
# that is passed through verbatim - and both must demote it, or the completion gate
# ends up outside the section rule 5 names.
test_custom_flow_note_empty_headings_are_demoted() {
  local home id brief anchor
  home="$TMP_ROOT/flow-note-empty-heading-home"
  mkdir -p "$home/data/project-flows"
  printf -- '- flowproj [no-mistakes] - flow project (added 2026-08-06)\n' > "$home/data/projects.md"
  anchor="Definition of done - MANDATORY custom delivery workflow"

  cat > "$home/data/project-flows/flowproj.md" <<'EOF'
# flowproj custom delivery workflow

#

1. Open the DRAFT PR, then present the local preview.

#flowproj is a hashtag, not a heading
EOF
  id="brief-flow-empty-heading-body"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "custom-flow brief with an empty note heading was not scaffolded"
  assert_gate_under_anchor "$brief" "$anchor" \
    "an empty note heading stranded the \`done:\` gate outside the section rule 5 names"
  assert_one_dod "$brief" "custom-flow brief with an empty note heading"
  assert_line "##" "$brief" \
    "an empty top-level heading in the note body escaped demotion"
  assert_no_line "#" "$brief" \
    "the empty top-level heading survived and still closes the Definition of done section"
  assert_line "#flowproj is a hashtag, not a heading" "$brief" \
    "a hashtag with no whitespace after the hashes was rewritten as a heading"

  # The same shape inside real, terminated front matter: the region is passed
  # through verbatim, so it is the one place a note line reaches the brief without
  # being classified, and an empty heading there closes the section just the same.
  cat > "$home/data/project-flows/flowproj.md" <<'EOF'
---
owner: captain
#
---
# flowproj custom delivery workflow

1. Open the DRAFT PR, then present the local preview.
EOF
  id="brief-flow-empty-heading-frontmatter"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "custom-flow brief with an empty front-matter heading was not scaffolded"
  assert_gate_under_anchor "$brief" "$anchor" \
    "an empty heading inside front matter stranded the \`done:\` gate outside the section rule 5 names"
  assert_one_dod "$brief" "custom-flow brief with an empty front-matter heading"
  assert_no_line "#" "$brief" \
    "an empty heading inside front matter reached the brief undemoted and closes the Definition of done section"
  assert_line "## flowproj custom delivery workflow" "$brief" \
    "the note body below the front matter was not demoted"
  assert_grep "Open the DRAFT PR, then present the local preview." "$brief" \
    "the note lost its flow steps while its front matter was classified"
  pass "fm-brief.sh: an empty note heading is demoted in the body and inside front matter"
}

# The completion bridge must not send a review-ready handoff to the pause verb.
# Rule 5 in the same brief reserves that verb for a wait that clears on its own,
# and firstmate answers it by leaving the idle pane alone on a long recheck
# cadence - so a crewmate that reports a captain preview or a PR review that way
# goes quiet and the captain is never told the work is ready. `needs-decision:`
# is the verb that means a human must act.
test_custom_flow_bridge_escalates_a_human_handoff_instead_of_pausing() {
  local home id brief
  home="$TMP_ROOT/flow-handoff-verb-home"
  mkdir -p "$home/data/project-flows"
  printf -- '- flowproj [no-mistakes] - flow project (added 2026-08-04)\n' > "$home/data/projects.md"
  printf 'Open the draft PR, then present the preview for the captain to review.\n' \
    > "$home/data/project-flows/flowproj.md"
  id="brief-flow-handoff-verb"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "custom-flow brief was not scaffolded"
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_grep 'Append `needs-decision: {what firstmate or the captain must decide}`' "$brief" \
    "the completion bridge does not escalate a human handoff to firstmate or the captain"
  assert_grep "will not clear on its own" "$brief" \
    "the completion bridge does not distinguish a human handoff from a self-clearing wait"
  assert_no_grep "waits on a review or deploy you must return to" "$brief" \
    "the completion bridge still routes a review handoff to the declared-external-wait verb"
  assert_grep "such as a deploy run in progress" "$brief" \
    "the completion bridge no longer reserves the pause verb for a self-clearing wait"
  # The bridge must speak the configured pause verb, not a hardcoded "paused".
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
    "$ROOT/bin/fm-brief.sh" "$id-verb" flowproj >/dev/null 2>&1
  brief="$home/data/$id-verb/brief.md"
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_grep 'Append `awaiting: {why}` only for a bounded wait' "$brief" \
    "the completion bridge hardcodes the default pause verb"
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_no_grep '`paused: {why}`' "$brief" \
    "the completion bridge still instructs the default pause status"
  pass "fm-brief.sh: the custom-flow bridge escalates a human handoff, never pauses on it"
}

# The generic no-mistakes gate this bridge replaces asked for
# `done: PR {url} checks green`, and firstmate feeds that URL straight into its
# PR-ready step. Every real custom flow opens a draft PR, so a summary-only
# status line would drop the one structured detail firstmate acts on. The bridge
# is mode-independent, so every custom-flow brief must carry the requirement.
test_custom_flow_bridge_keeps_the_pr_url_on_the_status_line() {
  local home id brief mode n
  n=0
  for mode in no-mistakes direct-PR local-only; do
    n=$((n + 1))
    home="$TMP_ROOT/flow-pr-url-home-$n"
    mkdir -p "$home/data/project-flows"
    printf -- '- flowproj [%s] - flow project (added 2026-08-04)\n' "$mode" > "$home/data/projects.md"
    printf 'Push the branch and open a DRAFT PR, then present the preview.\n' \
      > "$home/data/project-flows/flowproj.md"
    id="brief-flow-pr-url-$n"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$mode custom-flow brief was not scaffolded"
    assert_grep "$(rule1_marker "$mode" "$id")" "$brief" \
      "$mode custom-flow brief did not resolve to the $mode delivery mode"
    # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
    assert_grep 'name it in that status line as its full `https://...` URL' "$brief" \
      "$mode custom-flow brief does not require the PR's full URL on the status line"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'done: PR https://.../pull/{n} {summary}' "$brief" \
      "$mode custom-flow brief lost the worked example of a PR completion line"
    # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
    assert_grep 'the same URL inside the `needs-decision:` line' "$brief" \
      "$mode custom-flow brief drops the PR URL when the flow ends at a human gate"
  done
  pass "fm-brief.sh: the custom-flow bridge keeps a PR's full URL on the status line"
}

# Scout and secondmate scaffolds are byte-identical whether or not the project
# carries a custom-flow note. Generating both from the same home and task id
# keeps every embedded path and id identical, so this diff fails loudly if the
# ship-only injection ever leaks into a deliverable that is not a delivery.
test_custom_flow_note_leaves_scout_and_secondmate_briefs_byte_identical() {
  local home id brief with_note
  home="$TMP_ROOT/flow-byte-identical-home"
  mkdir -p "$home/data/project-flows"
  printf -- '- flowproj [no-mistakes] - flow project (added 2026-08-04)\n' > "$home/data/projects.md"
  printf 'Open the draft PR, then merge to the stage branch.\n' \
    > "$home/data/project-flows/flowproj.md"
  with_note="$TMP_ROOT/flow-byte-identical-with-note.md"

  id="brief-flow-scout-identical"
  brief="$home/data/$id/brief.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj --scout >/dev/null 2>&1
  assert_present "$brief" "scout brief with a note present was not scaffolded"
  cp "$brief" "$with_note"
  rm -f "$brief" "$home/data/project-flows/flowproj.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj --scout >/dev/null 2>&1
  assert_present "$brief" "scout brief with no note was not scaffolded"
  cmp -s "$with_note" "$brief" \
    || fail "a custom-flow note changed the scout brief; it must be byte-identical"

  printf 'Open the draft PR, then merge to the stage branch.\n' \
    > "$home/data/project-flows/flowproj.md"
  id="brief-flow-secondmate-identical"
  brief="$home/data/$id/brief.md"
  FM_SECONDMATE_CHARTER='Own the flowproj domain.' FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" "$id" --secondmate flowproj >/dev/null 2>&1
  assert_present "$brief" "secondmate charter with a note present was not scaffolded"
  cp "$brief" "$with_note"
  rm -f "$brief" "$home/data/project-flows/flowproj.md"
  FM_SECONDMATE_CHARTER='Own the flowproj domain.' FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" "$id" --secondmate flowproj >/dev/null 2>&1
  assert_present "$brief" "secondmate charter with no note was not scaffolded"
  cmp -s "$with_note" "$brief" \
    || fail "a custom-flow note changed the secondmate charter; it must be byte-identical"

  # Positive control for the two comparisons above: run the identical
  # with-note/without-note procedure on a ship brief, where the note MUST change
  # the output. If this one compared equal, the byte-identical assertions would
  # be proving nothing.
  printf 'Open the draft PR, then merge to the stage branch.\n' \
    > "$home/data/project-flows/flowproj.md"
  id="brief-flow-ship-differs"
  brief="$home/data/$id/brief.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  assert_present "$brief" "ship brief with a note present was not scaffolded"
  cp "$brief" "$with_note"
  rm -f "$brief" "$home/data/project-flows/flowproj.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj >/dev/null 2>&1
  assert_present "$brief" "ship brief with no note was not scaffolded"
  ! cmp -s "$with_note" "$brief" \
    || fail "a custom-flow note did not change the ship brief, so this comparison proves nothing"
  pass "fm-brief.sh: a custom-flow note never reaches scout or secondmate scaffolds"
}

# A project WITHOUT a note must scaffold exactly as today: no injected section,
# no leaked heading, and the generic Definition of done intact.
test_no_custom_flow_note_scaffolds_unchanged() {
  local home id brief
  home="$TMP_ROOT/no-custom-flow-home"
  mkdir -p "$home/data"
  id="brief-no-custom-flow-e2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" plainproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "plain ship brief was not scaffolded"
  assert_no_grep "MANDATORY custom delivery workflow" "$brief" \
    "plain brief leaked a custom-flow section with no note present"
  assert_no_grep "only definition of done" "$brief" \
    "plain brief leaked custom-flow definition-of-done wording with no note present"
  assert_grep "# Definition of done" "$brief" \
    "plain brief lost its Definition of done section"
  pass "fm-brief.sh: a project with no custom-flow note scaffolds unchanged"
}

# An empty note file is not a marker: it must not inject an empty mandatory
# section, so the brief scaffolds exactly as the no-note case.
test_empty_custom_flow_note_is_not_a_marker() {
  local home id brief
  home="$TMP_ROOT/empty-custom-flow-home"
  mkdir -p "$home/data/project-flows"
  : > "$home/data/project-flows/emptyproj.md"
  id="brief-empty-custom-flow-e3"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" emptyproj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_no_grep "MANDATORY custom delivery workflow" "$brief" \
    "an empty note wrongly injected a custom-flow section"
  pass "fm-brief.sh: an empty custom-flow note is treated as absent"
}

# A scout for a custom-flow project produces a report, not a delivery, so it must
# NOT carry the delivery-workflow contract even when the note exists.
test_scout_does_not_inject_custom_flow() {
  local home id brief
  home="$TMP_ROOT/scout-custom-flow-home"
  mkdir -p "$home/data/project-flows"
  printf 'Custom stage flow marker line.\n' > "$home/data/project-flows/flowproj.md"
  id="brief-scout-custom-flow-e4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj --scout >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_no_grep "MANDATORY custom delivery workflow" "$brief" \
    "scout brief wrongly injected the ship delivery-workflow contract"
  pass "fm-brief.sh: a scout never carries the ship custom-flow contract"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# --promote writes ship instructions to a sibling promote.md (leaving the scout's
# brief.md intact), applies the SAME custom-flow injection as a fresh ship brief,
# and replaces the fresh-clone Setup with the scratch-to-clean-base promotion Setup.
test_promote_flag_writes_promote_md_with_flow_and_promotion_setup() {
  local home id brief note
  home="$TMP_ROOT/promote-flag-home"
  mkdir -p "$home/data/project-flows"
  note="$home/data/project-flows/flowproj.md"
  cat > "$note" <<'EOF'
Custom stage flow for flowproj:
1. Start the dev server for the local visual preview owed to the captain.
EOF
  # The scout's original brief.md must survive the promotion untouched.
  mkdir -p "$home/data/promote-f1"
  printf 'original scout brief\n' > "$home/data/promote-f1/brief.md"
  id="promote-f1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" flowproj --promote >/dev/null 2>&1
  brief="$home/data/$id/promote.md"
  assert_present "$brief" "--promote did not scaffold promote.md"
  assert_grep "original scout brief" "$home/data/$id/brief.md" \
    "--promote overwrote the scout's original brief.md"
  assert_grep "# Setup - promotion from scout to ship" "$brief" \
    "--promote brief missing the promotion Setup heading"
  assert_grep "Inventory your scratch state" "$brief" \
    "--promote brief missing the scratch-inventory step"
  assert_no_grep "at a detached HEAD on a clean default branch" "$brief" \
    "--promote brief kept the fresh-clone Setup text"
  assert_grep "MANDATORY custom delivery workflow" "$brief" \
    "--promote brief did not inject the custom-flow contract"
  assert_grep "local visual preview owed to the captain" "$brief" \
    "--promote brief lost the note body"
  # The --promote brief is self-contained: no {TASK} placeholder, and the Task
  # section points at the scout's own brief.md and report.md.
  # shellcheck disable=SC2016 # Literal {TASK} is the placeholder we assert is absent.
  assert_no_grep '{TASK}' "$brief" \
    "--promote brief left an unsubstituted {TASK} placeholder"
  assert_grep "recorded in $home/data/$id/brief.md and $home/data/$id/report.md" "$brief" \
    "--promote brief lost the self-contained pointer to the scout's brief.md and report.md"
  assert_grep "Never add a co-author trailer naming an AI model or assistant" "$brief" \
    "--promote brief missing the AI co-author trailer ban"
  pass "fm-brief.sh: --promote writes promote.md with promotion Setup and custom-flow injection"
}

# --promote on a no-note project scaffolds the generic instructions unchanged.
test_promote_flag_no_note_scaffolds_generic() {
  local home id brief
  home="$TMP_ROOT/promote-flag-plain-home"
  mkdir -p "$home/data"
  id="promote-f2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" plainproj --promote >/dev/null 2>&1
  brief="$home/data/$id/promote.md"
  assert_present "$brief" "--promote did not scaffold promote.md for a no-note project"
  assert_no_grep "MANDATORY custom delivery workflow" "$brief" \
    "--promote no-note brief leaked a custom-flow section"
  assert_grep "# Definition of done" "$brief" \
    "--promote no-note brief lost its Definition of done section"
  pass "fm-brief.sh: --promote on a no-note project scaffolds generic instructions"
}

# --promote applies only to ship briefs, never scout or secondmate.
test_promote_flag_rejects_scout_and_secondmate() {
  local home status
  home="$TMP_ROOT/promote-flag-guard-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ps1 repo --scout --promote >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--promote with --scout must fail"
  assert_absent "$home/data/ps1/promote.md" "rejected --promote --scout still wrote a file"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x "$ROOT/bin/fm-brief.sh" ps2 --secondmate --no-projects --promote >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--promote with --secondmate must fail"
  pass "fm-brief.sh: --promote is rejected for scout and secondmate briefs"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"
  assert_grep "Never add a co-author trailer naming an AI model or assistant" "$brief" \
    "scout brief missing the AI co-author trailer ban"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_rule_cross_references_stay_pinned_to_their_rule
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_custom_flow_note_injected_into_ship_brief
test_custom_flow_replaces_generic_definition_of_done
test_custom_flow_states_precedence_over_mode_rules
test_pipeline_trigger_guard_rejects_every_reinstated_trigger
test_custom_flow_keeps_no_mistakes_pipeline_guardrails
test_pipeline_rules_do_not_hang_on_the_setup_doctor_line
test_custom_flow_keeps_mode_branch_and_handover_mechanics
test_ci_ready_token_stays_on_the_pipeline_path
test_rule5_points_at_the_heading_holding_the_done_gate
test_custom_flow_note_with_its_own_headings_keeps_the_gate_under_the_anchor
test_custom_flow_note_with_underline_headings_keeps_the_gate_under_the_anchor
test_custom_flow_note_leading_dashes_still_demote_headings
test_custom_flow_note_indented_headings_are_demoted
test_custom_flow_note_tab_and_crlf_headings_are_demoted
test_custom_flow_note_empty_headings_are_demoted
test_custom_flow_bridge_escalates_a_human_handoff_instead_of_pausing
test_custom_flow_bridge_keeps_the_pr_url_on_the_status_line
test_custom_flow_note_leaves_scout_and_secondmate_briefs_byte_identical
test_no_custom_flow_note_scaffolds_unchanged
test_empty_custom_flow_note_is_not_a_marker
test_scout_does_not_inject_custom_flow
test_scout_and_secondmate_load_decision_hold_policy
test_promote_flag_writes_promote_md_with_flow_and_promotion_setup
test_promote_flag_no_note_scaffolds_generic
test_promote_flag_rejects_scout_and_secondmate
test_scout_and_secondmate_scaffold
