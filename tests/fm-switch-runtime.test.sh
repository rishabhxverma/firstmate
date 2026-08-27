#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for bin/fm-switch-runtime.sh.
#
# Drives the real script against fixture homes through its documented env seam
# (FM_HOME, FM_SWITCH_NM_CONFIG, FM_SWITCH_OPENCODE_JSON), so no test touches the
# real ~/.no-mistakes or ~/.config state. Covers both switch directions, comment
# preservation, idempotency, the model-pin offer gate, usage errors, and --status.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-switch-runtime.sh"
T=$(fm_test_tmproot switch-runtime)
HOME_DIR="$T/home"
CREW="$HOME_DIR/config/crew-harness"
NM="$T/nm.yaml"
OCJSON="$T/opencode.json"

# A realistic slice of the real no-mistakes config: leading comments, the agent
# key with dated notes around it, then unrelated keys that must survive intact.
nm_fixture() {
  local agent=$1
  cat > "$NM" <<EOF
# no-mistakes global configuration

# Agent to use for code generation
# Options: auto, claude, codex, rovodev, opencode, pi, acp:<target>
# 2026-08-25: switched from auto(claude) to opencode+oxalpha on captain instruction
agent: ${agent}
# 2026-08-26: captain ruled repos WITH AGENTS.md validate on claude

log_level: info
auto_fix:
  rebase: 3
  lint: 3
intent:
  enabled: true
EOF
}

oc_fixture() {
  local model=$1
  if [ "$model" = "none" ]; then
    cat > "$OCJSON" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "aws-mcp": { "type": "local", "command": ["uvx", "proxy"] }
  }
}
JSON
  elif [ "$model" = "missing" ]; then
    rm -f "$OCJSON"
  else
    printf '{\n  "model": "%s"\n}\n' "$model" > "$OCJSON"
  fi
}

reset_fixtures() {
  mkdir -p "$HOME_DIR/config"
  nm_fixture opencode
  oc_fixture opencode/x-preview-f-free
  printf 'opencode\n' > "$CREW"
}

switch() {
  FM_HOME="$HOME_DIR" FM_SWITCH_NM_CONFIG="$NM" FM_SWITCH_OPENCODE_JSON="$OCJSON" \
    "$SCRIPT" "$@"
}

crew_line() { cat "$CREW"; }
nm_agent() { grep -E '^agent:' "$NM"; }
oc_model() { jq -r '.model // ""' "$OCJSON" 2>/dev/null; }

# --- usage errors ------------------------------------------------------------

out=$(switch 2>&1)
code=$?
expect_code 1 "$code" "no argument exits 1"
assert_contains "$out" "Usage:" "no argument prints usage"

out=$(switch codex 2>&1)
code=$?
expect_code 1 "$code" "unsupported target exits 1"
assert_contains "$out" "Usage:" "unsupported target prints usage"

out=$(switch opencode extra 2>&1)
code=$?
expect_code 1 "$code" "extra positional exits 1"

out=$(switch --status extra 2>&1)
code=$?
expect_code 1 "$code" "--status with extra arg exits 1"

# --- switch to claude --------------------------------------------------------

reset_fixtures
out=$(switch claude 2>&1) || fail "claude switch should succeed: $out"
assert_contains "$out" "NOT switched automatically" "claude switch prints limits"
assert_contains "$out" "relaunch the primary session" "claude switch names relaunch duty"
[ "$(crew_line)" = "claude" ] || fail "crew-harness should be 'claude', got: $(crew_line)"
[ "$(nm_agent)" = "agent: claude" ] || fail "agent key should be claude, got: $(nm_agent)"
assert_grep "# 2026-08-25: switched from auto(claude) to opencode+oxalpha on captain instruction" \
  "$NM" "comment above agent key preserved"
assert_grep "# 2026-08-26: captain ruled repos WITH AGENTS.md validate on claude" \
  "$NM" "comment below agent key preserved"
assert_grep "log_level: info" "$NM" "unrelated top-level key preserved"
assert_grep "rebase: 3" "$NM" "nested key preserved"
[ "$(oc_model)" = "opencode/x-preview-f-free" ] || fail "opencode.json must be untouched by claude switch"

# --- idempotency, claude direction -------------------------------------------

before_nm=$(cat "$NM")
before_crew=$(cat "$CREW")
out=$(switch claude 2>&1) || fail "idempotent claude re-run should succeed"
assert_contains "$out" "unchanged" "idempotent claude re-run reports unchanged crew harness"
[ "$(cat "$NM")" = "$before_nm" ] || fail "second claude run must not modify nm config bytes"
[ "$(cat "$CREW")" = "$before_crew" ] || fail "second claude run must not modify crew-harness bytes"

# --- switch to opencode ------------------------------------------------------

oc_fixture opencode/x-preview-f-free
out=$(switch opencode 2>&1) || fail "opencode switch should succeed: $out"
[ "$(crew_line)" = "opencode" ] ||
  fail "crew-harness should be the bare adapter name, got: $(crew_line)"
crew_resolved=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-harness.sh" crew 2>/dev/null)
[ "$crew_resolved" = "opencode" ] ||
  fail "fm-harness.sh resolve_crew must accept the written crew-harness, got: $crew_resolved"
[ "$(nm_agent)" = "agent: opencode" ] || fail "agent key should be opencode, got: $(nm_agent)"
assert_contains "$out" "model pin: ok" "satisfied pin reported ok"

# --- idempotency, opencode direction -----------------------------------------

before_nm=$(cat "$NM")
before_crew=$(cat "$CREW")
before_oc=$(cat "$OCJSON")
out=$(switch opencode 2>&1) || fail "idempotent opencode re-run should succeed"
[ "$(cat "$NM")" = "$before_nm" ] || fail "second opencode run must not modify nm config bytes"
[ "$(cat "$CREW")" = "$before_crew" ] || fail "second opencode run must not modify crew-harness bytes"
[ "$(cat "$OCJSON")" = "$before_oc" ] || fail "second opencode run must not modify opencode.json"

# --- round trip both directions ----------------------------------------------

switch claude >/dev/null 2>&1 || fail "round trip leg 1"
[ "$(nm_agent)" = "agent: claude" ] || fail "round trip claude leg failed"
switch opencode </dev/null >/dev/null 2>&1 || fail "round trip leg 2"
[ "$(nm_agent)" = "agent: opencode" ] || fail "round trip opencode leg failed"
assert_grep "log_level: info" "$NM" "config still healthy after round trip"

# --- model pin offer: accepted -----------------------------------------------

reset_fixtures
oc_fixture none
out=$(printf 'y\n' | switch opencode 2>&1) || fail "accepted pin offer should succeed: $out"
[ "$(oc_model)" = "opencode/x-preview-f-free" ] || fail "pin should be added after yes"
[ "$(nm_agent)" = "agent: opencode" ] || fail "switch should complete after accepted offer"
assert_grep "https://opencode.ai/config.json" "$OCJSON" "existing keys survive pin addition"
assert_grep 'aws-mcp' "$OCJSON" "mcp block survives pin addition"

# --- model pin offer: declined aborts before any write ------------------------

reset_fixtures
nm_fixture claude
printf 'claude\n' > "$CREW"
oc_fixture missing
out=$(printf 'n\n' | switch opencode 2>&1)
code=$?
expect_code 1 "$code" "declined pin offer exits non-zero"
assert_contains "$out" "aborted without changing anything" "decline message explains no writes"
[ "$(crew_line)" = "claude" ] || fail "declined offer must not touch crew-harness, got: $(crew_line)"
[ "$(nm_agent)" = "agent: claude" ] || fail "declined offer must not touch nm config, got: $(nm_agent)"
out=$(switch opencode </dev/null 2>&1)
code=$?
expect_code 1 "$code" "EOF at prompt counts as decline"
assert_absent "$OCJSON" "declined offer must not create opencode.json"
[ "$(crew_line)" = "claude" ] || fail "EOF decline must not touch crew-harness"
[ "$(nm_agent)" = "agent: claude" ] || fail "EOF decline must not touch nm config"

# --- malformed opencode.json fails fast before any prompt or write -------------

reset_fixtures
nm_fixture claude
printf 'claude\n' > "$CREW"
printf '{ bad json\n' > "$OCJSON"
out=$(printf 'y\n' | switch opencode 2>&1)
code=$?
expect_code 1 "$code" "invalid opencode.json exits 1"
assert_contains "$out" "not valid JSON" "invalid opencode.json error names the problem"
assert_not_contains "$out" "[y/N]" "invalid opencode.json must not reach the pin offer"
[ "$(cat "$OCJSON")" = "{ bad json" ] || fail "invalid opencode.json must be left untouched"
[ "$(crew_line)" = "claude" ] || fail "invalid opencode.json must abort before crew-harness write"
[ "$(nm_agent)" = "agent: claude" ] || fail "invalid opencode.json must abort before nm write"
[ -z "$(ls "$T"/opencode.json.tmp.* "$T"/nm.yaml.tmp.* 2>/dev/null)" ] ||
  fail "no temp files may be left behind after a failed switch"
out=$(switch --status 2>&1)
code=$?
expect_code 1 "$code" "--status on invalid opencode.json exits 1"
assert_contains "$out" "not valid JSON" "--status names the invalid opencode.json"

# --- missing jq fails fast without leaving temp files ---------------------------

reset_fixtures
nm_fixture claude
printf 'claude\n' > "$CREW"
oc_fixture missing
nojq=$(fm_test_tmproot switch-runtime-nojq)/bin
mkdir -p "$nojq"
for tool in bash sh grep sed awk head cat mktemp mv chmod stat dirname mkdir tr ls; do
  real=$(command -v "$tool") && ln -sf "$real" "$nojq/$tool"
done
out=$(printf 'y\n' | PATH="$nojq" switch opencode 2>&1)
code=$?
expect_code 1 "$code" "missing jq exits 1"
assert_contains "$out" "jq is required" "missing jq error names jq"
assert_not_contains "$out" "[y/N]" "missing jq must not reach the pin offer"
assert_absent "$OCJSON" "missing jq must not create opencode.json"
[ "$(crew_line)" = "claude" ] || fail "missing jq must abort before crew-harness write"
[ -z "$(ls "$T"/opencode.json.tmp.* "$T"/nm.yaml.tmp.* 2>/dev/null)" ] ||
  fail "no temp files may be left behind when jq is missing"

# --- different existing pin is kept and warned -------------------------------

reset_fixtures
oc_fixture opencode/some-paid-model
out=$(switch opencode </dev/null 2>&1) || fail "different pin should not block switch: $out"
[ "$(oc_model)" = "opencode/some-paid-model" ] || fail "deliberate pin must not be overwritten"
assert_contains "$out" "WARNING" "non-oxalpha pin produces a warning"

# --- missing no-mistakes config -----------------------------------------------

reset_fixtures
rm -f "$NM"
out=$(switch claude 2>&1)
code=$?
expect_code 1 "$code" "missing nm config exits 1"
assert_contains "$out" "required file not found" "missing config error names the file"
[ "$(crew_line)" = "opencode" ] ||
  fail "failed preflight must not have touched crew-harness"

# --- agent key absent gets inserted top-level ---------------------------------

reset_fixtures
grep -vE '^agent:' "$NM" > "$NM.new" && mv "$NM.new" "$NM"
switch claude >/dev/null 2>&1 || fail "insert branch should succeed"
[ "$(nm_agent)" = "agent: claude" ] || fail "inserted agent key should be first-class"
first_non_comment=$(grep -vE '^[[:blank:]]*(#|$)' "$NM" | head -n 1)
[ "$first_non_comment" = "agent: claude" ] ||
  fail "inserted key must precede other top-level keys, got: $first_non_comment"

# --- inline comment on the agent line survives --------------------------------

reset_fixtures
nm_fixture 'claude # why'
switch opencode >/dev/null 2>&1 || fail "switch with inline comment should succeed"
[ "$(nm_agent)" = "agent: opencode # why" ] ||
  fail "inline comment on agent line must survive, got: $(nm_agent)"
before_nm=$(cat "$NM")
out=$(switch opencode 2>&1) || fail "converged run on commented agent line should succeed"
[ "$(cat "$NM")" = "$before_nm" ] ||
  fail "converged run on commented agent line must be byte-identical"
switch claude >/dev/null 2>&1 || fail "switch back with inline comment should succeed"
[ "$(nm_agent)" = "agent: claude # why" ] ||
  fail "inline comment must survive the reverse direction, got: $(nm_agent)"
out=$(switch --status 2>&1)
assert_contains "$out" "pipeline agent: claude (" "status strips the inline comment from the agent value"

nm_fixture '"claude"'
switch opencode >/dev/null 2>&1 || fail "switch with quoted agent value should succeed"
[ "$(nm_agent)" = "agent: opencode" ] || fail "quoted value normalizes to bare, got: $(nm_agent)"

# --- empty agent value gets a well-formed separator ----------------------------

nm_fixture ''
switch opencode >/dev/null 2>&1 || fail "switch from empty agent value should succeed"
[ "$(nm_agent)" = "agent: opencode" ] || fail "empty value must become 'agent: opencode', got: $(nm_agent)"

nm_fixture '# c'
switch opencode >/dev/null 2>&1 || fail "switch from comment-only agent value should succeed"
[ "$(nm_agent)" = "agent: opencode # c" ] ||
  fail "comment-only value must become 'agent: opencode # c', got: $(nm_agent)"

nm_fixture '   claude   # c'
switch opencode >/dev/null 2>&1 || fail "switch from padded agent value should succeed"
[ "$(nm_agent)" = "agent: opencode   # c" ] ||
  fail "padded value normalizes the separator and keeps the comment, got: $(nm_agent)"

# --- status -------------------------------------------------------------------

reset_fixtures
out=$(switch --status 2>&1)
assert_contains "$out" "crew harness: opencode (" "status shows crew harness"
assert_contains "$out" "pipeline agent: opencode" "status shows pipeline agent"
assert_contains "$out" "opencode model pin: opencode/x-preview-f-free" "status shows model pin"
assert_not_contains "$out" "disagree" "converged surfaces report no disagreement"
assert_not_contains "$out" "note:" "converged surfaces print no note"

# Drifted surfaces get flagged.
nm_fixture claude
out=$(switch --status 2>&1)
assert_contains "$out" "pipeline agent: claude" "status reflects drifted pipeline agent"
assert_contains "$out" "disagree" "status flags drifted surfaces"

# A wrong or absent model pin is drift too when either surface is opencode.
reset_fixtures
oc_fixture opencode/some-paid-model
out=$(switch --status 2>&1)
assert_contains "$out" "opencode model pin: opencode/some-paid-model" "status shows the drifted pin"
assert_contains "$out" "note: opencode model pin is 'opencode/some-paid-model'" "status flags a wrong model pin"
assert_not_contains "$out" "disagree" "wrong pin alone is not a crew-vs-agent disagreement"

oc_fixture none
out=$(switch --status 2>&1)
assert_contains "$out" "note: opencode model pin is absent" "status flags a missing model key"

oc_fixture missing
out=$(switch --status 2>&1)
assert_contains "$out" "opencode model pin: absent" "status reports absent opencode.json"
assert_contains "$out" "note: opencode model pin is absent" "status flags an absent opencode.json"

nm_fixture claude
printf 'claude\n' > "$CREW"
out=$(switch --status 2>&1)
assert_not_contains "$out" "note:" "claude-converged home without a pin prints no note"

# Whitespace around the crew-harness token is ignored, matching resolve_crew.
reset_fixtures
printf '  opencode \n' > "$CREW"
out=$(switch --status 2>&1)
assert_contains "$out" "crew harness: opencode (" "status trims whitespace around the crew token"
assert_not_contains "$out" "note:" "padded crew token on a converged home prints no note"
oc_fixture none
out=$(switch --status 2>&1)
assert_contains "$out" "note: opencode model pin is absent" "padded crew token still drives the pin drift check"

# Absent surfaces are named, not silently blank.
rm -f "$OCJSON" "$CREW"
grep -vE '^agent:' "$NM" > "$NM.new" && mv "$NM.new" "$NM"
out=$(FM_HOME="$HOME_DIR" FM_SWITCH_NM_CONFIG="$NM" FM_SWITCH_OPENCODE_JSON="$OCJSON" \
  "$SCRIPT" --status 2>&1)
assert_contains "$out" "crew harness: absent" "status reports absent crew harness"
assert_contains "$out" "pipeline agent: unset" "status reports unset pipeline agent"
assert_contains "$out" "opencode model pin: absent" "status reports absent model pin"

pass "fm-switch-runtime behavior suite"
