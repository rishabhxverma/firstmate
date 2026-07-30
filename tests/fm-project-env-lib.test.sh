#!/usr/bin/env bash
# Behavior tests for bin/fm-project-env-lib.sh: the merge-or-refuse core that
# converges a worktree's .env from a project's declared local-environment
# source (config/project-env/<name>.env) without ever clobbering content the
# worktree already has.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-project-env-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-env-lib)

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

SECRET_VALUE="sk-super-secret-do-not-print-1234567890"

test_fresh_worktree_is_seeded_with_full_source() {
  local dir src dest out_file out
  dir="$TMP_ROOT/fresh"
  mkdir -p "$dir"
  src="$dir/source.env"
  dest="$dir/worktree/.env"
  out_file="$dir/out.log"
  printf 'ANTHROPIC_API_KEY=%s\nCURSEFORGE_API_KEY=cf-1\n' "$SECRET_VALUE" > "$src"

  fm_project_env_sync_file "$src" "$dest" > "$out_file" 2>&1

  [ "$FM_PROJECT_ENV_STATUS" = seeded ] || fail "fresh worktree should be seeded, got '$FM_PROJECT_ENV_STATUS'"
  cmp -s "$src" "$dest" || fail "seeded destination should be a byte-identical copy of the declared source"
  [ "$(file_mode "$dest")" = 600 ] || fail "seeded destination should be mode 600, got $(file_mode "$dest")"
  out=$(cat "$out_file")
  assert_not_contains "$out" "$SECRET_VALUE" "seeding must never echo the secret value to stdout/stderr"
  pass "a fresh worktree is seeded with a full copy of the declared source, mode 0600"
}

test_existing_worktree_gains_missing_key_without_losing_its_own() {
  local dir src dest out_file out
  dir="$TMP_ROOT/merge"
  mkdir -p "$dir/worktree"
  src="$dir/source.env"
  dest="$dir/worktree/.env"
  out_file="$dir/out.log"
  printf 'ANTHROPIC_API_KEY=%s\nCURSEFORGE_API_KEY=cf-from-source\n' "$SECRET_VALUE" > "$src"
  printf 'CURSEFORGE_API_KEY=cf-local-override\n' > "$dest"

  fm_project_env_sync_file "$src" "$dest" > "$out_file" 2>&1

  [ "$FM_PROJECT_ENV_STATUS" = merged ] || fail "existing worktree missing a declared key should merge, got '$FM_PROJECT_ENV_STATUS'"
  [ "$FM_PROJECT_ENV_DETAIL" = 1 ] || fail "exactly one key (ANTHROPIC_API_KEY) should have been added, detail was '$FM_PROJECT_ENV_DETAIL'"
  assert_grep "CURSEFORGE_API_KEY=cf-local-override" "$dest" \
    "the worktree's own pre-existing key/value must never be overwritten by the declared source"
  assert_no_grep "cf-from-source" "$dest" \
    "the source's conflicting value for an already-present key must never be written"
  assert_grep "ANTHROPIC_API_KEY=$SECRET_VALUE" "$dest" \
    "the worktree should gain the key it was missing"
  [ "$(file_mode "$dest")" = 600 ] || fail "merged destination should be mode 600, got $(file_mode "$dest")"
  out=$(cat "$out_file")
  assert_not_contains "$out" "$SECRET_VALUE" "merging must never echo the secret value to stdout/stderr"
  pass "an existing worktree gains only the keys it was missing; its own content is never clobbered"
}

test_fully_converged_worktree_is_unchanged_and_idempotent() {
  local dir src dest before after
  dir="$TMP_ROOT/unchanged"
  mkdir -p "$dir/worktree"
  src="$dir/source.env"
  dest="$dir/worktree/.env"
  printf 'ANTHROPIC_API_KEY=%s\n' "$SECRET_VALUE" > "$src"
  printf 'ANTHROPIC_API_KEY=%s\nEXTRA_LOCAL_ONLY=kept\n' "$SECRET_VALUE" > "$dest"
  before=$(cat "$dest")

  fm_project_env_sync_file "$src" "$dest" >/dev/null 2>&1
  [ "$FM_PROJECT_ENV_STATUS" = unchanged ] || fail "a worktree with every declared key should report unchanged, got '$FM_PROJECT_ENV_STATUS'"
  after=$(cat "$dest")
  [ "$before" = "$after" ] || fail "unchanged convergence must not modify the destination at all"

  fm_project_env_sync_file "$src" "$dest" >/dev/null 2>&1
  [ "$FM_PROJECT_ENV_STATUS" = unchanged ] || fail "re-running sync on a converged worktree should stay unchanged (idempotent respawn)"
  after=$(cat "$dest")
  [ "$before" = "$after" ] || fail "a second run must not duplicate or alter any content"
  pass "a fully converged worktree is left untouched and repeated sync stays idempotent"
}

test_missing_declared_source_is_a_silent_noop() {
  local dir src dest
  dir="$TMP_ROOT/no-source"
  mkdir -p "$dir/worktree"
  src="$dir/source.env"
  dest="$dir/worktree/.env"
  printf 'LOCAL_ONLY=keep-me\n' > "$dest"

  fm_project_env_sync_file "$src" "$dest" >/dev/null 2>&1
  [ "$FM_PROJECT_ENV_STATUS" = no-source ] || fail "an absent declared source should report no-source, got '$FM_PROJECT_ENV_STATUS'"
  assert_grep "LOCAL_ONLY=keep-me" "$dest" "a missing declared source must never touch an existing destination"
  assert_absent "$src" "a missing declared source must never be created as a side effect"
  pass "a project with no declared source is a silent no-op, not an error"
}

test_symlink_destination_is_skipped_not_followed() {
  local dir src real_target dest
  dir="$TMP_ROOT/symlink"
  mkdir -p "$dir/worktree" "$dir/elsewhere"
  src="$dir/source.env"
  real_target="$dir/elsewhere/real.env"
  dest="$dir/worktree/.env"
  printf 'ANTHROPIC_API_KEY=%s\n' "$SECRET_VALUE" > "$src"
  printf 'UNRELATED=untouched\n' > "$real_target"
  ln -s "$real_target" "$dest"

  fm_project_env_sync_file "$src" "$dest" >/dev/null 2>&1
  [ "$FM_PROJECT_ENV_STATUS" = skipped ] || fail "a symlinked destination should be skipped, got '$FM_PROJECT_ENV_STATUS'"
  [ -L "$dest" ] || fail "the destination symlink itself must be left in place"
  assert_grep "UNRELATED=untouched" "$real_target" "a symlinked destination's target must never be written through"
  pass "a symlinked destination is skipped rather than followed or clobbered"
}

test_fm_project_env_source_path_rejects_unsafe_names() {
  fm_project_env_source_path "/tmp/config" "" >/dev/null 2>&1 \
    && fail "an empty project name should be rejected"
  fm_project_env_source_path "/tmp/config" "../escape" >/dev/null 2>&1 \
    && fail "a path-traversal project name should be rejected"
  fm_project_env_source_path "/tmp/config" "a/b" >/dev/null 2>&1 \
    && fail "a project name containing a slash should be rejected"
  [ "$(fm_project_env_source_path "/tmp/config" storycraftai)" = "/tmp/config/project-env/storycraftai.env" ] \
    || fail "a plain project name should resolve under config/project-env/<name>.env"
  pass "fm_project_env_source_path resolves plain names and rejects unsafe ones"
}

test_export_prefixed_destination_key_counts_as_present() {
  local dir src dest before after
  dir="$TMP_ROOT/export-prefix"
  mkdir -p "$dir/worktree"
  src="$dir/source.env"
  dest="$dir/worktree/.env"
  printf 'ANTHROPIC_API_KEY=%s\n' "$SECRET_VALUE" > "$src"
  printf 'export ANTHROPIC_API_KEY=rotated-in-this-worktree\n' > "$dest"
  before=$(cat "$dest")

  fm_project_env_sync_file "$src" "$dest" >/dev/null 2>&1
  [ "$FM_PROJECT_ENV_STATUS" = unchanged ] \
    || fail "an 'export KEY=' destination line should count as that key being present, got '$FM_PROJECT_ENV_STATUS'"
  after=$(cat "$dest")
  [ "$before" = "$after" ] || fail "a rotated 'export KEY=' value must not be shadowed by an appended source line"
  assert_no_grep "$SECRET_VALUE" "$dest" "the source value must never be appended behind an export-prefixed key"

  fm_project_env_sync_file "$src" "$dest" >/dev/null 2>&1
  [ "$(cat "$dest")" = "$before" ] || fail "re-running must not duplicate the export-prefixed key"
  pass "an 'export KEY=' (or indented) destination key is recognized as present, so it is never shadowed or duplicated"
}

test_multiline_source_value_is_appended_whole() {
  local dir src dest
  dir="$TMP_ROOT/multiline"
  mkdir -p "$dir/worktree"
  src="$dir/source.env"
  dest="$dir/worktree/.env"
  printf 'SERVICE_KEY="line-one\nline-two"\nPLAIN_KEY=plain\n' > "$src"
  printf 'PLAIN_KEY=already-here\n' > "$dest"

  fm_project_env_sync_file "$src" "$dest" >/dev/null 2>&1
  [ "$FM_PROJECT_ENV_STATUS" = merged ] || fail "a missing multiline key should merge, got '$FM_PROJECT_ENV_STATUS'"
  [ "$FM_PROJECT_ENV_DETAIL" = 1 ] || fail "a multiline value counts as one key, detail was '$FM_PROJECT_ENV_DETAIL'"
  assert_grep 'line-two"' "$dest" "the continuation line of a multiline value must be carried with its key"
  # shellcheck source=/dev/null
  ( set -a; . "$dest" ) >/dev/null 2>&1 \
    || fail "the merged destination must still be loadable, i.e. no unterminated quote was written"
  pass "a multiline declared value is appended with every continuation line, so the destination stays loadable"
}

test_unterminated_source_quote_is_refused_not_half_written() {
  local dir src dest before
  dir="$TMP_ROOT/unterminated"
  mkdir -p "$dir/worktree"
  src="$dir/source.env"
  dest="$dir/worktree/.env"
  printf 'GOOD_KEY=fine\nBROKEN_KEY="never-closed\n' > "$src"
  printf 'LOCAL_ONLY=keep-me\n' > "$dest"
  before=$(cat "$dest")

  fm_project_env_sync_file "$src" "$dest" >/dev/null 2>&1 \
    && fail "a source ending with an unterminated quote should be an error, not a partial merge"
  [ "$FM_PROJECT_ENV_STATUS" = error ] || fail "expected error status, got '$FM_PROJECT_ENV_STATUS'"
  [ "$(cat "$dest")" = "$before" ] || fail "a refused merge must leave the destination byte-for-byte unchanged"
  pass "a declared source with an unterminated quoted value is refused outright rather than half-written"
}

test_gitignored_destination_precondition() {
  local dir
  dir="$TMP_ROOT/gitignore"
  mkdir -p "$dir/ignoring" "$dir/tracking" "$dir/plain"
  git -C "$dir/ignoring" init -q
  printf '.env\n' > "$dir/ignoring/.gitignore"
  git -C "$dir/tracking" init -q

  fm_project_env_dest_gitignored "$dir/ignoring/.env" \
    || fail "a repo whose .gitignore lists .env should satisfy the precondition"
  fm_project_env_dest_gitignored "$dir/tracking/.env" \
    && fail "a repo that does not ignore .env must fail the precondition"
  fm_project_env_dest_gitignored "$dir/plain/.env" \
    && fail "a directory that is not a git working tree must fail the precondition"
  pass "fm_project_env_dest_gitignored succeeds only where the owning repo actually ignores the destination"
}

test_fresh_worktree_is_seeded_with_full_source
test_existing_worktree_gains_missing_key_without_losing_its_own
test_export_prefixed_destination_key_counts_as_present
test_multiline_source_value_is_appended_whole
test_unterminated_source_quote_is_refused_not_half_written
test_gitignored_destination_precondition
test_fully_converged_worktree_is_unchanged_and_idempotent
test_missing_declared_source_is_a_silent_noop
test_symlink_destination_is_skipped_not_followed
test_fm_project_env_source_path_rejects_unsafe_names

echo "# all fm-project-env-lib tests passed"
