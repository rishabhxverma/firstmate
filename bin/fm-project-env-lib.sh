# shellcheck shell=bash
# Declared per-project local-environment propagation: keeps every crewmate
# worktree for a project seeded with that project's local, gitignored .env
# file, so a spawned crewmate never discovers mid-task that a credential is
# missing from the worktree it happened to land in.
#
# Usage: . bin/fm-project-env-lib.sh   (no FM_* setup required)
#
# The source of truth is explicit and per-project: config/project-env/<name>.env
# in the active firstmate home (gitignored; AGENTS.md section 2). It is never
# guessed from a sibling worktree slot - that guessing is exactly how a
# treehouse pool's .env files drift out of sync with each other.
#
# This is a PRIME-DIRECTIVE-1 EXCEPTION: writing a gitignored .env into a
# project worktree (including a disposable treehouse pool slot) is a
# config-propagation action in the same family as the existing
# inherited-config propagation for secondmate homes (fm-config-inherit-lib.sh).
# It is owned by the two callers below, both referenced from AGENTS.md
# section 1's exceptions list:
#   - bin/fm-spawn.sh converges one worktree at spawn time (ship/scout only;
#     never a --secondmate spawn, which has its own inheritance surface).
#   - bin/fm-project-env-sync.sh converges every existing pool worktree for a
#     project on demand, repairing drift that predates this propagation.
#
# Both callers must confirm the destination .env is actually gitignored by the
# project that owns it (fm_project_env_dest_gitignored) before converging it.
# That is the precondition the PRIME-DIRECTIVE-1 exception rests on: a file git
# ignores cannot be swept upstream by a crewmate's "git add -A", while a
# tracked-or-trackable .env holding a real credential can be.
#
# Merge-or-refuse, never clobber: a destination .env that already exists keeps
# every key it already has, exactly as it has it, even when that value
# diverges from the declared source. Only KEYS the destination is missing are
# appended from the source, verbatim, together with every continuation line of
# a value that spans more than one physical line, so an appended value is never
# left with an unterminated quote. A destination .env is never truncated,
# rewritten key-by-key, or made to match the source exactly - the two failure
# modes this must avoid are (a) losing a worktree-local credential the source
# does not declare and (b) clobbering a value someone intentionally rotated
# directly in a live worktree. Only a brand-new (absent) destination is
# seeded with a full copy of the source.
#
# A key is compared by its normalized name on both sides: leading whitespace
# and an optional "export " prefix are stripped first, so a worktree line
# "export ANTHROPIC_API_KEY=rotated" counts as that key being present and is
# left alone rather than being shadowed by a re-appended source assignment that
# a last-wins loader would then win.
#
# Secrets never touch stdout/stderr from this library: every function here
# either returns a status via FM_PROJECT_ENV_STATUS/FM_PROJECT_ENV_DETAIL (a
# status word and a key COUNT, never a key name or value) or prints bare KEY
# names (never VALUES) for diagnostic use. Callers must keep that contract:
# never echo, cat, or log the contents of a destination .env.

# fm_project_env_source_path <config-dir> <project-name>
# Print the declared per-project env source path. Refuses an unsafe project
# name (path traversal, empty) rather than resolving outside config-dir.
fm_project_env_source_path() {
  local config_dir=$1 project=$2
  [ -n "$config_dir" ] || return 1
  case "$project" in
    ''|*/*|.|..) return 1 ;;
  esac
  printf '%s/project-env/%s.env\n' "$config_dir" "$project"
}

# fm_project_env_line_key <line>
# Print the normalized KEY of one KEY=VALUE line: leading whitespace and an
# optional "export " prefix are stripped, as is whitespace around the key
# itself. Returns non-zero (printing nothing) for a line that does not declare
# a syntactically valid key, so blank lines, comments, and value continuation
# lines are all rejected by the same test. Never prints the value half.
fm_project_env_line_key() {
  local line=$1 key
  line=${line#"${line%%[![:space:]]*}"}
  case "$line" in
    'export '*|'export	'*)
      line=${line#export}
      line=${line#"${line%%[![:space:]]*}"}
      ;;
  esac
  case "$line" in
    *=*) ;;
    *) return 1 ;;
  esac
  key=${line%%=*}
  key=${key%"${key##*[![:space:]]}"}
  case "$key" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  printf '%s' "$key"
}

# fm_project_env_open_quote <text>
# Print the quote character <text> leaves unterminated ("'" or '"'), or nothing
# when every quote in it is balanced. Used to recognize a value that continues
# onto the following physical line. Prints only a quote character, never any of
# <text> itself.
fm_project_env_open_quote() {
  local text=$1 ch state=''
  while [ -n "$text" ]; do
    ch=${text%"${text#?}"}
    text=${text#?}
    case "$state" in
      '')
        case "$ch" in
          "'"|'"') state=$ch ;;
          "\\") text=${text#?} ;;
        esac
        ;;
      "'")
        case "$ch" in
          "'") state='' ;;
        esac
        ;;
      *)
        case "$ch" in
          "\\") text=${text#?} ;;
          '"') state='' ;;
        esac
        ;;
    esac
  done
  printf '%s' "$state"
}

# fm_project_env_dest_gitignored <dest>
# Succeed only when the git repository that owns <dest> ignores it. The two
# callers gate every write on this: it is the precondition that makes writing a
# credential-bearing .env into a project worktree safe (see the header above).
# Fails when <dest>'s directory is not a git working tree at all.
fm_project_env_dest_gitignored() {
  local dest=$1 dir base
  [ -n "$dest" ] || return 1
  case "$dest" in
    */*) dir=${dest%/*}; base=${dest##*/} ;;
    *) dir=.; base=$dest ;;
  esac
  [ -n "$base" ] || return 1
  [ -d "$dir" ] || return 1
  git -C "$dir" check-ignore -q -- "$base" 2>/dev/null
}

# fm_project_env_keys <file>
# Print one bare KEY per line for each KEY=VALUE line in <file> (blank lines,
# #-comments, and value continuation lines skipped). Never prints the value half
# of any line. Silent no-op when <file> does not exist.
fm_project_env_keys() {
  local file=$1 line key block=''
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$block" ]; then
      block="$block
$line"
      [ -n "$(fm_project_env_open_quote "$block")" ] || block=''
      continue
    fi
    key=$(fm_project_env_line_key "$line") || continue
    if [ -n "$(fm_project_env_open_quote "$line")" ]; then
      block=$line
    fi
    printf '%s\n' "$key"
  done < "$file"
}

# fm_project_env_missing_lines <src> <dest>
# Print each whole KEY=VALUE declaration from <src> whose KEY is absent from
# <dest> (or every declared line, verbatim, when <dest> does not exist). A value
# that continues onto further physical lines is emitted with all of its
# continuation lines, so an emitted declaration is always self-contained.
# Preserves the source's exact line content so quoting/escaping in a value is
# never reinterpreted. Never prints anything derived from <dest>'s own values.
# Sets FM_PROJECT_ENV_MISSING_COUNT to the number of KEYS emitted (not lines).
# Returns 2, having emitted nothing at all, when <src>'s last declaration leaves
# a quote unterminated: a partial declaration must never reach a destination.
fm_project_env_missing_lines() {
  local src=$1 dest=$2 dest_keys_file out_file line key block='' count=0 rc=0
  FM_PROJECT_ENV_MISSING_COUNT=0
  [ -f "$src" ] || return 0
  dest_keys_file=$(mktemp "${TMPDIR:-/tmp}/fm-project-env-destkeys.XXXXXX" 2>/dev/null) || return 1
  out_file=$(mktemp "${TMPDIR:-/tmp}/fm-project-env-srclines.XXXXXX" 2>/dev/null) || {
    rm -f "$dest_keys_file"
    return 1
  }
  fm_project_env_keys "$dest" > "$dest_keys_file"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$block" ]; then
      block="$block
$line"
      [ -z "$(fm_project_env_open_quote "$block")" ] || continue
      if ! grep -qxF "$key" "$dest_keys_file"; then
        printf '%s\n' "$block" >> "$out_file"
        count=$((count + 1))
      fi
      block=''
      continue
    fi
    key=$(fm_project_env_line_key "$line") || continue
    if [ -n "$(fm_project_env_open_quote "$line")" ]; then
      block=$line
      continue
    fi
    if ! grep -qxF "$key" "$dest_keys_file"; then
      printf '%s\n' "$line" >> "$out_file"
      count=$((count + 1))
    fi
  done < "$src"
  if [ -n "$block" ]; then
    rc=2
  else
    cat "$out_file"
    FM_PROJECT_ENV_MISSING_COUNT=$count
  fi
  rm -f "$dest_keys_file" "$out_file"
  return "$rc"
}

# fm_project_env_sync_file <src> <dest>
# Converge one destination .env from one declared source, per the
# merge-or-refuse contract documented at the top of this file. Sets
# FM_PROJECT_ENV_STATUS to one of:
#   no-source  <src> does not exist; no-op, not an error
#   seeded     <dest> did not exist; created as a full copy of <src>, mode 0600
#   merged     <dest> existed and gained FM_PROJECT_ENV_DETAIL (a count) keys
#              it was missing; every key it already had is untouched
#   unchanged  <dest> existed and already had every key <src> declares
#   skipped    <dest> exists but is not a plain file (symlink/device/etc.);
#              left completely untouched
#   error      a filesystem operation failed, or <src> ends with an
#              unterminated quoted value and so cannot be merged without
#              corrupting <dest>; FM_PROJECT_ENV_DETAIL explains which step,
#              never file content
# Returns non-zero only for "error". FM_PROJECT_ENV_DETAIL is a short reason
# or a bare integer count - never a key name or value.
fm_project_env_sync_file() {
  local src=$1 dest=$2 dest_parent tmp missing_file missing_count missing_rc
  FM_PROJECT_ENV_STATUS=""
  FM_PROJECT_ENV_DETAIL=""
  [ -n "$dest" ] || { FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="no destination path"; return 1; }
  if [ ! -f "$src" ] || [ -L "$src" ]; then
    FM_PROJECT_ENV_STATUS="no-source"
    return 0
  fi
  dest_parent=${dest%/*}
  [ -n "$dest_parent" ] && [ "$dest_parent" != "$dest" ] || { FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="no destination directory"; return 1; }
  mkdir -p "$dest_parent" 2>/dev/null || { FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="could not create destination directory"; return 1; }
  if [ -L "$dest" ]; then
    FM_PROJECT_ENV_STATUS="skipped"
    FM_PROJECT_ENV_DETAIL="destination is a symlink"
    return 0
  fi
  if [ -e "$dest" ] && [ ! -f "$dest" ]; then
    FM_PROJECT_ENV_STATUS="skipped"
    FM_PROJECT_ENV_DETAIL="destination exists and is not a plain file"
    return 0
  fi
  if [ ! -f "$dest" ]; then
    tmp=$(umask 077; mktemp "$dest_parent/.fm-project-env.XXXXXX" 2>/dev/null) || {
      FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="could not create temp file"; return 1
    }
    if ! cp "$src" "$tmp" 2>/dev/null || ! chmod 0600 "$tmp" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
      FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="could not copy declared source"
      return 1
    fi
    if ! mv -f "$tmp" "$dest" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
      FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="could not install seeded env file"
      return 1
    fi
    FM_PROJECT_ENV_STATUS="seeded"
    return 0
  fi
  missing_file=$(mktemp "${TMPDIR:-/tmp}/fm-project-env-missing.XXXXXX" 2>/dev/null) || {
    FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="could not stage merge"; return 1
  }
  missing_rc=0
  fm_project_env_missing_lines "$src" "$dest" > "$missing_file" || missing_rc=$?
  if [ "$missing_rc" -ne 0 ]; then
    rm -f "$missing_file"
    FM_PROJECT_ENV_STATUS="error"
    if [ "$missing_rc" -eq 2 ]; then
      FM_PROJECT_ENV_DETAIL="declared source ends with an unterminated quoted value"
    else
      FM_PROJECT_ENV_DETAIL="could not read declared source"
    fi
    return 1
  fi
  if [ ! -s "$missing_file" ]; then
    rm -f "$missing_file"
    FM_PROJECT_ENV_STATUS="unchanged"
    return 0
  fi
  missing_count=$FM_PROJECT_ENV_MISSING_COUNT
  tmp=$(umask 077; mktemp "$dest_parent/.fm-project-env.XXXXXX" 2>/dev/null) || {
    rm -f "$missing_file"
    FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="could not create temp file"
    return 1
  }
  if ! cat "$dest" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" "$missing_file" 2>/dev/null || true
    FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="could not stage existing destination"
    return 1
  fi
  if ! { printf '\n' >> "$tmp" && cat "$missing_file" >> "$tmp"; } 2>/dev/null; then
    rm -f "$tmp" "$missing_file" 2>/dev/null || true
    FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="could not append merged keys"
    return 1
  fi
  rm -f "$missing_file"
  if ! chmod 0600 "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="could not set permissions"
    return 1
  fi
  if ! mv -f "$tmp" "$dest" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    FM_PROJECT_ENV_STATUS="error"; FM_PROJECT_ENV_DETAIL="could not install merged env file"
    return 1
  fi
  # shellcheck disable=SC2034 # Read by callers after fm_project_env_sync_file returns.
  FM_PROJECT_ENV_STATUS="merged"
  # shellcheck disable=SC2034 # Read by callers after fm_project_env_sync_file returns.
  FM_PROJECT_ENV_DETAIL="$missing_count"
  return 0
}

# fm_project_env_pool_worktrees <project-dir>
# Print one absolute, existing worktree path per line for every slot in the
# treehouse pool for the repo at <project-dir> (both in-use and available -
# "treehouse status", run from inside <project-dir>, reports the whole pool
# regardless of which slot is current). Read-only: never mutates the project.
# Prints nothing and returns non-zero when treehouse is unavailable or the
# directory has no pool yet.
fm_project_env_pool_worktrees() {
  local project_dir=$1 raw path
  [ -d "$project_dir" ] || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  raw=$(cd "$project_dir" && treehouse status 2>/dev/null) || return 1
  printf '%s\n' "$raw" | sed -nE 's/^[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+(.+)$/\1/p' \
    | while IFS= read -r path; do
        case "$path" in
          "~"*) path="${HOME:-}${path#\~}" ;;
        esac
        [ -n "$path" ] && [ -d "$path" ] || continue
        printf '%s\n' "$path"
      done
}
