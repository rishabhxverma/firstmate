#!/usr/bin/env bash
# Behavior tests for bin/fm-project-env-sync.sh: the one-command repair path
# that converges every existing treehouse pool worktree for a project onto its
# declared local-environment source (config/project-env/<name>.env), so a
# pool that already drifted (AGENTS.md worked example: some slots have a
# secret, others don't) can be repaired instead of left as a landmine.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-project-env-sync)
SYNC="$ROOT/bin/fm-project-env-sync.sh"
SECRET_VALUE="sk-super-secret-do-not-print-9876543210"

# make_fake_treehouse <dir> <status-file>: a treehouse stub whose `status`
# subcommand prints the given status file's content, exactly like the real
# CLI's pool listing (slot number, state, absolute path).
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
  mkdir -p "$home/config" "$home/projects/proj"
  git -C "$home/projects/proj" init -q
  printf '%s\n' "$home"
}

test_no_declared_source_is_a_clean_noop() {
  local home fakebin out rc
  home=$(new_world no-source)
  fakebin=$(make_fake_treehouse "$TMP_ROOT/no-source")

  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    "$SYNC" proj 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "no declared source should exit 0, got $rc: $out"
  assert_contains "$out" "no declared source" "should report the missing declared source plainly"
  pass "a project with no declared source is a clean no-op"
}

test_converges_seeded_and_merged_slots_without_clobbering_extra_content() {
  local home fakebin slot_fresh slot_partial slot_extra status_file out rc
  home=$(new_world converge)
  mkdir -p "$home/config/project-env"
  printf 'ANTHROPIC_API_KEY=%s\nCURSEFORGE_API_KEY=cf-declared\n' "$SECRET_VALUE" \
    > "$home/config/project-env/proj.env"

  slot_fresh="$TMP_ROOT/converge/slot-fresh"
  slot_partial="$TMP_ROOT/converge/slot-partial"
  slot_extra="$TMP_ROOT/converge/slot-extra"
  mkdir -p "$slot_fresh" "$slot_partial" "$slot_extra"
  printf 'CURSEFORGE_API_KEY=cf-local-override\n' > "$slot_partial/.env"
  printf 'ANTHROPIC_API_KEY=%s\nCURSEFORGE_API_KEY=cf-declared\nEXTRA_LOCAL_TOOL_TOKEN=keep-me\n' "$SECRET_VALUE" \
    > "$slot_extra/.env"

  status_file="$TMP_ROOT/converge/status.txt"
  {
    printf '1     in-use       %s\n' "$slot_fresh"
    printf '2     available    %s\n' "$slot_partial"
    printf '3     available    %s\n' "$slot_extra"
  } > "$status_file"

  fakebin=$(make_fake_treehouse "$TMP_ROOT/converge")
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_TREEHOUSE_STATUS="$status_file" \
    "$SYNC" proj 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "converging three slots should exit 0, got $rc: $out"
  assert_not_contains "$out" "$SECRET_VALUE" "sync output must never contain a secret value"

  cmp -s "$home/config/project-env/proj.env" "$slot_fresh/.env" \
    || fail "the previously bare slot should be seeded with the full declared source"

  assert_grep "CURSEFORGE_API_KEY=cf-local-override" "$slot_partial/.env" \
    "a slot's own pre-existing key must survive convergence unchanged"
  assert_grep "ANTHROPIC_API_KEY=$SECRET_VALUE" "$slot_partial/.env" \
    "the partially-seeded slot should gain the key it was missing"

  assert_grep "EXTRA_LOCAL_TOOL_TOKEN=keep-me" "$slot_extra/.env" \
    "content unique to a slot (declared nowhere) must never be dropped by convergence"

  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_TREEHOUSE_STATUS="$status_file" \
    "$SYNC" proj 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "re-running convergence on an already-converged pool should exit 0, got $rc: $out"
  assert_contains "$out" "unchanged" "re-running on a converged pool should report unchanged slots"
  assert_not_contains "$out" "merged" "a second run must not re-merge already-converged slots"

  pass "convergence seeds bare slots, merges missing keys into partial slots, and never clobbers slot-local content; idempotent on re-run"
}

test_no_declared_source_is_a_clean_noop
test_converges_seeded_and_merged_slots_without_clobbering_extra_content

echo "# all fm-project-env-sync tests passed"
