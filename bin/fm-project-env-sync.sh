#!/usr/bin/env bash
# Converge every treehouse pool worktree for one project onto its declared
# local-environment source, repairing drift that predates or falls outside
# fm-spawn.sh's per-spawn convergence (bin/fm-project-env-lib.sh owns the
# merge-or-refuse contract and is a PRIME-DIRECTIVE-1 exception for this exact
# propagation; see its header and AGENTS.md section 1).
# Usage: fm-project-env-sync.sh <project-name> [--help]
#   <project-name> is the bare name under projects/ (data/projects.md registry
#   name), e.g. "storycraftai" for projects/storycraftai.
# Reads the declared source at config/project-env/<project-name>.env and
# merges any keys a worktree is missing into that worktree's .env, one line
# per pool slot: "slot <path>: <status>[ (<detail>)]". Never prints a key name
# or value - only status words and bare counts.
# A slot whose repository does not gitignore .env is skipped, never written:
# that is the precondition the PRIME-DIRECTIVE-1 exception rests on.
# No declared source is not an error: prints one line and exits 0, so a
# project that genuinely needs no shared local environment stays quiet.
# Exits non-zero only when a real propagation error occurred for some slot.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-project-env-lib.sh
. "$SCRIPT_DIR/fm-project-env-lib.sh"

NAME=${1:-}
[ -n "$NAME" ] || { echo "usage: fm-project-env-sync.sh <project-name>" >&2; exit 2; }
case "$NAME" in
  */*|.|..) echo "error: invalid project name: $NAME" >&2; exit 2 ;;
esac

PROJ_DIR="$PROJECTS/$NAME"
[ -d "$PROJ_DIR" ] || { echo "error: no project directory at $PROJ_DIR" >&2; exit 1; }

SRC=$(fm_project_env_source_path "$CONFIG" "$NAME") || {
  echo "error: could not resolve declared source path for $NAME" >&2
  exit 1
}
if [ ! -f "$SRC" ]; then
  echo "project-env-sync: $NAME: no declared source at $SRC; nothing to converge"
  exit 0
fi

POOL=$(fm_project_env_pool_worktrees "$PROJ_DIR") || {
  echo "project-env-sync: $NAME: no treehouse pool found for $PROJ_DIR"
  exit 0
}
if [ -z "$POOL" ]; then
  echo "project-env-sync: $NAME: treehouse pool is empty for $PROJ_DIR"
  exit 0
fi

echo "project-env-sync: $NAME: converging from $SRC"
errors=0
while IFS= read -r slot; do
  [ -n "$slot" ] || continue
  if ! fm_project_env_dest_gitignored "$slot/.env"; then
    printf '  slot %s: skipped (.env is not gitignored by this project)\n' "$slot"
    continue
  fi
  if fm_project_env_sync_file "$SRC" "$slot/.env"; then
    case "$FM_PROJECT_ENV_STATUS" in
      merged) printf '  slot %s: merged (%s key(s) added)\n' "$slot" "$FM_PROJECT_ENV_DETAIL" ;;
      *) printf '  slot %s: %s\n' "$slot" "$FM_PROJECT_ENV_STATUS" ;;
    esac
  else
    printf '  slot %s: error (%s)\n' "$slot" "${FM_PROJECT_ENV_DETAIL:-unknown}"
    errors=1
  fi
done <<EOF
$POOL
EOF

[ "$errors" -eq 0 ] || exit 1
exit 0
