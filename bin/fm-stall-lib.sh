#!/usr/bin/env bash
# fm-stall-lib.sh - the ONE owner of Claude stall detection and bounded
# auto-resume scheduling.
#
# WHY THIS EXISTS: a Claude worker that hits its usage-limit window, or whose
# turn is ended by a transient upstream 5xx, leaves a live pane with an idle
# composer and no further output. Supervision surfaces that correctly as a
# stopped crew, but the only recovery was a human typing "continue", so an
# unattended fleet stalls for as long as nobody is watching. This library is
# the decision half of the fix; bin/fm-watch.sh's stall_autoresume_step is the
# only production caller and owns the wiring (gate, send, log, escalate).
#
# TWO STALL CLASSES, deliberately scheduled differently:
#   limit     the pane shows a usage-limit banner. The banner usually names the
#             reset time, so the first resume is scheduled FOR that time rather
#             than guessed. An unparseable or absent reset time degrades to the
#             backoff ladder instead of failing - a late resume is harmless, a
#             never-resume is the bug being fixed.
#   overload  the pane shows an upstream 5xx / overloaded_error banner. There is
#             no reset time to read, so attempts follow the bounded ladder
#             (FM_STALL_BACKOFF, default 2min, 5min, 15min, then every 30min).
# A limit banner outranks an overload banner in the same capture: the limit is
# the longer wait, and resuming into it would just burn an attempt.
#
# THIS LIBRARY NEVER DECIDES ALONE. It classifies rendered text, which is the
# weakest kind of evidence, so the caller must first establish that the worker
# is NOT provably working (bin/fm-busy-lib.sh owns that verdict) and that the
# composer is provably empty (bin/fm-composer-lib.sh owns that one, through the
# backend's classifier). Rendered text then only picks WHICH stall it is. That
# ordering is what keeps an actively-working pane, a pane holding a genuine
# question or permission dialog, and a pane with text already typed into it out
# of the auto-resume path entirely.
#
# ADJACENCY. A stall banner counts only when it sits IMMEDIATELY above the
# composer, with nothing but blank rows, box-drawing rows, and composer chrome
# between them. Claude keeps old banners in its transcript after a SUCCESSFUL
# resume, so a banner floating mid-scrollback is history, not a live error; a
# recovered worker's own output separates its composer from any stale banner and
# the classification reads none. A banner wider than one terminal row is allowed
# one continuation row directly beneath it, because upstream 5xx banners embed a
# JSON blob that wraps. Detection degrades to "no stall" on anything else, which
# is the safe direction: a missed auto-resume surfaces through the ordinary
# stale path, while a spurious nudge types into a healthy worker.
#
# EPISODE MODEL. All scheduling state for one task lives in a single line at
# state/<id>.stall, atomically replaced:
#
#   v2 class=<limit|overload> attempts=<uint> next=<epoch> first=<epoch> \
#      last=<epoch> escalated=<0|1> quiet=<epoch|0> sent=<digest|0>
#
# One episode spans a stall and every resume attempt against it. `quiet` marks
# when the stall was last seen GONE; the record is only discarded, and the
# ladder only restarts at its first rung, once the worker has been clear for
# FM_STALL_EPISODE_RESET. Without that, a worker that resumes, immediately
# re-stalls, and re-stalls again would restart at the 2-minute rung forever -
# exactly the tight loop the ladder exists to prevent. While the stall is still
# showing, quiet is forced back to zero even on polls that decline to act (a
# pending composer), so a continuously-stalling episode can never age out and
# read as freshly recovered. `sent` records the pane digest at the last resume
# delivery: a due attempt against a byte-identical pane is refused (`unchanged`),
# because re-typing into a pane nothing has changed since the last nudge adds no
# information. Such an episode stops owning its polls, handing the wedge to the
# ordinary stale path - which is the escalation for it, since a pane that never
# moved after a delivery is a worker that never got it.
#
# A CHANGE OF STALL CLASS does not restart the ladder. limit and overload are
# two renderings of the same ongoing trouble, and flapping between them must not
# spend nothing while resetting attempts to zero forever. Only a genuinely new
# episode - no record, or a full FM_STALL_EPISODE_RESET of quiet - starts back
# at the first rung.
#
# ESCALATION. After FM_STALL_MAX_ATTEMPTS resumes against the same episode the
# ladder is spent, the episode is marked escalated, and this library stops
# proposing resumes for it. The caller surfaces that once through the ordinary
# stale wake so a human path (stuck-crewmate-recovery) takes over. Auto-resume
# is deliberately silent until then: a routine resume is a log line, not a wake.
#
# Sourcing: set -u safe. Sourced, never executed.

# shellcheck source=bin/fm-composer-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-composer-lib.sh"

FM_STALL_LIB_VERSION=v2

# Non-blank rendered lines scanned for a stall banner, counted back from the end
# of the capture. Bounded on purpose: a stall banner sits immediately above the
# composer, so a wider window only adds ways for unrelated displayed content
# (a diff, a log, a test fixture) to look like a banner.
FM_STALL_SCAN_LINES="${FM_STALL_SCAN_LINES:-20}"

# Seconds between resume attempts within one episode, in order. The last rung
# repeats for every further attempt, so the ladder is bounded but never a tight
# loop.
FM_STALL_BACKOFF="${FM_STALL_BACKOFF:-120 300 900 1800}"

# Resumes allowed against one episode before it escalates to a human.
FM_STALL_MAX_ATTEMPTS="${FM_STALL_MAX_ATTEMPTS:-4}"

# Seconds a worker must stay clear of any stall banner before its episode is
# discarded and the ladder restarts at its first rung.
FM_STALL_EPISODE_RESET="${FM_STALL_EPISODE_RESET:-1800}"

# Grace added after a parsed usage-limit reset time before the first resume, so
# a clock a minute fast cannot resume into a window that has not actually
# reopened.
FM_STALL_RESET_SETTLE="${FM_STALL_RESET_SETTLE:-60}"

# Longest wait a parsed reset time is allowed to schedule. A banner names a
# time of day, not a date, so a time that has already passed today is
# genuinely ambiguous: "resets 3am" read at 10pm means five hours from now,
# but read three minutes after 3am it means the window ALREADY reopened and
# rolling it to tomorrow would park a healthy worker for a full day.
# Observed live on 2026-08-24: a worker showed
# "You've hit your session limit · resets 4:40pm" and was read at 4:43pm, i.e.
# three minutes after its own reset. Time-of-day alone cannot separate those
# two cases, so this bounds the damage instead of guessing: a wait longer than
# one plausible session window is not trusted, and the episode falls back to
# the ladder. Being early costs one spent attempt on a bounded ladder; being a
# day late costs the whole point of unattended recovery.
FM_STALL_MAX_RESET_WAIT="${FM_STALL_MAX_RESET_WAIT:-21600}"

# --- configuration gate ----------------------------------------------------

# fm_stall_auto_resume_setting <config-dir> -> on|off
# Absent file means on: this is the default-on recovery path, and a home that
# has never heard of it should still recover. Only an explicit off disables.
fm_stall_auto_resume_setting() {  # <config-dir>
  local dir=${1:-} value
  [ -n "$dir" ] || { printf 'on'; return 0; }
  [ -f "$dir/auto-resume" ] || { printf 'on'; return 0; }
  value=$(head -n 1 "$dir/auto-resume" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  case "$value" in
    off|0|false|no|disabled) printf 'off' ;;
    *)                       printf 'on' ;;
  esac
}

# fm_stall_enabled <config-dir> <harness>: 0 when auto-resume applies to a task
# on <harness>. Scoped to claude alone. Every other harness ends a failed turn
# through its own lifecycle contract, and none of their stall banners has been
# read against a real binary, so guessing at one would be exactly the rendered-
# text assumption bin/fm-busy-lib.sh's redesign removed.
fm_stall_enabled() {  # <config-dir> <harness>
  local dir=${1:-} harness=${2:-}
  [ "$harness" = claude ] || return 1
  [ "$(fm_stall_auto_resume_setting "$dir")" = on ] || return 1
  return 0
}

# --- rendered-banner classification ----------------------------------------

# fm_stall_pane_digest <capture> -> a stable digest of the raw pane bytes. The
# re-trigger guard compares this against the digest recorded at the last resume
# delivery, so the same capture must hash the same on every poll.
fm_stall_pane_digest() {  # <capture>
  if command -v md5 >/dev/null 2>&1; then printf '%s' "$1" | md5 -q
  else printf '%s' "$1" | md5sum | cut -d' ' -f1; fi
}

# Composer footer hints Claude renders beneath or around its composer, matched
# as fixed lowercase substrings of the row.

# fm_stall_row_is_chrome <plain-row>: 0 when the row is part of the composer's
# own rendering rather than content above it: blank, box-drawing border, a bare
# prompt glyph, a row drawn between the composer box's vertical borders, or a
# footer hint line.
fm_stall_row_is_chrome() {  # <plain-row>
  local row=$1 body lc
  body=${row//[[:space:]]/}
  [ -n "$body" ] || return 0
  case $body in
    *[!╭╮╰╯─━│┃┏┓┗┛┣┫┬┴┼═║╌┈┄]*) ;;
    *) return 0 ;;
  esac
  case $body in
    ❯|›|⟩|'>'|'$'|'%'|'#') return 0 ;;
  esac
  # A row drawn between the composer box's vertical borders is the box itself,
  # whatever its interior holds (an empty prompt, ghost text, or input someone
  # typed); whether that input blocks a resume is the caller's composer gate,
  # not this classifier's business.
  case $body in
    │*│) return 0 ;;
  esac
  lc=$(printf '%s' "$row" | tr '[:upper:]' '[:lower:]')
  case $lc in
    *for\ shortcuts*|*context\ left*|*accept\ edits*|*plan\ mode*|*auto-accept*|*shift+tab*|*esc\ to*) return 0 ;;
  esac
  return 1
}

# A wrapped banner's upper row ends mid-rendering, so its last character is
# punctuation from inside the error payload (JSON delimiters, an underscore from
# a cut identifier). Finished worker output above a stale banner ends in a word
# or a full stop, so requiring this artifact is what keeps the one-row wrap
# allowance from re-opening the false positive adjacency exists to close.
FM_STALL_WRAP_CUT_RE='[][_,:;"({-]$'

# fm_stall_banner_zone <capture> -> stdout the stall-banner text hugging the
# composer, empty when none does. Walks up from the end of the ANSI-stripped
# capture past chrome rows; the first substantive row must carry a banner, or be
# the wrapped continuation of one in the row directly above it (upstream 5xx
# renderings embed a JSON blob wide enough to wrap). Bounded by
# FM_STALL_SCAN_LINES rows.
fm_stall_banner_zone() {  # <capture>
  local r r0='' r1='' i seen=0
  local -a tail_rows=()
  while IFS= read -r r; do tail_rows+=("$r"); done \
    < <(printf '%s\n' "$1" | fm_composer_strip_ansi | tail -n "$FM_STALL_SCAN_LINES")
  for (( i=${#tail_rows[@]} - 1; i >= 0; i-- )); do
    r=${tail_rows[i]}
    fm_stall_row_is_chrome "$r" && continue
    if [ "$seen" -eq 0 ]; then
      r0=$r
      seen=1
      continue
    fi
    r1=$r
    break
  done
  [ "$seen" -eq 1 ] || return 0
  if printf '%s\n' "$r0" | grep -qiE "$FM_STALL_LIMIT_RE|$FM_STALL_OVERLOAD_RE"; then
    printf '%s\n' "$r0"
    return 0
  fi
  if [ -n "$r1" ] && [[ $r1 =~ $FM_STALL_WRAP_CUT_RE ]] \
    && printf '%s %s\n' "$r1" "$r0" | grep -qiE "$FM_STALL_LIMIT_RE|$FM_STALL_OVERLOAD_RE"; then
    printf '%s %s\n' "$r1" "$r0"
    return 0
  fi
  return 0
}

# Usage-limit phrasings observed across Claude's limit banners, plus the older
# pipe-delimited machine form handled separately in fm_stall_parse_reset.
FM_STALL_LIMIT_RE='(usage|session|weekly|opus|sonnet|[0-9]+-hour) limit reached|limit reached[^a-z]*resets|hit your ([a-z0-9-]+ )*limit|(usage|session|weekly) limit[^a-z]*(will )?reset|limit will reset'

# Upstream 5xx phrasings. Each alternative requires the error framing next to
# the code, never a bare three-digit number, so displayed content that merely
# mentions 529 does not read as a live banner.
FM_STALL_OVERLOAD_RE='api[ _-]?error[^0-9a-z]{0,24}5[0-9][0-9]|overloaded_error|5[0-9][0-9][^a-z0-9]{0,12}(overloaded|service unavailable|internal server error|bad gateway|gateway timeout)|api[ _-]?error[^a-z0-9]{0,4}(overloaded|service unavailable)'

# fm_stall_classify <capture> [now-epoch] -> "<class> <detail>"
#   none unknown            no stall banner hugs the composer
#   limit <epoch|unknown>   usage-limit banner; detail is the parsed reset time
#   overload <5xx|5xx-code> transient upstream error banner
fm_stall_classify() {  # <capture> [now-epoch]
  local capture=${1:-} now=${2:-} zone code reset
  [ -n "$now" ] || now=$(date +%s)
  zone=$(fm_stall_banner_zone "$capture")
  [ -n "$zone" ] || { printf 'none unknown\n'; return 0; }
  if printf '%s\n' "$zone" | grep -qiE "$FM_STALL_LIMIT_RE"; then
    reset=$(fm_stall_parse_reset "$zone" "$now")
    printf 'limit %s\n' "${reset:-unknown}"
    return 0
  fi
  if printf '%s\n' "$zone" | grep -qiE "$FM_STALL_OVERLOAD_RE"; then
    code=$(printf '%s\n' "$zone" | grep -oiE "$FM_STALL_OVERLOAD_RE" | grep -oE '5[0-9][0-9]' | head -n 1)
    printf 'overload %s\n' "${code:-5xx}"
    return 0
  fi
  printf 'none unknown\n'
}

# --- reset-time parsing ----------------------------------------------------

# Portable epoch<->calendar conversion. macOS (BSD) date parses an explicit
# input format with -j -f and reads an epoch with -r; GNU date uses -d and
# @epoch. Detected per call rather than cached so the library stays safe to
# source into any shell.
fm_stall_day_for() {  # <tz> <epoch>
  local tz=${1:-} epoch=$2
  if [ "$(uname)" = Darwin ]; then
    if [ -n "$tz" ]; then TZ="$tz" date -r "$epoch" +%Y-%m-%d 2>/dev/null
    else date -r "$epoch" +%Y-%m-%d 2>/dev/null; fi
  else
    if [ -n "$tz" ]; then TZ="$tz" date -d "@$epoch" +%Y-%m-%d 2>/dev/null
    else date -d "@$epoch" +%Y-%m-%d 2>/dev/null; fi
  fi
}

fm_stall_epoch_at() {  # <tz> <YYYY-MM-DD> <HH> <MM>
  local tz=${1:-} day=$2 hh=$3 mm=$4
  if [ "$(uname)" = Darwin ]; then
    if [ -n "$tz" ]; then TZ="$tz" date -j -f '%Y-%m-%d %H:%M:%S' "$day $hh:$mm:00" +%s 2>/dev/null
    else date -j -f '%Y-%m-%d %H:%M:%S' "$day $hh:$mm:00" +%s 2>/dev/null; fi
  else
    if [ -n "$tz" ]; then TZ="$tz" date -d "$day $hh:$mm:00" +%s 2>/dev/null
    else date -d "$day $hh:$mm:00" +%s 2>/dev/null; fi
  fi
}

# fm_stall_parse_reset <text> <now-epoch> -> reset epoch, or empty when the text
# names no reset time this parser can resolve.
#
# Handles the machine form "Claude AI usage limit reached|<epoch>" and the
# rendered forms "resets 3am", "resets 3:30am", "resets at 15:00",
# "will reset at 3pm", each with an optional trailing "(Area/City)" zone,
# including multi-segment and hyphenated zone names. An
# already-past time of day rolls to the next day, because the banner names the
# next reset, not a historical one. Anything else - a spend cap with no timed
# reset, a date-bearing weekly reset, a phrasing not seen yet - returns empty on
# purpose, and the caller's backoff ladder covers it.
fm_stall_parse_reset() {  # <text> <now-epoch>
  local text=$1 now=$2 pipe line after tok tz hh mm meridiem hour24 day epoch
  pipe=$(printf '%s\n' "$text" | grep -oE 'usage limit reached\|[0-9]{6,}' | head -n 1)
  if [ -n "$pipe" ]; then
    printf '%s' "${pipe##*|}"
    return 0
  fi
  line=$(printf '%s\n' "$text" | grep -iE 'reset' | tail -n 1)
  [ -n "$line" ] || return 0
  after=$(printf '%s' "$line" | sed -E 's/.*[Rr][Ee][Ss][Ee][Tt][A-Za-z]*[[:space:]]+(at[[:space:]]+)?//')
  tok=$(printf '%s' "$after" | grep -oiE '^[0-9]{1,2}(:[0-9]{2})?[[:space:]]*([ap]\.?m\.?)?' | head -n 1)
  [ -n "$tok" ] || return 0
  meridiem=$(printf '%s' "$tok" | grep -oiE '[ap]\.?m\.?' | tr -d '. ' | tr '[:upper:]' '[:lower:]')
  hh=$(printf '%s' "$tok" | grep -oE '^[0-9]{1,2}')
  mm=$(printf '%s' "$tok" | grep -oE ':[0-9]{2}' | tr -d ':')
  [ -n "$mm" ] || mm=00
  # Force base 10 BEFORE any arithmetic: bash reads a leading zero as octal, so
  # "09:30" would die in $(( )) and "printf '%02d' 09" would misparse, turning a
  # real reset time into no reset at all.
  case "$hh$mm" in *[!0-9]*|'') return 0 ;; esac
  hh=$((10#$hh))
  mm=$((10#$mm))
  [ "$hh" -le 23 ] || return 0
  [ "$mm" -le 59 ] || return 0
  case "$meridiem" in
    am) if [ "$hh" -eq 12 ]; then hour24=0; else hour24=$hh; fi ;;
    pm) if [ "$hh" -eq 12 ]; then hour24=12; else hour24=$((hh + 12)); fi ;;
    *)  hour24=$hh ;;
  esac
  [ "$hour24" -le 23 ] || return 0
  tz=$(printf '%s' "$after" | grep -oE '\(([A-Za-z_-]+(/[A-Za-z_-]+)+|UTC|GMT)\)' | head -n 1 | tr -d '()')
  hour24=$(printf '%02d' "$hour24")
  day=$(fm_stall_day_for "$tz" "$now")
  [ -n "$day" ] || return 0
  epoch=$(fm_stall_epoch_at "$tz" "$day" "$hour24" "$mm")
  case "${epoch:-}" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$epoch" -le "$now" ]; then
    day=$(fm_stall_day_for "$tz" "$((now + 86400))")
    [ -n "$day" ] || return 0
    epoch=$(fm_stall_epoch_at "$tz" "$day" "$hour24" "$mm")
    case "${epoch:-}" in ''|*[!0-9]*) return 0 ;; esac
  fi
  printf '%s' "$epoch"
}

# --- backoff ladder --------------------------------------------------------

# fm_stall_backoff_delay <attempt> -> seconds before attempt number <attempt>
# (0-based). Past the last configured rung the last rung repeats.
fm_stall_backoff_delay() {  # <attempt>
  local attempt=$1 i=0 rung last=
  for rung in $FM_STALL_BACKOFF; do
    last=$rung
    if [ "$i" -eq "$attempt" ]; then
      printf '%s' "$rung"
      return 0
    fi
    i=$((i + 1))
  done
  printf '%s' "${last:-1800}"
}

# --- episode record --------------------------------------------------------

fm_stall_record_path() {  # <state-dir> <id>
  printf '%s/%s.stall' "$1" "$2"
}

# fm_stall_field <state-dir> <id> <key> -> the recorded value, or empty when the
# record is missing, not v1, or does not carry the key. Never fails, so a
# corrupt record reads as a missing episode and the caller starts a fresh one.
fm_stall_field() {  # <state-dir> <id> <key>
  local file line key=$3 token
  file=$(fm_stall_record_path "$1" "$2")
  [ -f "$file" ] || return 0
  line=$(head -n 1 "$file" 2>/dev/null || true)
  case "$line" in "$FM_STALL_LIB_VERSION "*) ;; *) return 0 ;; esac
  for token in $line; do
    case "$token" in
      "$key"=*) printf '%s' "${token#*=}"; return 0 ;;
    esac
  done
}

fm_stall_uint() {  # <value> <default>
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *)           printf '%s' "$1" ;;
  esac
}

# fm_stall_write <state-dir> <id> <class> <attempts> <next> <first> <last>
#   <escalated> <quiet> <sent>: atomically replace the episode record. <sent> is
# the raw pane digest recorded at the last resume delivery, or 0 for none yet.
fm_stall_write() {  # <state-dir> <id> <class> <attempts> <next> <first> <last> <escalated> <quiet> <sent>
  local dir=$1 id=$2 file tmp
  file=$(fm_stall_record_path "$dir" "$id")
  tmp="$file.tmp.$$"
  printf '%s class=%s attempts=%s next=%s first=%s last=%s escalated=%s quiet=%s sent=%s\n' \
    "$FM_STALL_LIB_VERSION" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

fm_stall_clear() {  # <state-dir> <id>
  rm -f "$(fm_stall_record_path "$1" "$2")" 2>/dev/null || true
}

# fm_stall_note_clear <state-dir> <id> <now>: record that no stall banner is
# showing for this task right now. The first clear poll only stamps `quiet`;
# the episode is discarded once the worker has stayed clear for
# FM_STALL_EPISODE_RESET, so a resume that works for thirty seconds and stalls
# again continues the same ladder instead of restarting it.
fm_stall_note_clear() {  # <state-dir> <id> <now>
  local dir=$1 id=$2 now=$3 quiet sent
  [ -f "$(fm_stall_record_path "$dir" "$id")" ] || return 0
  quiet=$(fm_stall_uint "$(fm_stall_field "$dir" "$id" quiet)" 0)
  if [ "$quiet" -eq 0 ]; then
    sent=$(fm_stall_field "$dir" "$id" sent)
    fm_stall_write "$dir" "$id" \
      "$(fm_stall_field "$dir" "$id" class)" \
      "$(fm_stall_uint "$(fm_stall_field "$dir" "$id" attempts)" 0)" \
      "$(fm_stall_uint "$(fm_stall_field "$dir" "$id" next)" "$now")" \
      "$(fm_stall_uint "$(fm_stall_field "$dir" "$id" first)" "$now")" \
      "$(fm_stall_uint "$(fm_stall_field "$dir" "$id" last)" "$now")" \
      "$(fm_stall_uint "$(fm_stall_field "$dir" "$id" escalated)" 0)" \
      "$now" \
      "${sent:-0}"
    return 0
  fi
  if [ "$((now - quiet))" -ge "$FM_STALL_EPISODE_RESET" ]; then
    fm_stall_clear "$dir" "$id"
  fi
  return 0
}

# fm_stall_note_showing <state-dir> <id> <now>: record that the stall banner is
# STILL showing on this poll even though the caller declined to act on it (the
# composer was not provably empty). This enforces the invariant that an episode
# whose stall is still showing is never treated as newly clear: without it, a
# long pending-composer stretch would leave an older `quiet` timestamp in place,
# and once it aged past FM_STALL_EPISODE_RESET the still-stalling episode would
# be discarded and re-armed at the first rung as if the worker had recovered.
fm_stall_note_showing() {  # <state-dir> <id> <now>
  local dir=$1 id=$2 now=$3 quiet sent
  [ -f "$(fm_stall_record_path "$dir" "$id")" ] || return 0
  quiet=$(fm_stall_uint "$(fm_stall_field "$dir" "$id" quiet)" 0)
  [ "$quiet" -ne 0 ] || return 0
  sent=$(fm_stall_field "$dir" "$id" sent)
  fm_stall_write "$dir" "$id" \
    "$(fm_stall_field "$dir" "$id" class)" \
    "$(fm_stall_uint "$(fm_stall_field "$dir" "$id" attempts)" 0)" \
    "$(fm_stall_uint "$(fm_stall_field "$dir" "$id" next)" "$now")" \
    "$(fm_stall_uint "$(fm_stall_field "$dir" "$id" first)" "$now")" \
    "$now" \
    "$(fm_stall_uint "$(fm_stall_field "$dir" "$id" escalated)" 0)" \
    0 \
    "${sent:-0}"
}

# fm_stall_plan <state-dir> <id> <class> <detail> <now> [pane-digest]
#   -> "<verdict> <arg>"
#   armed <seconds>      this poll OPENED the episode and scheduled its first
#                        attempt; reported separately from `wait` so a caller can
#                        log the transition once rather than on every poll of a
#                        wait that may legitimately run for hours
#   wait <seconds>       the scheduled attempt is not due yet; nothing to do
#   resume <attempt>     attempt number <attempt> (0-based) is due now
#   unchanged <seconds>  an attempt is due but the pane has not changed by one
#                        byte since the last delivery; refuse to re-nudge. The
#                        verdict releases the window back to ordinary
#                        supervision, which is the escalation for it: a pane
#                        that never moved after a delivery belongs to a worker
#                        that never got it
#   escalate <attempts>  the ladder is spent; hand this worker to a human
#   escalated <attempts> already escalated; this library is done with it
# Records the episode as a side effect. The caller must call
# fm_stall_commit_attempt after acting on a `resume`. The digest argument is
# optional; without it the re-trigger guard is inert and every due attempt fires.
fm_stall_plan() {  # <state-dir> <id> <class> <detail> <now> [pane-digest]
  local dir=$1 id=$2 class=$3 detail=$4 now=$5 digest=${6:-}
  local prev_class attempts next first escalated quiet sent reset
  prev_class=$(fm_stall_field "$dir" "$id" class)
  quiet=$(fm_stall_uint "$(fm_stall_field "$dir" "$id" quiet)" 0)
  if [ -z "$prev_class" ] \
    || { [ "$quiet" -gt 0 ] && [ "$((now - quiet))" -ge "$FM_STALL_EPISODE_RESET" ]; }; then
    reset=$(fm_stall_reset_epoch "$class" "$detail" "$now")
    if [ -n "$reset" ]; then
      next=$((reset + FM_STALL_RESET_SETTLE))
    else
      next=$((now + $(fm_stall_backoff_delay 0)))
    fi
    fm_stall_write "$dir" "$id" "$class" 0 "$next" "$now" "$now" 0 0 0 || return 1
    printf 'armed %s\n' "$((next - now))"
    return 0
  fi
  attempts=$(fm_stall_uint "$(fm_stall_field "$dir" "$id" attempts)" 0)
  next=$(fm_stall_uint "$(fm_stall_field "$dir" "$id" next)" "$now")
  first=$(fm_stall_uint "$(fm_stall_field "$dir" "$id" first)" "$now")
  escalated=$(fm_stall_uint "$(fm_stall_field "$dir" "$id" escalated)" 0)
  sent=$(fm_stall_field "$dir" "$id" sent)
  sent=${sent:-0}
  # limit and overload are two renderings of one ongoing stall. Adopting the
  # new class must KEEP the ladder position: resetting attempts to zero here let
  # a pane flapping between renderings restart the ladder forever without ever
  # spending an attempt toward escalation. Only the schedule moves when the new
  # rendering carries usable information - a valid reset time - and otherwise
  # the rung already pending stands.
  if [ "$prev_class" != "$class" ]; then
    reset=$(fm_stall_reset_epoch "$class" "$detail" "$now")
    if [ -n "$reset" ]; then
      next=$((reset + FM_STALL_RESET_SETTLE))
    fi
  fi
  # The stall is showing again, so this episode is not quiet any more - and an
  # adopted class must be persisted even mid-episode. This runs before the
  # escalated check on purpose: an escalated episode whose stall is still
  # showing must never age into a "fresh" one through a stale quiet stamp and
  # re-arm a second ladder plus a second wake.
  if [ "$quiet" -ne 0 ] || [ "$prev_class" != "$class" ]; then
    fm_stall_write "$dir" "$id" "$class" "$attempts" "$next" "$first" "$now" "$escalated" 0 "$sent" || return 1
  fi
  if [ "$escalated" -ne 0 ]; then
    printf 'escalated %s\n' "$attempts"
    return 0
  fi
  if [ "$now" -lt "$next" ]; then
    printf 'wait %s\n' "$((next - now))"
    return 0
  fi
  if [ "$attempts" -ge "$FM_STALL_MAX_ATTEMPTS" ]; then
    fm_stall_write "$dir" "$id" "$class" "$attempts" "$next" "$first" "$now" 1 0 "$sent" || return 1
    printf 'escalate %s\n' "$attempts"
    return 0
  fi
  # Re-trigger guard: a due attempt against a pane that has not changed since
  # the last delivery adds no information, so refuse it rather than re-typing
  # into a worker that never received the previous nudge.
  if [ -n "$digest" ] && [ "$sent" != 0 ] && [ "$sent" = "$digest" ]; then
    printf 'unchanged %s\n' "$((next - now))"
    return 0
  fi
  printf 'resume %s\n' "$attempts"
}

# fm_stall_reset_epoch <class> <detail> <now> -> a usable future reset epoch, or
# empty. Only a limit episode carries one, and only when it is genuinely ahead
# of now and no further out than FM_STALL_MAX_RESET_WAIT; anything beyond that
# is either a misparse or a time-of-day that has already passed and was rolled
# to tomorrow, and the bounded ladder is the safer schedule for both.
fm_stall_reset_epoch() {  # <class> <detail> <now>
  local class=$1 detail=$2 now=$3
  [ "$class" = limit ] || return 0
  case "$detail" in ''|*[!0-9]*) return 0 ;; esac
  [ "$detail" -gt "$now" ] || return 0
  [ "$((detail - now))" -le "$FM_STALL_MAX_RESET_WAIT" ] || return 0
  printf '%s' "$detail"
}

# fm_stall_commit_attempt <state-dir> <id> <class> <detail> <now>
#                         [pane-digest]: record that a resume was just attempted
# and schedule the next rung. Called for a failed delivery too: a send that did
# not land is a spent attempt, so a wedged endpoint walks the same bounded
# ladder to escalation instead of retrying every poll. The digest records what
# the pane looked like at delivery time, arming the re-trigger guard.
fm_stall_commit_attempt() {  # <state-dir> <id> <class> <detail> <now> [pane-digest]
  local dir=$1 id=$2 class=$3 detail=$4 now=$5 digest=${6:-} attempts first next reset
  attempts=$(( $(fm_stall_uint "$(fm_stall_field "$dir" "$id" attempts)" 0) + 1 ))
  first=$(fm_stall_uint "$(fm_stall_field "$dir" "$id" first)" "$now")
  reset=$(fm_stall_reset_epoch "$class" "$detail" "$now")
  if [ -n "$reset" ]; then
    next=$((reset + FM_STALL_RESET_SETTLE))
  else
    next=$((now + $(fm_stall_backoff_delay "$attempts")))
  fi
  fm_stall_write "$dir" "$id" "$class" "$attempts" "$next" "$first" "$now" 0 0 "${digest:-0}"
}

# fm_stall_resume_text <class> -> the single-line steer sent to the worker.
# It deliberately does not say "continue": a worker whose turn died mid-pipeline
# must re-read its own run state first, or it re-applies fixes the pipeline
# already landed. The wording covers workers with no active run too, since a
# scout or a direct-PR ship has no pipeline to consult.
fm_stall_resume_text() {  # <class>
  local class=$1 cause
  case "$class" in
    limit) cause='your usage limit window has reset' ;;
    *)     cause='the upstream API error was transient and has cleared' ;;
  esac
  # shellcheck disable=SC2016 # single quotes are deliberate: the backtick-wrapped
  # command must reach the worker verbatim, not expand here.
  printf 'Auto-resume: %s, so pick your task back up. First re-read your own current state - if a no-mistakes run is active, read `no-mistakes axi status` and continue from the gate it reports rather than redoing pipeline work that already applied - then carry on.' "$cause"
}
