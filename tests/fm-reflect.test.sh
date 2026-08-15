#!/usr/bin/env bash
# Tests for bin/fm-reflect.sh, the automatic reflection harvest that
# bin/fm-teardown.sh runs before cleanup destroys a task's records.
#
# The script exists so reflection stops depending on someone remembering it, and
# its whole value depends on two properties holding together: it must capture the
# material that cleanup is about to erase, and it must be incapable of putting
# unlanded work at risk while doing so. These cases pin both.
#
#   (a) capture writes the event log, task record, and branch history durably
#   (b) capture queues exactly one wake naming the published file
#   (c) capture NEVER writes inside the worktree (the unlanded-work guarantee)
#   (d) absent data/<id>/ is a silent no-op with no wake
#   (e) absent metadata, event log, and worktree degrade to stated absences
#   (f) a failed publish queues NO wake (no wake ever names a missing file)
#   (g) a path-unsafe task id is refused before anything is written
#   (h) a rerun republishes and leaves no stray temp file
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REFLECT="$ROOT/bin/fm-reflect.sh"
TMP_ROOT=$(fm_test_tmproot fm-reflect-tests)

# Build a sandbox holding a task's durable records plus a git worktree standing in
# for the isolated copy. Echoes the case dir.
make_case() {  # <name>
  local name=$1 case_dir=
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data/task-r1"

  git init -q "$case_dir/wt"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "baseline"
  git -C "$case_dir/wt" checkout -q -b fm/task-r1
  printf 'shipped\n' > "$case_dir/wt/shipped.txt"
  git -C "$case_dir/wt" add -- shipped.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "add shipped"

  fm_write_meta "$case_dir/state/task-r1.meta" \
    "window=firstmate:fm-task-r1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "harness=claude" \
    "model=opus"
  printf 'working: setup done\nblocked: needed a credential\ndone: PR up\n' \
    > "$case_dir/state/task-r1.status"
  printf 'the brief\n' > "$case_dir/data/task-r1/brief.md"

  printf '%s\n' "$case_dir"
}

run_reflect() {  # <case-dir> [task-id]
  local case_dir=$1 id=${2:-task-r1}
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
    "$REFLECT" "$id"
}

# Snapshot every path under a directory with its size and mtime, so a later
# comparison catches a created, deleted, or rewritten file.
snapshot_tree() {  # <dir>
  find "$1" -exec stat -f '%N %z %m' {} + 2>/dev/null \
    || find "$1" -exec stat -c '%n %s %Y' {} + 2>/dev/null
}

wake_lines() {  # <case-dir>
  cat "$1/state/.wake-queue" 2>/dev/null || true
}

test_capture_publishes_the_material_cleanup_destroys() {
  local case_dir out
  case_dir=$(make_case publishes)

  run_reflect "$case_dir" || fail "publishes: capture exited non-zero"

  out="$case_dir/data/task-r1/reflection.md"
  [ -f "$out" ] || fail "publishes: no reflection.md was published"
  # The event log and branch history are exactly what teardown erases next.
  assert_grep 'blocked: needed a credential' "$out" \
    "publishes: the event log cleanup removes was not captured"
  assert_grep 'add shipped' "$out" \
    "publishes: the branch history the isolated copy holds was not captured"
  assert_grep 'kind: ship' "$out" "publishes: the task record was not captured"
  assert_grep 'mode: no-mistakes' "$out" "publishes: the delivery mode was not captured"
  assert_grep 'brief.md' "$out" "publishes: the instructions pointer was not captured"
  pass "capture publishes the event log, task record, and branch history durably"
}

test_capture_queues_one_wake_naming_the_published_file() {
  local case_dir queue count
  case_dir=$(make_case one-wake)

  run_reflect "$case_dir" || fail "one-wake: capture exited non-zero"

  queue=$(wake_lines "$case_dir")
  count=$(printf '%s\n' "$queue" | grep -c 'reflection:task-r1' || true)
  [ "$count" = 1 ] || fail "one-wake: expected exactly 1 reflection wake, got $count"
  assert_contains "$queue" "$case_dir/data/task-r1/reflection.md" \
    "one-wake: the wake did not name the published file"
  assert_contains "$queue" "data/learnings.md" \
    "one-wake: the wake did not route the fold-in to the learnings file"
  pass "capture queues exactly one wake naming the published file"
}

# The load-bearing safety property: teardown has already cleared its landed-work
# and dirty checks by the time the capture runs, so a capture that wrote into the
# worktree would make those verdicts stale on work about to be destroyed.
test_capture_never_writes_inside_the_worktree() {
  local case_dir before after control status_before
  case_dir=$(make_case read-only)
  printf 'unstaged\n' > "$case_dir/wt/scratch.txt"

  # Run every bit of instrumentation BEFORE the baseline snapshot. `git status`
  # can itself refresh a racily-clean index and rewrite .git/index, so an
  # instrumentation call placed between the two snapshots would be recorded as a
  # write by the capture that never made it.
  status_before=$(git -C "$case_dir/wt" status --porcelain)
  assert_contains "$status_before" "scratch.txt" \
    "read-only: fixture did not actually leave the worktree dirty"

  before=$(snapshot_tree "$case_dir/wt")
  run_reflect "$case_dir" || fail "read-only: capture exited non-zero"
  after=$(snapshot_tree "$case_dir/wt")

  [ "$before" = "$after" ] || fail \
    "read-only: the capture changed the worktree"$'\n'"--- diff ---"$'\n'"$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"

  # Control: prove the comparison can actually see a write, so a passing verdict
  # above is evidence and not an artifact of a blind snapshot.
  printf 'more\n' >> "$case_dir/wt/scratch.txt"
  control=$(snapshot_tree "$case_dir/wt")
  [ "$control" != "$before" ] || fail \
    "read-only: the snapshot cannot detect a worktree write, so the case is vacuous"
  pass "capture never writes inside the worktree it reads"
}

test_absent_task_data_dir_is_a_silent_noop() {
  local case_dir rc=0 output
  case_dir=$(make_case no-data-dir)
  rm -rf "$case_dir/data/task-r1"

  set +e
  output=$(run_reflect "$case_dir" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "no-data-dir: capture should succeed silently"
  [ -z "$output" ] || fail "no-data-dir: capture printed output: $output"
  assert_absent "$case_dir/data/task-r1" "no-data-dir: capture created a task data dir"
  [ -z "$(wake_lines "$case_dir")" ] || fail "no-data-dir: capture queued a wake"
  pass "an absent task data dir makes the capture a silent no-op with no wake"
}

test_missing_records_degrade_to_stated_absences() {
  local case_dir out
  case_dir=$(make_case degraded)
  rm -f "$case_dir/state/task-r1.meta" "$case_dir/state/task-r1.status"
  rm -rf "$case_dir/wt" "$case_dir/data/task-r1/brief.md"

  run_reflect "$case_dir" || fail "degraded: capture exited non-zero with no records left"

  out="$case_dir/data/task-r1/reflection.md"
  assert_grep 'No task metadata remained' "$out" "degraded: missing metadata not stated"
  assert_grep 'No event log remained' "$out" "degraded: missing event log not stated"
  assert_grep 'No isolated copy remained' "$out" "degraded: missing isolated copy not stated"
  assert_grep 'No brief remained' "$out" "degraded: missing instructions not stated"
  assert_contains "$(wake_lines "$case_dir")" 'reflection:task-r1' \
    "degraded: no wake was queued for the partial capture"
  pass "missing records degrade to stated absences instead of failing the capture"
}

# The wake is queued only after the atomic publish, so a wake can never name a
# file that was never written.
test_failed_publish_queues_no_wake() {
  local case_dir rc=0
  case_dir=$(make_case publish-fails)
  chmod 500 "$case_dir/data/task-r1"

  set +e
  run_reflect "$case_dir" >/dev/null 2>&1
  rc=$?
  set -e
  chmod 700 "$case_dir/data/task-r1"

  [ "$rc" -ne 0 ] || fail "publish-fails: capture reported success with an unwritable data dir"
  assert_absent "$case_dir/data/task-r1/reflection.md" \
    "publish-fails: a reflection file appeared despite the failed publish"
  [ -z "$(wake_lines "$case_dir")" ] || fail \
    "publish-fails: a wake was queued for a file that was never published"
  pass "a failed publish queues no wake, so no wake names a missing file"
}

test_path_unsafe_task_id_is_refused() {
  local case_dir rc=0 err
  case_dir=$(make_case unsafe-id)

  set +e
  err=$(run_reflect "$case_dir" '../escape' 2>&1)
  rc=$?
  set -e

  expect_code 2 "$rc" "unsafe-id: a traversing task id should be refused"
  assert_contains "$err" "invalid reflection request" "unsafe-id: no refusal reason printed"
  pass "a path-unsafe task id is refused before anything is written"
}

test_rerun_republishes_and_leaves_no_temp_file() {
  local case_dir out first
  case_dir=$(make_case rerun)

  run_reflect "$case_dir" || fail "rerun: first capture exited non-zero"
  out="$case_dir/data/task-r1/reflection.md"
  first=$(cat "$out")
  printf 'done: second pass\n' >> "$case_dir/state/task-r1.status"

  run_reflect "$case_dir" || fail "rerun: second capture exited non-zero"

  assert_grep 'done: second pass' "$out" "rerun: the republished capture is stale"
  [ "$first" != "$(cat "$out")" ] || fail "rerun: the capture was not republished"
  assert_absent "$case_dir/data/task-r1/.reflection.md.tmp" \
    "rerun: a temp file was left behind"
  pass "a rerun republishes the capture and leaves no temp file"
}

test_capture_publishes_the_material_cleanup_destroys
test_capture_queues_one_wake_naming_the_published_file
test_capture_never_writes_inside_the_worktree
test_absent_task_data_dir_is_a_silent_noop
test_missing_records_degrade_to_stated_absences
test_failed_publish_queues_no_wake
test_path_unsafe_task_id_is_refused
test_rerun_republishes_and_leaves_no_temp_file
