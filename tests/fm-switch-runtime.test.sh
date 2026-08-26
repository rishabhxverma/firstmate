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
  printf 'opencode opencode/x-preview-f-free\n' > "$CREW"
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
expect_code 0 $? "claude switch exit code"
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
expect_code 0 $? "opencode switch exit code"
[ "$(crew_line)" = "opencode opencode/x-preview-f-free" ] ||
  fail "crew-harness should carry oxalpha model, got: $(crew_line)"
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
oc_fixture missing
before_crew=$(cat "$CREW")
out=$(printf 'n\n' | switch opencode 2>&1)
code=$?
expect_code 1 "$code" "declined pin offer exits non-zero"
assert_contains "$out" "aborted without changing anything" "decline message explains no writes"
[ "$(cat "$CREW")" = "$before_crew" ] || fail "declined offer must not touch crew-harness"
[ "$(nm_agent)" = "agent: opencode" ] || fail "declined offer must not touch nm config"
out=$(switch opencode </dev/null 2>&1)
code=$?
expect_code 1 "$code" "EOF at prompt counts as decline"
assert_absent "$OCJSON" "declined offer must not create opencode.json"

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
[ "$(crew_line)" = "opencode opencode/x-preview-f-free" ] ||
  fail "failed preflight must not have touched crew-harness"

# --- agent key absent gets inserted top-level ---------------------------------

reset_fixtures
grep -vE '^agent:' "$NM" > "$NM.new" && mv "$NM.new" "$NM"
switch claude >/dev/null 2>&1 || fail "insert branch should succeed"
[ "$(nm_agent)" = "agent: claude" ] || fail "inserted agent key should be first-class"
first_non_comment=$(grep -vE '^[[:blank:]]*(#|$)' "$NM" | head -n 1)
[ "$first_non_comment" = "agent: claude" ] ||
  fail "inserted key must precede other top-level keys, got: $first_non_comment"

# --- status -------------------------------------------------------------------

reset_fixtures
out=$(switch --status 2>&1)
assert_contains "$out" "crew harness: opencode opencode/x-preview-f-free" "status shows crew harness"
assert_contains "$out" "pipeline agent: opencode" "status shows pipeline agent"
assert_contains "$out" "opencode model pin: opencode/x-preview-f-free" "status shows model pin"
assert_not_contains "$out" "disagree" "converged surfaces report no disagreement"

# Drifted surfaces get flagged.
nm_fixture claude
out=$(switch --status 2>&1)
assert_contains "$out" "pipeline agent: claude" "status reflects drifted pipeline agent"
assert_contains "$out" "disagree" "status flags drifted surfaces"

# Absent surfaces are named, not silently blank.
rm -f "$OCJSON" "$CREW"
grep -vE '^agent:' "$NM" > "$NM.new" && mv "$NM.new" "$NM"
out=$(FM_HOME="$HOME_DIR" FM_SWITCH_NM_CONFIG="$NM" FM_SWITCH_OPENCODE_JSON="$OCJSON" \
  "$SCRIPT" --status 2>&1)
assert_contains "$out" "crew harness: absent" "status reports absent crew harness"
assert_contains "$out" "pipeline agent: unset" "status reports unset pipeline agent"
assert_contains "$out" "opencode model pin: absent" "status reports absent model pin"

pass "fm-switch-runtime behavior suite"
