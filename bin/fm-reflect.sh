#!/usr/bin/env bash
# fm-reflect.sh - harvest one task's reflection material before cleanup destroys it.
#
# Reflection used to depend on someone remembering to run it, and it was most
# likely to be skipped exactly when it was most valuable: cleanup removes the
# task's event log, its metadata, and the isolated copy holding the branch
# history, which together are the raw material reflection reads. This script is
# the automatic harvest. bin/fm-teardown.sh calls it once every landed-work and
# discard-work refusal has already passed and before the first destructive step,
# so the material is captured while it still exists.
#
# Usage: fm-reflect.sh <task-id>
#
# What it does, in order:
#   1. Reads the task's durable records: state/<id>.meta, state/<id>.status, and
#      - READ-ONLY - the branch history and change size of the recorded worktree.
#   2. Publishes them atomically to data/<id>/reflection.md.
#   3. Queues ONE `check` wake naming that file, so firstmate folds the durable
#      operational facts into data/learnings.md per AGENTS.md section 6's
#      knowledge routing. The .agents/skills/task-reflection skill owns that
#      fold-in procedure.
#
# Safety contract - why this cannot endanger unlanded work:
#   - It NEVER writes inside the worktree. Every worktree access is a read
#     (`git log`, `git diff --shortstat`, `git status`), so it cannot dirty a
#     worktree whose landed-work check has already passed, and cannot make
#     teardown discard anything. The captured output goes to data/<id>/, which
#     cleanup does not remove.
#   - It is best effort. bin/fm-teardown.sh runs it bounded and ignores its exit
#     status; a failure, a missing tool, or a hang leaves teardown unchanged.
#   - The wake is queued LAST, only after the atomic publish succeeded, so a
#     queued wake never points at a missing or half-written file. A capture
#     killed mid-write leaves the previous complete reflection.md (or none) plus
#     an orphaned temp file that the next capture overwrites - never a partial
#     record and never a dangling wake.
#
# Precondition: data/<id>/ must already exist. bin/fm-brief.sh creates it for
# every real task (it holds brief.md), so an absent directory means there is no
# task record to annotate; the capture is then a silent no-op. That keeps the
# capture inert for callers - including tests - that never staged a task record.
#
# Skipped by bin/fm-teardown.sh for kind=secondmate: a secondmate is a
# persistent home, not a work item with a task worktree to reflect on.
#
# Environment:
#   FM_REFLECT_EVENT_LINES   last N event-log lines to capture (default 200)
#   FM_REFLECT_COMMITS       last N branch commits to capture (default 100)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
EVENT_LINES=${FM_REFLECT_EVENT_LINES:-200}
COMMITS=${FM_REFLECT_COMMITS:-100}
# A malformed cap must not turn the harvest into an arithmetic error, because the
# capture is the last chance to read these records before they are destroyed.
case "$EVENT_LINES" in ''|0|*[!0-9]*) EVENT_LINES=200 ;; esac
case "$COMMITS" in ''|0|*[!0-9]*) COMMITS=100 ;; esac

# Every git command below must be a pure read of a worktree whose landed-work and
# dirty verdicts teardown has ALREADY decided. Read-only intent is not enough on
# its own: `status` and `diff` may refresh the index's stat cache and rewrite
# .git/index as a side effect, and a worktree written between those verdicts and
# the destruction they authorize is exactly what must not happen here.
# GIT_OPTIONAL_LOCKS=0 is git's own switch for suppressing that optional refresh,
# so the capture cannot take the index lock or rewrite the index no matter which
# read it performs. tests/fm-reflect.test.sh pins the worktree as untouched.
export GIT_OPTIONAL_LOCKS=0

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -lt 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: invalid reflection request" >&2
  exit 2
fi
ID=$1
TASK_DATA="$DATA/$ID"
META="$STATE/$ID.meta"
STATUS="$STATE/$ID.status"
OUT="$TASK_DATA/reflection.md"
TMP="$TASK_DATA/.reflection.md.tmp"

# No task record to annotate: nothing to capture, and nothing to report.
[ -d "$TASK_DATA" ] || exit 0

WT=
if [ -f "$META" ]; then
  WT=$(fm_meta_get "$META" worktree)
fi

# Print the task's recorded identity. Absent metadata is normal on a rerun after
# cleanup already removed it, so it degrades to a stated absence, not an error.
emit_task_record() {
  local key value
  printf '## Task record\n\n'
  if [ ! -f "$META" ]; then
    printf 'No task metadata remained at capture time (%s).\n' "$META"
    return 0
  fi
  for key in project kind mode yolo harness model effort backend pr; do
    value=$(fm_meta_get "$META" "$key")
    [ -n "$value" ] && printf -- '- %s: %s\n' "$key" "$value"
  done
  return 0
}

# The event log is the richest signal about how the task actually went - where it
# stalled, what it escalated, how often it was steered - and cleanup removes it.
emit_event_log() {
  local total
  printf '## Event log\n\n'
  if [ ! -f "$STATUS" ]; then
    printf 'No event log remained at capture time (%s).\n' "$STATUS"
    return 0
  fi
  total=$(wc -l < "$STATUS" | tr -d ' ')
  printf 'From %s, removed by cleanup. %s line(s) recorded' "$STATUS" "$total"
  if [ "$total" -gt "$EVENT_LINES" ]; then
    printf ', last %s shown' "$EVENT_LINES"
  fi
  printf '.\n\n```\n'
  tail -n "$EVENT_LINES" "$STATUS"
  printf '```\n'
  return 0
}

# Branch history and change size go away with the isolated copy. Every command
# here reads; none of them can modify the worktree or its index.
# shellcheck disable=SC2016 # Backticks are literal Markdown code ticks in the captured report, not expansions.
emit_branch_history() {
  local branch base
  printf '## Branch history\n\n'
  if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    printf 'No isolated copy remained at capture time (%s).\n' "${WT:-<unrecorded>}"
    return 0
  fi
  if ! branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null); then
    printf 'The isolated copy at %s was not a readable git worktree.\n' "$WT"
    return 0
  fi
  printf 'Branch `%s` in %s, removed by cleanup.\n\n' "$branch" "$WT"
  printf '```\n'
  git -C "$WT" log --oneline --no-decorate -n "$COMMITS" 2>/dev/null || true
  printf '```\n\n'
  base=$(git -C "$WT" rev-parse --verify --quiet HEAD 2>/dev/null) || base=
  if [ -n "$base" ]; then
    printf 'Change size against the merge base with the default branch:\n\n```\n'
    git -C "$WT" diff --shortstat "$(default_branch_merge_base "$WT")...HEAD" 2>/dev/null || true
    printf '```\n\n'
  fi
  printf 'Uncommitted at capture time:\n\n```\n'
  git -C "$WT" status --porcelain 2>/dev/null || true
  printf '```\n'
  return 0
}

# Best-effort merge base against whichever default-branch ref this worktree can
# see. An unresolvable base prints nothing and the diff above degrades to empty.
default_branch_merge_base() {  # <worktree>
  local wt=$1 ref
  for ref in origin/HEAD origin/main origin/master main master; do
    if git -C "$wt" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
      git -C "$wt" merge-base "$ref" HEAD 2>/dev/null && return 0
    fi
  done
  printf 'HEAD\n'
  return 0
}

# shellcheck disable=SC2016 # Backticks are literal Markdown code ticks in the captured report, not expansions.
{
  printf '# Reflection material: %s\n\n' "$ID"
  printf 'Captured %s by bin/fm-reflect.sh, immediately before cleanup removed\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'this task'"'"'s volatile records and isolated copy.\n\n'
  printf 'Fold the durable operational facts into `data/learnings.md`, then delete\n'
  printf 'this file. The `task-reflection` skill owns that procedure.\n\n'
  emit_task_record
  printf '\n'
  printf '## Instructions given\n\n'
  if [ -f "$TASK_DATA/brief.md" ]; then
    printf 'See `%s/brief.md` (kept by cleanup).\n' "$TASK_DATA"
  else
    printf 'No brief remained at capture time.\n'
  fi
  printf '\n'
  emit_event_log
  printf '\n'
  emit_branch_history
} > "$TMP"

mv -f "$TMP" "$OUT"

# Queued last, and only after the atomic publish above: a wake never names a
# file that is missing or half-written.
fm_wake_append check "reflection:$ID" \
  "check: reflection: material captured for task $ID; fold it into data/learnings.md from $OUT"
