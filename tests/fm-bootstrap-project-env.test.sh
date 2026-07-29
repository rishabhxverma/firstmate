#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh's PROJECT_ENV detection line: a read-only
# scan (bin/fm-project-env-lib.sh) that reports when a treehouse pool has
# drifted from its declared per-project local-environment source, or when
# pool worktrees already carry local .env content but no source is declared -
# the exact drift observed live in the storycraftai pool (AGENTS.md's worked
# example). Detect-only: never writes anything, and never prints a secret.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-project-env)
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
SECRET_VALUE="sk-super-secret-do-not-print-5566778899"

make_fake_treehouse() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  status)
    [ -n "${FM_FAKE_TREEHOUSE_STATUS:-}" ] && [ -f "$FM_FAKE_TREEHOUSE_STATUS" ] && cat "$FM_FAKE_TREEHOUSE_STATUS"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

new_world() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/config" "$home/projects/proj" "$home/state" "$home/data"
  git -C "$home/projects/proj" init -q
  printf '%s\n' "$home"
}

run_bootstrap() {
  local home=$1 fakebin=$2 status_file=$3
  PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_STATUS="$status_file" \
    "$BOOTSTRAP" 2>&1
}

test_drifted_pool_is_reported_and_secret_is_never_printed() {
  local home fakebin slot1 slot2 status_file out
  home=$(new_world drift)
  fakebin=$(make_fake_treehouse "$TMP_ROOT/drift")
  mkdir -p "$home/config/project-env"
  printf 'ANTHROPIC_API_KEY=%s\n' "$SECRET_VALUE" > "$home/config/project-env/proj.env"

  slot1="$TMP_ROOT/drift/slot1"
  slot2="$TMP_ROOT/drift/slot2"
  mkdir -p "$slot1" "$slot2"
  printf 'CURSEFORGE_API_KEY=cf-only\n' > "$slot1/.env"
  printf 'ANTHROPIC_API_KEY=%s\n' "$SECRET_VALUE" > "$slot2/.env"

  status_file="$TMP_ROOT/drift/status.txt"
  {
    printf '1     in-use       %s\n' "$slot1"
    printf '2     available    %s\n' "$slot2"
  } > "$status_file"

  out=$(run_bootstrap "$home" "$fakebin" "$status_file")

  assert_contains "$out" "PROJECT_ENV: project proj: 1 of 2 pool worktree(s) are missing keys the declared source has" \
    "bootstrap should report exactly the one drifted slot"
  assert_contains "$out" "bin/fm-project-env-sync.sh proj" \
    "the diagnostic should point at the exact repair command"
  assert_not_contains "$out" "$SECRET_VALUE" "bootstrap must never print a secret value"
  pass "a drifted pool is reported with a precise slot count and no secret leakage"
}

test_missing_declared_source_with_existing_content_is_reported() {
  local home fakebin slot1 status_file out
  home=$(new_world missing-source)
  fakebin=$(make_fake_treehouse "$TMP_ROOT/missing-source")
  # No config/project-env/proj.env declared at all.

  slot1="$TMP_ROOT/missing-source/slot1"
  mkdir -p "$slot1"
  printf 'ANTHROPIC_API_KEY=%s\n' "$SECRET_VALUE" > "$slot1/.env"

  status_file="$TMP_ROOT/missing-source/status.txt"
  printf '1     in-use       %s\n' "$slot1" > "$status_file"

  out=$(run_bootstrap "$home" "$fakebin" "$status_file")

  assert_contains "$out" "PROJECT_ENV: project proj: pool worktrees carry local .env content but no declared source" \
    "bootstrap should flag undeclared-but-present local env content"
  assert_not_contains "$out" "$SECRET_VALUE" "bootstrap must never print a secret value"
  pass "a pool with local .env content but no declared source is reported"
}

test_fully_converged_pool_is_silent() {
  local home fakebin slot1 slot2 status_file out
  home=$(new_world converged)
  fakebin=$(make_fake_treehouse "$TMP_ROOT/converged")
  mkdir -p "$home/config/project-env"
  printf 'ANTHROPIC_API_KEY=%s\n' "$SECRET_VALUE" > "$home/config/project-env/proj.env"

  slot1="$TMP_ROOT/converged/slot1"
  slot2="$TMP_ROOT/converged/slot2"
  mkdir -p "$slot1" "$slot2"
  printf 'ANTHROPIC_API_KEY=%s\n' "$SECRET_VALUE" > "$slot1/.env"
  printf 'ANTHROPIC_API_KEY=%s\nEXTRA=kept\n' "$SECRET_VALUE" > "$slot2/.env"

  status_file="$TMP_ROOT/converged/status.txt"
  {
    printf '1     in-use       %s\n' "$slot1"
    printf '2     available    %s\n' "$slot2"
  } > "$status_file"

  out=$(run_bootstrap "$home" "$fakebin" "$status_file")

  assert_not_contains "$out" "PROJECT_ENV" "a fully converged pool must stay silent"
  pass "a fully converged pool prints no PROJECT_ENV diagnostic"
}

test_drifted_pool_is_reported_and_secret_is_never_printed
test_missing_declared_source_with_existing_content_is_reported
test_fully_converged_pool_is_silent

echo "# all fm-bootstrap-project-env tests passed"
