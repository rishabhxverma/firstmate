#!/usr/bin/env bash
# fm-switch-runtime.sh - flip the fleet runtime between opencode+oxalpha and claude.
#
# One command replacing the three-file hand edit: crew-harness, the no-mistakes
# pipeline agent key, and the opencode model pin.
#
# Usage:
#   bin/fm-switch-runtime.sh <opencode|claude>   switch the runtime pins to the target
#   bin/fm-switch-runtime.sh --status            print the current runtime per surface
#   bin/fm-switch-runtime.sh --help              this help
#
# Surfaces switched:
#   1. <FM_HOME>/config/crew-harness       rewritten to one line holding the bare
#                                          adapter name ("opencode" or "claude"); the
#                                          consumer (fm-harness.sh resolve_crew) never
#                                          parses a model from this file.
#   2. ~/.no-mistakes/config.yaml          only the value token of the top-level
#                                          "agent:" key flipped between opencode and
#                                          claude; every other line, the surrounding
#                                          comments, and any inline comment on the
#                                          agent line itself are preserved.
#   3. ~/.config/opencode/opencode.json    checked ONLY when targeting opencode: the
#                                          "model" key must equal
#                                          opencode/x-preview-f-free, because
#                                          `opencode serve` rejects -m and this pin is
#                                          the only way workers get oxalpha, and the
#                                          only place the model is pinned. Missing pin
#                                          triggers an offer to add it; declining aborts
#                                          before any surface is touched. A present pin
#                                          naming a different model is kept and warned
#                                          about, never overwritten.
#
# Never switched automatically (printed on every successful run):
#   - Running no-mistakes runs keep their launch-time agent until they finish.
#   - The primary session itself must be relaunched under the other CLI by the captain.
#
# Environment overrides (test seam; production defaults shown):
#   FM_HOME                  home whose config/ holds crew-harness
#                            (default: the repo root containing this script)
#   FM_SWITCH_NM_CONFIG      no-mistakes config path (default: ~/.no-mistakes/config.yaml)
#   FM_SWITCH_OPENCODE_JSON  opencode config path (default: ~/.config/opencode/opencode.json)
#
# Idempotent in both directions: re-running a converged target changes nothing and
# exits 0. Exit codes: 0 success; 1 usage error, missing no-mistakes config,
# missing jq or unparseable opencode.json, declined model-pin offer, or failed write.
set -u

OPENCODE_MODEL="opencode/x-preview-f-free"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CREW_HARNESS_FILE="${FM_HOME}/config/crew-harness"
NM_CONFIG="${FM_SWITCH_NM_CONFIG:-${HOME}/.no-mistakes/config.yaml}"
OPENCODE_JSON="${FM_SWITCH_OPENCODE_JSON:-${HOME}/.config/opencode/opencode.json}"

TMP_FILE=""
cleanup_tmp() {
  [ -n "$TMP_FILE" ] && rm -f "$TMP_FILE"
  return 0
}
trap cleanup_tmp EXIT

die() {
  printf 'fm-switch-runtime: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: bin/fm-switch-runtime.sh <opencode|claude>
       bin/fm-switch-runtime.sh --status

Switches the fleet runtime between opencode+oxalpha and claude:
  1. rewrites <FM_HOME>/config/crew-harness
  2. flips the top-level "agent:" key in ~/.no-mistakes/config.yaml (comments preserved)
  3. when targeting opencode, verifies ~/.config/opencode/opencode.json pins
     "model": "opencode/x-preview-f-free" (offer to add it when absent)

Running no-mistakes runs keep their launch-time agent, and the primary session
must be relaunched under the other CLI by hand; both limits are printed per run.
EOF
}

usage_error() {
  usage
  exit 1
}

require_file() {
  [ -f "$1" ] || die "required file not found: $1"
}

# file_mode <path>: octal permission string, GNU stat first, BSD fallback.
file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || printf '644'
}

# crew_harness_value: first non-empty, non-comment line of crew-harness, or empty.
crew_harness_value() {
  [ -f "$CREW_HARNESS_FILE" ] || return 0
  grep -vE '^[[:blank:]]*(#|$)' "$CREW_HARNESS_FILE" | head -n 1
}

# nm_agent_value: trimmed top-level agent value from the no-mistakes config
# (inline comment and surrounding quotes stripped), or empty.
nm_agent_value() {
  [ -f "$NM_CONFIG" ] || return 0
  grep -E '^agent:' "$NM_CONFIG" | head -n 1 |
    sed -e 's/^agent:[[:blank:]]*//' -e 's/[[:blank:]]*#.*$//' \
      -e 's/[[:blank:]]*$//' -e 's/^"//' -e 's/"$//'
}

# require_jq <why>: die unless jq is on PATH. Called from the main process, never
# from inside a command substitution, so the die really exits.
require_jq() {
  command -v jq >/dev/null 2>&1 ||
    die "jq is required to $1 but was not found on PATH"
}

# preflight_opencode_json: when opencode.json exists, require jq and refuse to
# proceed if the file does not parse. Runs before any prompt or write.
preflight_opencode_json() {
  [ -f "$OPENCODE_JSON" ] || return 0
  require_jq "read $OPENCODE_JSON"
  jq empty "$OPENCODE_JSON" >/dev/null 2>&1 ||
    die "$OPENCODE_JSON is not valid JSON; fix it by hand before switching"
}

# opencode_model_pin: the "model" value from opencode.json, or empty when the
# file is absent. Callers run preflight_opencode_json first.
opencode_model_pin() {
  [ -f "$OPENCODE_JSON" ] || return 0
  jq -r '.model // ""' "$OPENCODE_JSON"
}

# write_file_preserving_mode <src> <dst>: atomically move src over dst while
# restoring dst's original permissions.
write_file_preserving_mode() {
  local src=$1 dst=$2 mode
  mode=$(file_mode "$dst")
  mv "$src" "$dst" || die "failed to replace $dst"
  TMP_FILE=""
  chmod "$mode" "$dst" || die "failed to restore permissions on $dst"
}

# set_crew_harness <target>: rewrite crew-harness to the bare adapter name.
set_crew_harness() {
  local target=$1 desired
  desired="$target"
  mkdir -p "$(dirname "$CREW_HARNESS_FILE")" ||
    die "cannot create $(dirname "$CREW_HARNESS_FILE")"
  if [ "$(crew_harness_value)" = "$desired" ]; then
    printf "crew harness: unchanged (%s)\n" "$CREW_HARNESS_FILE"
    return 0
  fi
  printf '%s\n' "$desired" > "$CREW_HARNESS_FILE" ||
    die "failed to write $CREW_HARNESS_FILE"
  printf "crew harness: updated -> '%s' (%s)\n" "$desired" "$CREW_HARNESS_FILE"
}

# set_nm_agent <target>: flip the top-level agent key in place, preserving every
# other line. Replaces only the value token of existing key lines, so a trailing
# inline comment survives; inserts the key before the first non-comment line
# when absent.
set_nm_agent() {
  local target=$1 tmp count
  count=$(grep -cE '^agent:' "$NM_CONFIG" || true)
  tmp=$(mktemp "${NM_CONFIG}.tmp.XXXXXX") ||
    die "cannot create temp file next to $NM_CONFIG"
  TMP_FILE="$tmp"
  if [ "${count:-0}" -gt 0 ]; then
    sed "s/^\(agent:[[:blank:]]*\)[^#[:blank:]]*/\1${target}/" "$NM_CONFIG" > "$tmp"
  else
    awk -v ins="agent: ${target}" '
      !done && $0 !~ /^[[:blank:]]*$/ && $0 !~ /^#/ { print ins; done = 1 }
      { print }
      END { if (!done) print ins }
    ' "$NM_CONFIG" > "$tmp"
  fi
  grep -qE "^agent:[[:blank:]]*${target}([[:blank:]]|\$)" "$tmp" ||
    die "rewrite of $NM_CONFIG did not produce 'agent: ${target}'"
  write_file_preserving_mode "$tmp" "$NM_CONFIG"
  printf "no-mistakes agent: set -> '%s' (%s)\n" "$target" "$NM_CONFIG"
}

# ensure_opencode_pin: enforce the model pin when switching to opencode.
# Returns 0 when the pin is satisfied (possibly just added), having printed a
# warning when a deliberate non-oxalpha pin was left in place.
ensure_opencode_pin() {
  local pin answer tmp
  require_jq "read or write $OPENCODE_JSON"
  preflight_opencode_json
  pin=$(opencode_model_pin)
  if [ "$pin" = "$OPENCODE_MODEL" ]; then
    printf "opencode model pin: ok ('%s' in %s)\n" "$pin" "$OPENCODE_JSON"
    return 0
  fi
  if [ -n "$pin" ]; then
    printf "opencode model pin: WARNING keeping existing '%s' in %s (expected '%s')\n" \
      "$pin" "$OPENCODE_JSON" "$OPENCODE_MODEL"
    return 0
  fi
  printf 'opencode model pin: MISSING in %s\n' "$OPENCODE_JSON"
  printf 'The opencode serve command rejects -m, so this pin is the only way workers get %s.\n' \
    "$OPENCODE_MODEL"
  if [ -f "$OPENCODE_JSON" ]; then
    printf 'Add "model": "%s" to %s? [y/N] ' "$OPENCODE_MODEL" "$OPENCODE_JSON"
  else
    printf 'Create %s with that model pin? [y/N] ' "$OPENCODE_JSON"
  fi
  read -r answer || answer=""
  case "$answer" in
    y | Y | yes | Yes | YES) ;;
    *)
      die "model pin declined; aborted without changing anything (re-run and answer yes, or pin the model by hand)"
      ;;
  esac
  mkdir -p "$(dirname "$OPENCODE_JSON")" ||
    die "cannot create $(dirname "$OPENCODE_JSON")"
  tmp=$(mktemp "${OPENCODE_JSON}.tmp.XXXXXX") ||
    die "cannot create temp file next to $OPENCODE_JSON"
  TMP_FILE="$tmp"
  if [ -f "$OPENCODE_JSON" ]; then
    jq --arg m "$OPENCODE_MODEL" '.model = $m' "$OPENCODE_JSON" > "$tmp" ||
      die "failed to update model pin in $OPENCODE_JSON (invalid JSON?)"
  else
    jq -n --arg m "$OPENCODE_MODEL" \
      '{"$schema": "https://opencode.ai/config.json", model: $m}' > "$tmp" ||
      die "failed to create $OPENCODE_JSON"
  fi
  write_file_preserving_mode "$tmp" "$OPENCODE_JSON"
  printf "opencode model pin: added -> '%s' (%s)\n" "$OPENCODE_MODEL" "$OPENCODE_JSON"
}

print_unswitchable_notes() {
  cat <<'EOF'
NOT switched automatically:
  - running no-mistakes runs keep their launch-time agent until they finish
  - relaunch the primary session under the target CLI yourself (exit, then start it)
EOF
}

cmd_switch() {
  local target=$1
  require_file "$NM_CONFIG"
  if [ "$target" = opencode ]; then
    ensure_opencode_pin
  fi
  set_crew_harness "$target"
  set_nm_agent "$target"
  if [ "$target" != opencode ]; then
    printf 'opencode model pin: not touched (target is claude)\n'
  fi
  print_unswitchable_notes
}

cmd_status() {
  local crew nm pin
  preflight_opencode_json
  crew=$(crew_harness_value)
  nm=$(nm_agent_value)
  pin=$(opencode_model_pin)
  printf 'runtime switch status\n'
  if [ -n "$crew" ]; then
    printf 'crew harness: %s (%s)\n' "$crew" "$CREW_HARNESS_FILE"
  else
    printf 'crew harness: absent (%s)\n' "$CREW_HARNESS_FILE"
  fi
  if [ -n "$nm" ]; then
    printf 'pipeline agent: %s (%s)\n' "$nm" "$NM_CONFIG"
  else
    printf 'pipeline agent: unset (%s)\n' "$NM_CONFIG"
  fi
  if [ -n "$pin" ]; then
    printf 'opencode model pin: %s (%s)\n' "$pin" "$OPENCODE_JSON"
  else
    printf 'opencode model pin: absent (%s)\n' "$OPENCODE_JSON"
  fi
  if [ -n "$crew" ] && [ -n "$nm" ] && [ "$crew" != "$nm" ]; then
    printf 'note: crew harness and pipeline agent disagree; run bin/fm-switch-runtime.sh <target> to converge\n'
  fi
  if { [ "$crew" = opencode ] || [ "$nm" = opencode ]; } && [ "$pin" != "$OPENCODE_MODEL" ]; then
    if [ -n "$pin" ]; then
      printf "note: opencode model pin is '%s', not '%s'; workers will not get oxalpha until %s pins it\n" \
        "$pin" "$OPENCODE_MODEL" "$OPENCODE_JSON"
    else
      printf "note: opencode model pin is absent; workers will not get oxalpha until %s pins '%s' (run bin/fm-switch-runtime.sh opencode)\n" \
        "$OPENCODE_JSON" "$OPENCODE_MODEL"
    fi
  fi
}

main() {
  case "${1:-}" in
    --help | -h)
      usage
      exit 0
      ;;
    --status)
      [ $# -eq 1 ] || usage_error
      cmd_status
      ;;
    opencode | claude)
      [ $# -eq 1 ] || usage_error
      cmd_switch "$1"
      ;;
    *)
      usage_error
      ;;
  esac
}

main "$@"
