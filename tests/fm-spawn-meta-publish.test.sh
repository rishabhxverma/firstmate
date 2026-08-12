#!/usr/bin/env bash
# tests/fm-spawn-meta-publish.test.sh - metadata publication is the point where
# a task becomes recoverable, so it is all-or-nothing:
#   1. The default (tmux) spawn publishes a complete meta record and no
#      backend= line, and leaves no publication temp file behind.
#   2. A spawn whose metadata write fails aborts with a concrete error instead
#      of reporting success, and publishes NO meta file at all - a truncated or
#      absent record must never be mistaken for a live, recoverable task.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-meta-publish)

# Fake tmux: answers the pane-path query so a real spawn runs against a fake
# pane.
make_spawn_fakebin() {
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

# A `mv` that fails ONLY on the rename that publishes this task's meta record,
# standing in for a full or read-only state filesystem at exactly the moment of
# publication. Everything else is delegated to the real mv, so the spawn up to
# that point is unmodified.
install_meta_mv_failure() {  # <fakebin> <id>
  local fakebin=$1 id=$2
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
set -u
for a in "\$@"; do
  case "\$a" in
    */$id.meta) exit 1 ;;
  esac
done
exec /bin/mv "\$@"
SH
  chmod +x "$fakebin/mv"
}

make_case() {  # <name> -> echoes home|proj|wt|fakebin|id
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id="$name-z1"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$id"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

# --- 1. the healthy publication ---------------------------------------------

IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR CASE_ID <<EOF
$(make_case ok)
EOF
OUT=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
  "$CASE_ID" "$PROJ_DIR") || fail "healthy spawn failed: $OUT"
META="$HOME_DIR/state/$CASE_ID.meta"
[ -f "$META" ] || fail "healthy spawn published no meta file"
for key in window endpoint_task_id worktree project harness kind mode yolo tasktmp model effort; do
  grep -q "^$key=" "$META" || fail "meta is missing $key="
done
grep -q '^backend=' "$META" && fail "the default tmux spawn must not write backend="
[ "$(tail -c 1 "$META" | od -An -c | tr -d ' \n')" = '\n' ] \
  || fail "meta must end with a newline"
ls "$HOME_DIR"/state/.*.meta.publish.* >/dev/null 2>&1 \
  && fail "publication temp file left behind on the healthy path"
pass "a healthy spawn publishes a complete tmux meta record and no temp file"
printf -- '--- published meta (%s) ---\n' "$CASE_ID"
cat "$META"

# --- 2. the failed publication ----------------------------------------------

IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR CASE_ID <<EOF
$(make_case fail)
EOF
STATE_DIR="$HOME_DIR/state"
install_meta_mv_failure "$FAKEBIN_DIR" "$CASE_ID"
OUT=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_ID" "$PROJ_DIR")
STATUS=$?
printf -- '--- failed-publication spawn (exit %s) ---\n%s\n' "$STATUS" "$OUT"
[ "$STATUS" -ne 0 ] || fail "a spawn whose metadata write fails must not report success"
case "$OUT" in
  *"cannot publish task metadata"*"aborting the spawn"*) : ;;
  *) fail "the abort must name the metadata publication failure" ;;
esac
[ ! -e "$STATE_DIR/$CASE_ID.meta" ] \
  || fail "an aborted spawn must not leave a meta record behind"
ls "$STATE_DIR"/.*.meta.publish.* >/dev/null 2>&1 \
  && fail "an aborted spawn must not leave a publication temp file behind"
pass "a failed metadata write aborts the spawn and publishes no record"
