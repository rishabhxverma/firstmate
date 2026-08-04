#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's declared per-project local-environment
# convergence (bin/fm-project-env-lib.sh): a ship/scout spawn seeds or merges
# the worktree's .env from config/project-env/<project>.env, so a spawned
# crewmate never lands in a worktree missing a credential that other pool
# slots happen to have.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-project-env)
SECRET_VALUE="sk-super-secret-do-not-print-1122334455"
# A ship spawn carries an explicit delivery contract (bin/fm-spawn.sh's --mode /
# --yolo); the env propagation under test is independent of which contract it is,
# so these cases use the standing default and record the same mode in the brief.
SPAWN_MODE=no-mistakes

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# make_fakebin <dir>: a tmux stub whose pane_current_path immediately reports
# the target worktree (no staleness to simulate here - that is covered by
# fm-spawn-worktree-settle.test.sh), plus a harmless treehouse stub for
# anything that probes it directly.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> [no-ignore]: a home with a declared project-env source
# for "demoproj", a real primary checkout, and a real git worktree standing in
# for a treehouse pool slot that has already settled at spawn time. The
# worktree gitignores .env the way a real project does, which is the
# precondition the propagation requires; pass "no-ignore" to omit it.
make_case() {
  local name=$1 id=$2 ignore=${3:-ignore} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/demoproj"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config/project-env"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'ANTHROPIC_API_KEY=%s\nCURSEFORGE_API_KEY=cf-declared\n' "$SECRET_VALUE" \
    > "$home/config/project-env/demoproj.env"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  [ "$ignore" = ignore ] && printf '.env\n' > "$wt/.gitignore"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n\n# Definition of done\nDelivery contract: mode=%s\n' \
    "$id" "$SPAWN_MODE" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

run_spawn() {
  local id=$1 home=$2 proj=$3 wt=$4 fakebin=$5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode "$SPAWN_MODE" --yolo off 2>&1
}

test_fresh_worktree_gets_the_declared_env_at_spawn_time() {
  local rec case_dir home proj wt fakebin id out
  id=penv-fresh-z1
  rec=$(make_case fresh "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF

  out=$(run_spawn "$id" "$home" "$proj" "$wt" "$fakebin")
  expect_code 0 "$?" "spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success: $out"
  assert_contains "$out" "project-env: seeded" "spawn should report seeding the fresh worktree's env"
  assert_not_contains "$out" "$SECRET_VALUE" "spawn output must never contain a secret value"
  cmp -s "$home/config/project-env/demoproj.env" "$wt/.env" \
    || fail "fresh worktree's .env should exactly match the declared source"
  [ "$(file_mode "$wt/.env")" = 600 ] || fail "seeded .env should be mode 600, got $(file_mode "$wt/.env")"
  pass "a fresh crewmate worktree is seeded with the declared per-project env at spawn time"
}

test_reused_worktree_with_local_content_is_merged_not_clobbered() {
  local rec case_dir home proj wt fakebin id out
  id=penv-reuse-z2
  rec=$(make_case reuse "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  # Simulate a reused pool slot: it already carries a local override for one
  # declared key plus a key the declared source knows nothing about.
  printf 'CURSEFORGE_API_KEY=cf-local-override\nEXTRA_LOCAL_TOOL_TOKEN=keep-me\n' > "$wt/.env"

  out=$(run_spawn "$id" "$home" "$proj" "$wt" "$fakebin")
  expect_code 0 "$?" "spawn should succeed"
  assert_contains "$out" "project-env: merged" "spawn should report merging the missing key"
  assert_not_contains "$out" "$SECRET_VALUE" "spawn output must never contain a secret value"

  assert_grep "CURSEFORGE_API_KEY=cf-local-override" "$wt/.env" \
    "a pre-existing worktree key must survive convergence unchanged"
  assert_grep "EXTRA_LOCAL_TOOL_TOKEN=keep-me" "$wt/.env" \
    "worktree-local content the declared source does not know about must never be dropped"
  assert_grep "ANTHROPIC_API_KEY=$SECRET_VALUE" "$wt/.env" \
    "the worktree should gain the declared key it was missing"
  [ "$(file_mode "$wt/.env")" = 600 ] || fail "merged .env should be mode 600, got $(file_mode "$wt/.env")"

  # Re-spawn into the same slot (pool reuse): must be idempotent - no
  # duplicate keys, no further prompted merge.
  out=$(run_spawn "$id" "$home" "$proj" "$wt" "$fakebin")
  expect_code 0 "$?" "respawn into the same slot should succeed"
  assert_not_contains "$out" "project-env: merged" "respawn on an already-converged slot should not report another merge"
  [ "$(grep -c '^ANTHROPIC_API_KEY=' "$wt/.env")" = 1 ] \
    || fail "respawn must not duplicate a key that was already converged"

  pass "a reused worktree's local content is merged with, never clobbered by, the declared per-project env"
}

test_worktree_that_does_not_gitignore_env_is_skipped() {
  local rec case_dir home proj wt fakebin id out
  id=penv-unignored-z3
  rec=$(make_case unignored "$id" no-ignore)
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF

  out=$(run_spawn "$id" "$home" "$proj" "$wt" "$fakebin")
  expect_code 0 "$?" "spawn should still succeed when the env propagation is skipped"
  assert_contains "$out" "does not gitignore .env" "spawn should say why the propagation was skipped"
  assert_not_contains "$out" "project-env: seeded" "a non-ignoring worktree must not be seeded"
  assert_not_contains "$out" "$SECRET_VALUE" "the skip warning must never contain a secret value"
  assert_absent "$wt/.env" "a credential must never be written where git would let a crewmate commit it"
  pass "a worktree whose project does not gitignore .env is skipped, and the spawn itself still succeeds"
}

test_fresh_worktree_gets_the_declared_env_at_spawn_time
test_reused_worktree_with_local_content_is_merged_not_clobbered
test_worktree_that_does_not_gitignore_env_is_skipped

echo "# all fm-spawn-project-env tests passed"
