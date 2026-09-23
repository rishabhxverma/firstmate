#!/usr/bin/env bash
# tests/fm-stall-recovery.test.sh - Claude stall auto-resume: the decision
# contract in bin/fm-stall-lib.sh, and its wiring inside a real bin/fm-watch.sh
# subprocess.
#
# The behavior under test is unattended recovery. A Claude worker that hits its
# usage-limit window, or whose turn a transient upstream 5xx ends, leaves a live
# pane with an idle composer and no further output; before this path the only
# recovery was a human typing "continue". The library half is exercised as pure
# functions (banner classification, reset-time parsing, the bounded ladder, and
# the episode record). The wiring half is exercised end to end against a real
# watcher process over a simulated stalled pane, because the parts that must not
# regress are ORDERING properties - a busy pane, a pane with text already typed,
# a non-Claude pane, and a home that switched the path off must each be left
# alone - and only the real watcher composes those gates in the real order.
#
# The resume steer itself is stubbed at FM_STALL_SEND_BIN, the watcher's declared
# seam, so these tests assert what was delivered and with which environment
# without driving a real backend submit. fm-send's own delivery contract is owned
# by fm-send-strict.test.sh and fm-send-settle.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-stall-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"

TMP_ROOT=$(fm_test_tmproot fm-stall-recovery-tests)

# A fixed reference clock. Every pure-library assertion computes against it
# rather than "now", so a test cannot pass or fail depending on the hour it runs.
now_at() {  # <YYYY-MM-DD HH:MM:SS>
  if [ "$(uname)" = Darwin ]; then
    date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s
  else
    date -d "$1" +%s
  fi
}
REF_NOW=$(now_at '2026-08-24 10:00:00')

# Render <epoch> as local wall-clock, for readable assertions on a parsed reset.
at_local() {  # <epoch>
  if [ "$(uname)" = Darwin ]; then date -r "$1" +'%Y-%m-%d %H:%M'; else date -d "@$1" +'%Y-%m-%d %H:%M'; fi
}

# Render <epoch> as the 24-hour wall clock a limit banner reports. 24-hour is
# deliberate: it round-trips exactly, including across midnight, so the fixture
# pins the reset-scheduling behavior rather than a locale's am/pm rendering.
at_hhmm() {  # <epoch>
  if [ "$(uname)" = Darwin ]; then date -r "$1" +'%H:%M'; else date -d "@$1" +'%H:%M'; fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

classify() {  # <capture> -> "<class> <detail>"
  fm_stall_classify "$1" "$REF_NOW"
}

# --- banner classification -------------------------------------------------

test_overload_banners_classify_with_their_status_code() {
  [ "$(classify '● Working…
  ⎿  API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}')" \
    = "overload 529" ] || fail "a 529 overloaded_error banner did not classify as an overload stall"
  [ "$(classify '  ⎿  API Error: 500 Internal server error')" = "overload 500" ] \
    || fail "a 500 banner did not classify as an overload stall"
  [ "$(classify 'API Error: 503 Service Unavailable')" = "overload 503" ] \
    || fail "a 503 banner did not classify as an overload stall"
  [ "$(classify 'API Error: 502 Bad Gateway')" = "overload 502" ] \
    || fail "a 502 banner did not classify as an overload stall"
  [ "$(classify 'API Error (Overloaded)')" = "overload 5xx" ] \
    || fail "a code-less overloaded banner did not classify as an overload stall"
  pass "upstream 5xx banners classify as an overload stall, carrying their status code"
}

test_limit_banners_classify_with_a_parsed_reset_time() {
  local out
  out=$(classify "You've hit your usage limit · resets 3pm (America/Toronto)")
  [ "${out%% *}" = limit ] || fail "a usage-limit banner did not classify as a limit stall: $out"
  [ "$(TZ=America/Toronto at_local "${out#* }")" = "2026-08-24 15:00" ] \
    || fail "a zoned reset time was not resolved in its own timezone: $out"

  out=$(classify "You've hit your usage limit · resets 3pm (America/Argentina/Buenos_Aires)")
  [ "$(TZ=America/Argentina/Buenos_Aires at_local "${out#* }")" = "2026-08-24 15:00" ] \
    || fail "a three-segment zone was not resolved in its own timezone: $out"

  out=$(classify "You've hit your usage limit · resets 3pm (America/Port-au-Prince)")
  [ "$(TZ=America/Port-au-Prince at_local "${out#* }")" = "2026-08-24 15:00" ] \
    || fail "a hyphenated zone was not resolved in its own timezone: $out"

  out=$(classify '5-hour limit reached ∙ resets 3am')
  [ "$(at_local "${out#* }")" = "2026-08-25 03:00" ] \
    || fail "an unzoned reset already past today did not roll to the next day: $out"

  out=$(classify 'Claude usage limit reached. Your limit will reset at 11:30pm.')
  [ "$(at_local "${out#* }")" = "2026-08-24 23:30" ] \
    || fail "a 'will reset at H:MMpm' banner did not parse: $out"

  out=$(classify 'usage limit reached · resets at 15:45')
  [ "$(at_local "${out#* }")" = "2026-08-24 15:45" ] \
    || fail "a 24-hour reset time did not parse: $out"

  # The older machine-readable form, kept because a home can still be running a
  # Claude build that emits it.
  [ "$(classify 'Claude AI usage limit reached|1787600000')" = "limit 1787600000" ] \
    || fail "the pipe-delimited machine limit form did not parse"
  pass "usage-limit banners classify as a limit stall with the reset time resolved"
}

# Observed live on 2026-08-24, from the pipeline's own review worker. Kept as a
# named case because it is the only banner in this suite read off a real Claude
# worker rather than sourced from the vetted prior art, and because it is the
# exact shape that exposed the already-passed-reset trap below.
test_the_observed_session_limit_banner_parses() {
  local observed out
  observed="You've hit your session limit · resets 4:40pm (America/Mexico_City)"
  out=$(classify "$observed")
  [ "${out%% *}" = limit ] || fail "the observed session-limit banner did not classify: $out"
  [ "$(TZ=America/Mexico_City at_local "${out#* }")" = "2026-08-24 16:40" ] \
    || fail "the observed session-limit banner resolved to the wrong time: $out"
  pass "the session-limit banner observed in the wild parses to its own reset time"
}

# The trap that banner exposed: a reset time names a time of day, not a date, so
# one that has already passed today gets rolled to tomorrow. Read three minutes
# after its own reset - which is exactly how it was observed - that turns a
# window that just REOPENED into a 24-hour wait, parking a healthy worker for a
# day. Time-of-day cannot resolve the ambiguity, so the wait is bounded instead:
# past the bound the ladder takes over and the worker is retried within minutes.
test_a_reset_that_already_passed_does_not_park_the_worker_for_a_day() {
  local d id n reset
  d="$TMP_ROOT/reset-just-passed/state"; mkdir -p "$d"; id=task
  n=$(now_at '2026-08-24 16:43:00')
  reset=$(fm_stall_parse_reset "You've hit your session limit · resets 4:43pm" "$n")
  [ -n "$reset" ] || fail "a just-passed reset time did not parse at all"
  [ "$((reset - n))" -gt 86000 ] \
    || fail "fixture no longer exercises the rollover it is pinning"
  # It must NOT be trusted as a wait: that is the whole point.
  [ -z "$(fm_stall_reset_epoch limit "$reset" "$n")" ] \
    || fail "a reset rolled a full day forward was trusted as a wait"
  [ "$(fm_stall_plan "$d" "$id" limit "$reset" "$n")" = "armed 120" ] \
    || fail "a just-passed reset parked the worker instead of falling back to the ladder"
  # A genuine overnight wait inside the bound is still honoured.
  rm -f "$(fm_stall_record_path "$d" "$id")"
  [ "$(fm_stall_plan "$d" "$id" limit "$((n + 18000))" "$n")" = "armed $((18000 + FM_STALL_RESET_SETTLE))" ] \
    || fail "a plausible five-hour reset wait was not honoured"
  pass "a reset time that already passed falls back to the ladder instead of waiting a day"
}

test_a_limit_banner_outranks_an_overload_banner() {
  local out
  out=$(classify 'API Error: 529 overloaded_error
You have hit your usage limit · resets 4pm')
  [ "${out%% *}" = limit ] \
    || fail "an overload banner outranked a limit banner in the same capture: $out"
  pass "a limit banner outranks an overload banner in the same capture"
}

test_an_untimed_limit_still_classifies_but_carries_no_reset() {
  # A spend cap has no timed reset to wait for. It must still read as a limit
  # stall (so the ladder, not a wedge escalation, owns it) with an unknown reset.
  [ "$(classify "You've hit your monthly spend limit for this organization.")" = "limit unknown" ] \
    || fail "an untimed spend limit did not classify as a limit stall with no reset"
  pass "a limit with no timed reset classifies as a limit stall carrying no reset time"
}

test_displayed_content_without_error_framing_is_not_a_stall() {
  [ "$(classify 'Running tests...
All 12 tests passed.')" = "none unknown" ] || fail "ordinary output classified as a stall"
  # The exact hazard: a worker whose own task is about 5xx handling renders those
  # words in its pane. Without the error framing next to the code, they are text.
  [ "$(classify 'The retry logic should handle HTTP status codes 500 through 529 gracefully.')" \
    = "none unknown" ] || fail "prose naming 5xx status codes classified as an overload stall"
  [ "$(classify 'diff --git a/limit.md b/limit.md
+the reset happens at 3pm')" = "none unknown" ] \
    || fail "prose naming a reset time classified as a limit stall"
  pass "displayed content without live error framing is never a stall"
}

test_a_banner_must_hug_the_composer() {
  local boxed wrapped buried
  # A banner sitting directly above the composer, with only blank and box rows
  # between them, is a pane genuinely resting on the error.
  boxed="You've hit your usage limit · resets 3pm (America/Toronto)

╭──────────────────────╮
│ >                    │
╰──────────────────────╯
 ? for shortcuts"
  local out
  out=$(classify "$boxed")
  [ "${out%% *}" = limit ] || fail "a banner hugging the composer did not classify: $out"

  # Claude keeps old banners in its transcript after a SUCCESSFUL resume. A
  # banner with the worker's own output between it and the composer is history,
  # not a live error; classifying it re-nudged recovered workers.
  buried='  ⎿  API Error: 529 overloaded_error
the fix landed and all checks are green
line two of ordinary output

❯'
  [ "$(classify "$buried")" = "none unknown" ] \
    || fail "a banner buried above later output classified as a live stall"

  # Upstream 5xx renderings embed a JSON blob wide enough to wrap, so the error
  # framing may sit one row above the banner's last rendered row.
  wrapped='API Error: 529 {"type":"error","error":{"type":"overloaded_
error","message":"Overloaded"}}

❯'
  [ "$(classify "$wrapped")" = "overload 529" ] \
    || fail "a wrapped overload banner hugging the composer did not classify"

  # The wrap allowance must not re-open the buried-banner false positive: a
  # finished sentence above a stale banner is worker output, not a truncated
  # payload row, and its final full stop proves it.
  prose='  ⎿  API Error: 529 overloaded_error
Fixed the retry logic.

❯'
  [ "$(classify "$prose")" = "none unknown" ] \
    || fail "a stale banner under finished output classified as a live stall"
  pass "only a banner hugging the composer classifies as a live stall"
}

test_the_banner_scan_window_is_bounded() {
  local scrolled i
  scrolled='API Error: 529 overloaded_error'
  for i in $(seq 1 25); do scrolled="$scrolled
line $i of ordinary output"; done
  [ "$(classify "$scrolled")" = "none unknown" ] \
    || fail "a banner scrolled far above the composer still classified as a live stall"
  # Widening the window must not bring history back to life: adjacency to the
  # composer, not scan width, is what separates a live banner from an old one.
  [ "$(FM_STALL_SCAN_LINES=40 fm_stall_classify "$scrolled" "$REF_NOW")" = "none unknown" ] \
    || fail "widening the scan window resurrected a scrolled-away banner"
  pass "banner scanning is bounded to the rows just above the composer"
}

test_leading_zero_reset_times_parse_in_base_ten() {
  # Bash reads a leading zero as octal: "09:30" once died in arithmetic and
  # misparsed through printf, turning a real reset time into no reset at all.
  local out n
  n=$(now_at '2026-08-24 08:00:00')
  out=$(fm_stall_parse_reset 'usage limit reached · resets at 09:30' "$n")
  [ -n "$out" ] || fail "a leading-zero reset time produced no reset at all"
  [ "$(at_local "$out")" = "2026-08-24 09:30" ] \
    || fail "a leading-zero hour was not read in base ten: $(at_local "$out")"
  out=$(fm_stall_parse_reset 'resets 08:30pm' "$n")
  [ "$(at_local "$out")" = "2026-08-24 20:30" ] \
    || fail "a leading-zero hour with a meridiem was not read in base ten: $(at_local "$out")"
  out=$(fm_stall_parse_reset 'resets at 09:05am' "$n")
  [ "$(at_local "$out")" = "2026-08-24 09:05" ] \
    || fail "a leading-zero minute was not preserved: $(at_local "$out")"
  pass "reset times with leading zeros parse in base ten"
}

test_unparseable_reset_times_degrade_to_no_reset() {
  [ -z "$(fm_stall_parse_reset 'resets sometime next week' "$REF_NOW")" ] \
    || fail "an unparseable reset phrase produced a reset time"
  [ -z "$(fm_stall_parse_reset 'resets 47pm' "$REF_NOW")" ] \
    || fail "an out-of-range hour produced a reset time"
  [ -z "$(fm_stall_parse_reset 'no reset information here' "$REF_NOW")" ] \
    || fail "text with no reset phrase produced a reset time"
  pass "an unresolvable reset time degrades to no reset rather than a wrong one"
}

# --- the bounded ladder ----------------------------------------------------

test_backoff_ladder_is_bounded_and_repeats_its_last_rung() {
  [ "$(fm_stall_backoff_delay 0)" = 120 ] || fail "first rung is not 2 minutes"
  [ "$(fm_stall_backoff_delay 1)" = 300 ] || fail "second rung is not 5 minutes"
  [ "$(fm_stall_backoff_delay 2)" = 900 ] || fail "third rung is not 15 minutes"
  [ "$(fm_stall_backoff_delay 3)" = 1800 ] || fail "fourth rung is not 30 minutes"
  # Past the configured ladder the last rung repeats, so the schedule is bounded
  # in both directions: it never tightens into a poll-rate loop and never grows
  # until a resume is effectively never attempted.
  [ "$(fm_stall_backoff_delay 4)" = 1800 ] || fail "the ladder did not repeat its last rung"
  [ "$(fm_stall_backoff_delay 50)" = 1800 ] || fail "the ladder did not repeat its last rung far out"
  pass "the backoff ladder is bounded and repeats its last rung"
}

# --- configuration gate ----------------------------------------------------

test_auto_resume_is_default_on_for_claude_only() {
  local dir
  dir="$TMP_ROOT/config-gate"; mkdir -p "$dir"
  fm_stall_enabled "$dir" claude || fail "auto-resume is not default-on for claude with no config file"
  for h in codex opencode pi grok kimi muse ''; do
    fm_stall_enabled "$dir" "$h" && fail "auto-resume applied to harness '${h:-<empty>}'"
  done
  printf 'off\n' > "$dir/auto-resume"
  fm_stall_enabled "$dir" claude && fail "config/auto-resume=off did not disable auto-resume"
  printf 'on\n' > "$dir/auto-resume"
  fm_stall_enabled "$dir" claude || fail "config/auto-resume=on did not enable auto-resume"
  # Only an explicit off disables: this is a recovery path, and an unreadable
  # preference must not quietly leave a fleet unable to recover.
  printf 'wibble\n' > "$dir/auto-resume"
  fm_stall_enabled "$dir" claude || fail "an unrecognised config value disabled auto-resume"
  pass "auto-resume is default-on for claude alone and only an explicit off disables it"
}

# --- episode record --------------------------------------------------------

test_an_episode_walks_the_ladder_then_escalates_once() {
  local d id n
  d="$TMP_ROOT/episode/state"; mkdir -p "$d"; id=task; n=1000000
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$n")" = "armed 120" ] \
    || fail "a first sighting did not arm the first rung"
  # A poll that merely re-observes the same wait reports `wait`, never `armed`:
  # the watcher logs the transition once, and a limit wait can run for hours.
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$((n + 60))")" = "wait 60" ] \
    || fail "an attempt came due early, or re-reported itself as newly armed"
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$((n + 120))")" = "resume 0" ] \
    || fail "the first attempt did not come due on its rung"
  fm_stall_commit_attempt "$d" "$id" overload 529 "$((n + 120))" || fail "committing an attempt failed"
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$((n + 320))")" = "wait 100" ] \
    || fail "the second rung was not scheduled 5 minutes out"

  local i now=$((n + 420))
  for i in 1 2 3; do
    [ "$(fm_stall_plan "$d" "$id" overload 529 "$now")" = "resume $i" ] \
      || fail "attempt $i did not come due"
    fm_stall_commit_attempt "$d" "$id" overload 529 "$now"
    now=$((now + 100000))
  done
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$now")" = "escalate 4" ] \
    || fail "a spent ladder did not escalate"
  # Escalating is a one-shot: the library hands the worker to a human and stops
  # proposing resumes, so a supervisor is never re-woken by the same episode.
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$((now + 100000))")" = "escalated 4" ] \
    || fail "an escalated episode proposed more work"
  pass "an episode walks the bounded ladder, escalates once, then stays quiet"
}

test_an_escalated_episode_whose_stall_returns_never_rearms() {
  local d id now
  d=$(mktemp -d "$TMP_ROOT/escalated-rearm.XXXXXX"); id=stuck
  now=$REF_NOW
  printf 'v2 class=overload attempts=4 next=%s first=%s last=%s escalated=1 quiet=0 sent=0\n' \
    "$now" "$now" "$now" > "$d/$id.stall"
  # A human nudges the worker; one busy poll stamps the episode quiet.
  fm_stall_note_clear "$d" "$id" "$((now + 60))"
  [ "$(fm_stall_field "$d" "$id" quiet)" = "$((now + 60))" ] \
    || fail "a busy poll did not stamp the escalated episode quiet"
  # The same stall is showing again well inside the quiet window.
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$((now + 120))")" = "escalated 4" ] \
    || fail "an escalated episode proposed work when its stall returned"
  [ "$(fm_stall_field "$d" "$id" quiet)" = 0 ] \
    || fail "seeing the stall again did not un-quiet the escalated episode"
  [ "$(fm_stall_field "$d" "$id" escalated)" = 1 ] \
    || fail "seeing the stall again dropped the escalated mark"
  # Far past FM_STALL_EPISODE_RESET, with the stall still showing every poll,
  # the episode must not age into a fresh one and re-arm a second ladder.
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$((now + 120 + FM_STALL_EPISODE_RESET * 2))")" = "escalated 4" ] \
    || fail "a still-stalled escalated episode re-armed after the quiet window"
  [ ! -s "$d/$id.stall" ] || grep -q 'escalated=1' "$d/$id.stall" \
    || fail "the escalated record was replaced: $(cat "$d/$id.stall")"
  pass "an escalated episode whose stall keeps showing stays escalated past the quiet window"
}

test_an_episode_survives_a_brief_clear_and_restarts_after_a_long_one() {
  local d id n
  d="$TMP_ROOT/episode-clear/state"; mkdir -p "$d"; id=task; n=1000000
  fm_stall_plan "$d" "$id" overload 529 "$n" >/dev/null
  fm_stall_commit_attempt "$d" "$id" overload 529 "$((n + 120))"
  [ "$(fm_stall_field "$d" "$id" attempts)" = 1 ] || fail "the attempt was not recorded"

  # A resume that works for a moment and re-stalls must CONTINUE the ladder.
  # Restarting it at the first rung is exactly the tight retry loop the ladder
  # exists to prevent.
  fm_stall_note_clear "$d" "$id" "$((n + 130))"
  fm_stall_plan "$d" "$id" overload 529 "$((n + 200))" >/dev/null
  [ "$(fm_stall_field "$d" "$id" attempts)" = 1 ] \
    || fail "a brief clear restarted the ladder instead of continuing it"

  # Once the worker has genuinely been productive for a full reset window, the
  # episode is over and a later stall is a new one.
  fm_stall_note_clear "$d" "$id" "$((n + 300))"
  fm_stall_note_clear "$d" "$id" "$((n + 300 + FM_STALL_EPISODE_RESET))"
  [ ! -e "$(fm_stall_record_path "$d" "$id")" ] \
    || fail "an episode survived a full clear window"
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$((n + 400000))")" = "armed 120" ] \
    || fail "a genuinely new stall did not start at the first rung"
  pass "an episode survives a brief clear and restarts only after a full clear window"
}

test_a_still_showing_stall_is_never_marked_clear() {
  local d id n quiet_t
  d="$TMP_ROOT/episode-showing/state"; mkdir -p "$d"; id=task; n=1000000
  fm_stall_plan "$d" "$id" overload 529 "$n" >/dev/null
  fm_stall_commit_attempt "$d" "$id" overload 529 "$((n + 120))"
  # A moment of recovery stamps quiet...
  fm_stall_note_clear "$d" "$id" "$((n + 130))"
  quiet_t=$(fm_stall_field "$d" "$id" quiet)
  [ "$quiet_t" != 0 ] || fail "the clear poll did not stamp quiet"
  # ...but a poll that sees the stall showing again while declining to act
  # (a composer that was not provably empty) must un-stamp it: otherwise the
  # still-stalling episode would age out and later re-arm as if the worker had
  # recovered, restarting the ladder it had already half spent.
  fm_stall_note_showing "$d" "$id" "$((n + 200))"
  [ "$(fm_stall_field "$d" "$id" quiet)" = 0 ] \
    || fail "a declined poll left the episode marked as quietly clearing"
  [ "$(fm_stall_field "$d" "$id" attempts)" = 1 ] \
    || fail "noting a showing stall disturbed the ladder position"
  [ "$(fm_stall_field "$d" "$id" last)" = "$((n + 200))" ] \
    || fail "noting a showing stall did not record when it was seen"
  # With no quiet timestamp to un-stamp, the call is a no-op that preserves
  # every field.
  fm_stall_note_showing "$d" "$id" "$((n + 300))"
  [ "$(fm_stall_field "$d" "$id" first)" = "$n" ] \
    || fail "re-noting a showing stall rewrote the episode's history"
  pass "a poll that declines while the stall is showing keeps the episode honestly stalled"
}

test_a_limit_episode_schedules_its_first_attempt_for_the_reset() {
  local d id n reset
  d="$TMP_ROOT/episode-limit/state"; mkdir -p "$d"; id=task; n=1000000; reset=$((n + 3600))
  [ "$(fm_stall_plan "$d" "$id" limit "$reset" "$n")" = "armed $((3600 + FM_STALL_RESET_SETTLE))" ] \
    || fail "a limit episode did not schedule its first attempt for the parsed reset"
  # A reset time that is already past, or implausibly far out, means the parse
  # went wrong; the ladder is the safer schedule than a wait that never ends.
  rm -f "$(fm_stall_record_path "$d" "$id")"
  [ "$(fm_stall_plan "$d" "$id" limit "$((n - 10))" "$n")" = "armed 120" ] \
    || fail "a past reset time was trusted over the ladder"
  rm -f "$(fm_stall_record_path "$d" "$id")"
  [ "$(fm_stall_plan "$d" "$id" limit "$((n + FM_STALL_MAX_RESET_WAIT + 60))" "$n")" = "armed 120" ] \
    || fail "a reset time past FM_STALL_MAX_RESET_WAIT was trusted over the ladder"
  pass "a limit episode waits for its parsed reset, and falls back to the ladder when there is none"
}

test_a_damaged_or_foreign_record_reads_as_a_fresh_episode() {
  local d id n
  d="$TMP_ROOT/episode-damaged/state"; mkdir -p "$d"; id=task; n=1000000
  printf 'garbage not a record\n' > "$(fm_stall_record_path "$d" "$id")"
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$n")" = "armed 120" ] \
    || fail "a corrupt record did not read as a fresh episode"
  # A record written by the previous schema version is foreign too: reading it
  # as a fresh episode costs one ladder position at upgrade, while trusting
  # misaligned fields could schedule anything.
  printf 'v1 class=overload attempts=3 next=1 first=1 last=1 escalated=0 quiet=0\n' \
    > "$(fm_stall_record_path "$d" "$id")"
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$n")" = "armed 120" ] \
    || fail "a previous-version record did not read as a fresh episode"
  [ "$(fm_stall_field "$d" "$id" attempts)" = 0 ] \
    || fail "a previous-version record leaked its attempts into the new schema"
  pass "a damaged or previous-version record reads as a fresh episode"
}

test_a_class_change_keeps_the_ladder_position() {
  local d id n reset v
  d="$TMP_ROOT/episode-switch/state"; mkdir -p "$d"; id=task; n=1000000; reset=$((n + 3600))
  fm_stall_plan "$d" "$id" overload 529 "$n" >/dev/null
  fm_stall_commit_attempt "$d" "$id" overload 529 "$((n + 120))"
  [ "$(fm_stall_field "$d" "$id" attempts)" = 1 ] || fail "the attempt was not recorded"
  # The same trouble re-rendered as a usage-limit banner adopts the usable reset
  # time but keeps the spent attempt: restarting the ladder here let a pane
  # flapping between renderings retry forever without ever escalating.
  [ "$(fm_stall_plan "$d" "$id" limit "$reset" "$((n + 130))")" = "wait $((3600 + FM_STALL_RESET_SETTLE - 130))" ] \
    || fail "adopting a limit rendering did not schedule for its reset"
  [ "$(fm_stall_field "$d" "$id" attempts)" = 1 ] \
    || fail "a change of stall class restarted the ladder"
  [ "$(fm_stall_field "$d" "$id" class)" = limit ] \
    || fail "the record did not adopt the new class"
  # Switching back, with no usable reset time, keeps the pending rung: losing
  # the banner's clock does not invalidate a schedule already made for the same
  # trouble, and keeping it is what keeps a flapping pane bounded.
  [ "$(fm_stall_plan "$d" "$id" overload 5xx "$((n + 140))")" = "wait $((3660 - 140))" ] \
    || fail "a class change did not keep its pending rung"
  # And the ladder stays bounded: enough dues still escalate, whichever way the
  # pane renders them.
  local i now=$((n + 100000))
  for i in 1 2 3 4; do
    case $((i % 2)) in
      0) v=$(fm_stall_plan "$d" "$id" limit unknown "$now") ;;
      *) v=$(fm_stall_plan "$d" "$id" overload 529 "$now") ;;
    esac
    case $v in resume*) fm_stall_commit_attempt "$d" "$id" overload 529 "$now" ;; esac
    now=$((now + 100000))
  done
  [ "$(fm_stall_field "$d" "$id" escalated)" = 1 ] \
    || fail "a flapping pane never reached escalation"
  pass "a change of stall class keeps the ladder position and stays bounded"
}

test_an_unchanged_pane_refuses_a_due_resume() {
  local d id n dg dg2
  d="$TMP_ROOT/episode-unchanged/state"; mkdir -p "$d"; id=task; n=1000000
  dg=$(fm_stall_pane_digest "pane bytes")
  dg2=$(fm_stall_pane_digest "different pane bytes")
  [ "$dg" != "$dg2" ] || fail "digest fixtures collided"
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$n")" = "armed 120" ] \
    || fail "the episode did not arm"
  # Before any delivery there is nothing to compare against: the guard is inert.
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$((n + 120))" "$dg")" = "resume 0" ] \
    || fail "the guard fired before any delivery had been made"
  fm_stall_commit_attempt "$d" "$id" overload 529 "$((n + 120))" "$dg"
  [ "$(fm_stall_field "$d" "$id" sent)" = "$dg" ] \
    || fail "committing an attempt did not record the pane digest"
  # Same bytes at the next due rung: refuse. Re-typing into a pane that has not
  # changed since the last delivery adds no information.
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$((n + 420))" "$dg")" = "unchanged 0" ] \
    || fail "an unchanged pane was resumed again"
  # The pane moved: the next rung is genuinely due.
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$((n + 420))" "$dg2")" = "resume 1" ] \
    || fail "a changed pane was blocked by the re-trigger guard"
  # A spent ladder escalates even when the pane is frozen: a worker that never
  # moved after four deliveries needs a human, not silence.
  rm -f "$(fm_stall_record_path "$d" "$id")"
  printf '%s class=overload attempts=4 next=1 first=1 last=1 escalated=0 quiet=0 sent=%s\n' \
    "$FM_STALL_LIB_VERSION" "$dg" > "$(fm_stall_record_path "$d" "$id")"
  [ "$(fm_stall_plan "$d" "$id" overload 529 "$n" "$dg")" = "escalate 4" ] \
    || fail "an unchanged pane hid a spent ladder from escalation"
  pass "a byte-identical pane refuses a due resume without hiding escalation"
}

# --- watcher wiring, end to end -------------------------------------------

# A stalled-pane fixture: a fake tmux serving one pane file that carries the
# banner rows above a real bordered composer box, a fake fm-send recorder bound
# to the watcher's declared FM_STALL_SEND_BIN seam, and a claude task recorded
# exactly as fm-spawn records one.
make_stall_case() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/config" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR_Y:-0}"; exit 0 ;; esac
    done
    for a in "$@"; do [ "$a" = "-p" ] && { printf 'fakepane\n'; exit 0; }; done
    exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0 ;;
  capture-pane)
    # Honour an explicit numeric row band (the composer reader's single-row
    # read); every other form returns the whole pane, which is what both the
    # 40-line watcher tail and the composer's full structural scan want here.
    _S=""; _E=""; shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -S) _S="${2:-}"; shift 2; continue ;;
        -E) _E="${2:-}"; shift 2; continue ;;
        *) shift ;;
      esac
    done
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] || exit 0
    if [ -n "$_S" ] && [ -n "$_E" ]; then
      case "$_S$_E" in
        *[!0-9]*) cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
        *) sed -n "$((_S + 1)),$((_E + 1))p" "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
      esac
    else
      cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/fm-send-fake.sh" <<'SH'
#!/usr/bin/env bash
# Records one delivery attempt as "<FM_HOME>\t<target>\t<text>" so a test can
# assert both the steer and the environment it was delivered with.
set -u
printf '%s\t%s\t%s\n' "${FM_HOME:-<unset>}" "${1:-}" "${2:-}" >> "${FM_FAKE_SEND_LOG:-/dev/null}"
exit "${FM_FAKE_SEND_RC:-0}"
SH
  chmod +x "$fakebin/fm-send-fake.sh"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$dir"
}

# write_pane <file> <shape> <composer-content> <banner-line>... : render a pane
# with the banner rows above a real composer, and echo the cursor row (0-based)
# that lands in it.
#
# Both shapes are exercised because the composer is a vendor surface that has
# already changed once: Claude Code 2.1.x renders the borderless `❯` composer,
# earlier builds drew a bordered box, and bin/fm-composer-lib.sh accepts both.
# A fixture pinned to only one shape would stop covering production the next
# time that rendering moves.
write_pane() {
  local file=$1 shape=$2 content=$3 line width border i rows
  shift 3
  : > "$file"
  rows=0
  for line in "$@"; do
    printf '%s\n' "$line" >> "$file"
    rows=$((rows + 1))
  done
  printf '\n' >> "$file"
  rows=$((rows + 1))
  if [ "$shape" = bare ]; then
    printf '❯ %s\n' "$content" >> "$file"
    printf '%s\n' "$rows"
    return 0
  fi
  width=$((${#content} + 4))
  [ "$width" -ge 14 ] || width=14
  border=""; i=0
  while [ "$i" -lt "$width" ]; do border="${border}─"; i=$((i + 1)); done
  {
    printf '╭%s╮\n' "$border"
    printf '│ > %-*s │\n' "$((width - 4))" "$content"
    printf '╰%s╯\n' "$border"
  } >> "$file"
  printf '%s\n' "$((rows + 1))"
}

# Record a claude task exactly as a spawn does, including the semantic busy
# record its lifecycle hooks would have written.
arm_claude_task() {  # <state> <id> <window> <busy-state> <busy-event> [harness]
  local state=$1 id=$2 window=$3 busy=$4 event=$5 harness=${6:-claude} gen
  fm_write_meta "$state/$id.meta" "window=$window" "backend=tmux" "kind=ship" "harness=$harness"
  gen=$("$BUSY_EVENT" arm "$state" "$id") || fail "arming the busy record for $id failed"
  "$BUSY_EVENT" apply "$state" "$id" "$busy" --gen "$gen" --source claude-hook --event "$event" \
    || fail "applying the busy record for $id failed"
}

# Launch a watcher over <dir> with the stall path wired to the fixture's seams.
# The ladder is compressed to one second so a test exercises the SCHEDULE rather
# than waiting on it; every schedule-shape assertion is made against the pure
# library above, where the real rungs are pinned.
#
# FM_WATCH_HANDLING_SUCCESSOR=1 on every launch: docs/watcher-continuity.md
# made the watcher deliberately one-shot ("one actionable reason closes one
# watcher cycle") and moved must-work continuity above the process boundary -
# every real continuous-supervision relaunch is started as a successor of the
# cycle that just closed, before or immediately after that close is delivered.
# A bare non-successor relaunch is instead read as a genuine downtime gap: it
# resurfaces a one-time "check: rearm-resurface" wake and exits before this
# suite's pane ever reaches classification, which is a real behavior this
# suite does not own (tests/fm-watch-recovery-loop.test.sh,
# tests/fm-wake-queue.test.sh, and tests/fm-watcher-lock.test.sh do). This
# suite tests stall classification and decline/delivery bookkeeping across
# repeated cycles, so every relaunch here models the ordinary continuous case
# a real supervising layer produces, not a downtime episode; the flag is a
# no-op on a case's first launch, where no prior cycle and no marker exist.
stall_watch_bg() {  # <dir> <window> <pane-file> <cursor-y> <out> [extra env...]
  local dir=$1 window=$2 pane=$3 cy=$4 out=$5
  shift 5
  PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$pane" FM_FAKE_TMUX_CURSOR_Y="$cy" \
    FM_FAKE_SEND_LOG="$dir/sent.log" \
    FM_STALL_SEND_BIN="$dir/fakebin/fm-send-fake.sh" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STALL_BACKOFF='1 1 1 1' FM_STALL_MAX_ATTEMPTS=99 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    env "$@" "$WATCH" > "$out" 2>&1 &
}

wait_for_file() {  # <file> [ticks]
  local f=$1 limit=${2:-60} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -s "$f" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The delivery recorder and the watcher's own log are written by two processes,
# so a log assertion made the instant a delivery lands is a race. Wait for the
# line instead of sleeping a guessed interval.
wait_for_grep() {  # <pattern> <file> [ticks]
  local pattern=$1 f=$2 limit=${3:-60} i=0
  while [ "$i" -lt "$limit" ]; do
    grep -F -- "$pattern" "$f" >/dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_an_overloaded_pane_is_resumed_without_waking_the_supervisor() {
  local dir state window pane out cy sent
  dir=$(make_stall_case overload-resume); state="$dir/state"
  window="test:fm-stalled"; pane="$dir/pane.txt"; out="$dir/watch.out"; sent="$dir/sent.log"
  cy=$(write_pane "$pane" bare "" \
    '● Analysing the failing test' \
    '  ⎿  API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}')
  arm_claude_task "$state" stalled "$window" idle stop-failure

  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  local pid=$!
  wait_for_file "$sent" 300 || { reap "$pid"; fail "a stalled claude pane was never auto-resumed: $(cat "$out")"; }

  # The steer must be delivered with this home named explicitly: fm-send fails
  # closed without it, so a steer that omitted it would never reach the worker.
  local home target text
  IFS=$(printf '\t') read -r home target text < "$sent"
  [ "$home" = "$dir" ] || fail "the resume steer was delivered without this home: '$home'"
  [ "$target" = stalled ] || fail "the resume steer named the wrong task: '$target'"
  case "$text" in
    *'no-mistakes axi status'*) ;;
    *) fail "the resume steer did not tell the worker to re-read its own run state: $text" ;;
  esac
  case "$text" in
    *'Auto-resume'*) ;;
    *) fail "the resume steer is not identifiable as an auto-resume: $text" ;;
  esac

  # Recovery is routine, not news: it is logged, never escalated.
  [ ! -s "$state/.wake-queue" ] || fail "an auto-resume queued a wake: $(cat "$state/.wake-queue")"
  [ ! -s "$out" ] || fail "an auto-resume printed a wake reason: $(cat "$out")"
  is_live_non_zombie "$pid" || fail "the watcher exited over a pane it had just resumed"
  wait_for_grep 'auto-resumed stalled after a overload stall' "$state/.watch-triage.log" \
    || fail "the auto-resume was not recorded in the watcher log: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  [ "$(fm_stall_field "$state" stalled class)" = overload ] || fail "no overload episode was recorded"
  reap "$pid"
  pass "a stalled claude pane is auto-resumed with an explicit home, and never wakes the supervisor"
}

test_a_usage_limit_pane_waits_for_its_reset_instead_of_resuming() {
  local dir state window pane out cy sent reset next
  dir=$(make_stall_case limit-wait); state="$dir/state"
  window="test:fm-limited"; pane="$dir/pane.txt"; out="$dir/watch.out"; sent="$dir/sent.log"
  reset=$(( $(date +%s) + 3600 ))
  cy=$(write_pane "$pane" boxed "" \
    "You've hit your usage limit · resets at $(at_hhmm "$reset")")
  arm_claude_task "$state" limited "$window" idle stop-failure

  # The ladder is compressed to one second here, so a resume within the test
  # window would mean the reset time was ignored - which is the regression this
  # pins: resuming into a closed limit window burns an attempt and changes nothing.
  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  local pid=$!
  # Wait for the episode itself, not a fixed interval: the assertion below is an
  # absence, and asserting an absence before the path has even run is vacuous.
  wait_for_file "$state/limited.stall" 300 \
    || { reap "$pid"; fail "no limit episode was opened for a usage-limit pane: $(cat "$out")"; }
  sleep 3
  [ ! -s "$sent" ] || { reap "$pid"; fail "a usage-limit pane was resumed before its reset: $(cat "$sent")"; }
  is_live_non_zombie "$pid" || fail "the watcher exited over a pane waiting out its limit window"
  [ ! -s "$state/.wake-queue" ] || fail "a limit wait queued a wake: $(cat "$state/.wake-queue")"
  [ "$(fm_stall_field "$state" limited class)" = limit ] || fail "no limit episode was recorded"
  next=$(fm_stall_field "$state" limited next)
  [ "$next" -ge "$reset" ] || fail "the first attempt was scheduled before the reset ($next < $reset)"
  reap "$pid"
  pass "a usage-limit pane waits for its own reset time instead of resuming into a closed window"
}

test_a_spent_ladder_surfaces_one_stale_wake_carrying_its_history() {
  local dir state window pane out cy drain_out
  dir=$(make_stall_case ladder-spent); state="$dir/state"
  window="test:fm-spent"; pane="$dir/pane.txt"; out="$dir/watch.out"
  drain_out="$dir/drain.out"
  cy=$(write_pane "$pane" bare "" '  ⎿  API Error: 529 overloaded_error')
  arm_claude_task "$state" spent "$window" idle stop-failure
  # An episode whose attempts are already spent and whose next attempt is due.
  printf '%s class=overload attempts=4 next=1 first=1 last=1 escalated=0 quiet=0 sent=0\n' \
    "$FM_STALL_LIB_VERSION" > "$state/spent.stall"

  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out" FM_STALL_MAX_ATTEMPTS=4
  local pid=$!
  wait_for_exit "$pid" 300 || fail "a spent auto-resume ladder never surfaced: $(cat "$out")"
  assert_grep "stale: $window" "$out" "the spent ladder did not surface as a stale wake"
  assert_grep 'auto-resume attempts spent' "$out" \
    "the escalation did not report that auto-resume had already been tried"
  [ ! -s "$dir/sent.log" ] || fail "a spent ladder attempted another resume"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$drain_out" 2>/dev/null \
    || fail "draining after the escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null \
    || fail "the escalation was not queued as a durable wake"
  pass "a spent auto-resume ladder surfaces exactly one stale wake carrying its history"
}

# The three structural gates, each asserted the same way: no steer is delivered
# and no episode is recorded, so nothing about the pane is touched.
assert_never_resumed() {  # <dir> <state> <id> <pid> <what>
  local dir=$1 state=$2 id=$3 pid=$4 what=$5
  sleep 3
  [ ! -s "$dir/sent.log" ] || { reap "$pid"; fail "$what was auto-resumed: $(cat "$dir/sent.log")"; }
  [ ! -e "$state/$id.stall" ] || { reap "$pid"; fail "$what opened an auto-resume episode"; }
  reap "$pid"
}

test_a_working_pane_is_never_resumed() {
  local dir state window pane out cy
  dir=$(make_stall_case busy-pane); state="$dir/state"
  window="test:fm-busy"; pane="$dir/pane.txt"; out="$dir/watch.out"
  # The same banner text, but the worker's own lifecycle says it is mid-turn:
  # Claude retries a 529 inside the turn before giving up, and steering a worker
  # that is still going would interrupt real work.
  cy=$(write_pane "$pane" bare "" \
    '  ⎿  API Error: 529 overloaded_error' \
    '● Retrying…')
  arm_claude_task "$state" busy "$window" busy user-prompt-submit
  # An episode left over from an earlier stall. A resumed worker spends most of
  # its polls busy, so if a busy poll did not clear the episode it would never
  # close, and a stall hours later would inherit a half-spent ladder.
  printf '%s class=overload attempts=2 next=1 first=1 last=1 escalated=0 quiet=0 sent=0\n' \
    "$FM_STALL_LIB_VERSION" > "$state/busy.stall"
  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  local pid=$!
  # Wait for the clear to land rather than sleeping a guessed interval: a busy
  # poll must stamp quiet on the open episode, and on a loaded machine the
  # watcher's first poll can legitimately land many seconds after launch.
  local i quiet="" ok=""
  for i in $(seq 1 200); do
    quiet=$(fm_stall_field "$state" busy quiet)
    if [ -n "$quiet" ] && [ "$quiet" != 0 ]; then ok=1; break; fi
    sleep 0.1
  done
  [ "$ok" = 1 ] || { reap "$pid"; fail "a producing worker did not clear its open stall episode: $(cat "$out")"; }
  [ ! -s "$dir/sent.log" ] || { reap "$pid"; fail "a pane whose worker is still mid-turn was auto-resumed"; }
  [ "$(fm_stall_field "$state" busy attempts)" = 2 ] \
    || { reap "$pid"; fail "clearing an episode discarded its spent attempts"; }
  reap "$pid"
  pass "a pane whose worker is still working is never auto-resumed, and clears any open episode"
}

test_a_pane_with_text_already_in_its_composer_is_never_resumed() {
  local dir state window pane out cy
  dir=$(make_stall_case pending-composer); state="$dir/state"
  window="test:fm-pending"; pane="$dir/pane.txt"; out="$dir/watch.out"
  # The bordered shape is the one where a stall can genuinely hug a composer
  # that is not empty: the typed text lives inside the box, so the banner above
  # the box still hugs it and the classification fires. Whether the interior
  # blocks the resume is the composer gate's call, asserted below.
  cy=$(write_pane "$pane" boxed "please rerun the failing case" \
    '  ⎿  API Error: 529 overloaded_error')
  arm_claude_task "$state" pending "$window" idle stop-failure
  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  local pid=$!
  [ ! -s "$dir/sent.log" ] || { reap "$pid"; fail "a pane with text already typed was auto-resumed"; }
  [ ! -e "$state/pending.stall" ] || { reap "$pid"; fail "a pane with text already typed opened an episode"; }
  wait_for_grep 'auto-resume declined for pending' "$state/.watch-triage.log" 300 \
    || fail "the composer gate did not record why it declined: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  # The decline is a transition, not a per-poll event. The stale path ends this
  # watcher, and the daemon relaunches it over the same state for as long as the
  # pane stays declined, so the suppression has to hold across relaunches: a
  # limit window that runs for hours would otherwise flood the size-capped
  # triage log one line per poll.
  wait "$pid" 2>/dev/null || true
  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  pid=$!
  sleep 3
  [ "$(grep -c 'auto-resume declined for pending' "$state/.watch-triage.log")" = 1 ] \
    || { reap "$pid"; fail "the same composer decline was logged again on a later poll: $(cat "$state/.watch-triage.log")"; }
  reap "$pid"
  # A different stall class behind the same held composer is a new transition
  # and is logged exactly once more. The held composer keeps its boxed shape:
  # in the bare shape its typed text is the last substantive row, and the
  # adjacency walk correctly refuses to reach a banner floating above it.
  cy=$(write_pane "$pane" boxed "please rerun the failing case" \
    "You've hit your usage limit · resets 11pm")
  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  pid=$!
  wait_for_grep 'auto-resume declined for pending (limit stall' "$state/.watch-triage.log" \
    || { reap "$pid"; fail "a changed stall class was not logged as a new decline: $(cat "$state/.watch-triage.log")"; }
  sleep 3
  [ "$(grep -c 'auto-resume declined for pending' "$state/.watch-triage.log")" = 2 ] \
    || { reap "$pid"; fail "the decline log did not settle at one line per transition: $(cat "$state/.watch-triage.log")"; }
  [ ! -s "$dir/sent.log" ] || { reap "$pid"; fail "a pane with text already typed was auto-resumed: $(cat "$dir/sent.log")"; }
  reap "$pid"
  pass "a pane with text already in its composer is never auto-resumed, and the decline is logged once per transition"
}

test_a_reused_window_logs_a_fresh_decline_for_its_new_task() {
  local dir state window pane out cy
  dir=$(make_stall_case reused-window); state="$dir/state"
  window="test:fm-reused"; pane="$dir/pane.txt"; out="$dir/watch.out"
  cy=$(write_pane "$pane" boxed "please rerun the failing case" \
    '  ⎿  API Error: 529 overloaded_error')
  arm_claude_task "$state" firsttask "$window" idle stop-failure
  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  local pid=$!
  wait_for_grep 'auto-resume declined for firsttask' "$state/.watch-triage.log" 300 \
    || { reap "$pid"; fail "the first task's decline was never logged: $(cat "$state/.watch-triage.log" 2>/dev/null)"; }
  wait "$pid" 2>/dev/null || true
  # The window is torn down and reassigned to a new task, same class and
  # composer state (the marker file at .stall-declined-<key> is keyed on the
  # window, not the task, so it survives the reassignment). A stale marker that
  # ignored the task would wrongly suppress the new task's first decline.
  rm -f "$state/firsttask.meta"
  arm_claude_task "$state" secondtask "$window" idle stop-failure
  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  pid=$!
  wait_for_grep 'auto-resume declined for secondtask' "$state/.watch-triage.log" 300 \
    || { reap "$pid"; fail "a window reused by a new task suppressed that task's first decline: $(cat "$state/.watch-triage.log")"; }
  [ ! -s "$dir/sent.log" ] || { reap "$pid"; fail "a pane with text already typed was auto-resumed"; }
  reap "$pid"
  pass "a window reused by a new task logs a fresh decline instead of inheriting the old task's suppression"
}

test_a_recovered_workers_stale_banner_is_never_retriggered() {
  local dir state window pane out cy
  dir=$(make_stall_case buried-banner); state="$dir/state"
  window="test:fm-recovered"; pane="$dir/pane.txt"; out="$dir/watch.out"
  # A worker that already recovered: the old banner is still in its transcript,
  # but its own output now sits between that banner and the composer. Nothing
  # may be delivered, and because classification reads none, no episode is even
  # opened - the ordinary stopped-crew supervision owns an idle pane like this.
  cy=$(write_pane "$pane" bare "" \
    '  ⎿  API Error: 529 overloaded_error' \
    'the fix landed and all checks are green' \
    'line two of ordinary output')
  arm_claude_task "$state" recovered "$window" idle stop-failure
  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  assert_never_resumed "$dir" "$state" recovered $! "a recovered worker whose transcript still shows a banner"
  pass "a banner buried above later output never retriggers a recovered worker"
}

test_a_pane_unchanged_since_the_last_delivery_is_not_nudged_again() {
  local dir state window pane out cy sent count
  dir=$(make_stall_case unchanged-skip); state="$dir/state"
  window="test:fm-static"; pane="$dir/pane.txt"; out="$dir/watch.out"; sent="$dir/sent.log"
  cy=$(write_pane "$pane" bare "" '  ⎿  API Error: 529 overloaded_error')
  arm_claude_task "$state" static "$window" idle stop-failure
  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  local pid=$!
  wait_for_file "$sent" 300 || { reap "$pid"; fail "the stalled pane was never resumed at all: $(cat "$out")"; }
  # The ladder is compressed to one second, so within a few more polls the next
  # rung comes due against the SAME bytes: the re-trigger guard must refuse it
  # instead of typing into a pane the last steer visibly never moved. Wait for
  # that refusal rather than sleeping a guessed interval.
  local i refused=""
  for i in $(seq 1 200); do
    if grep -q 'pane unchanged since the last attempt' "$state/.watch-triage.log" 2>/dev/null; then
      refused=1
      break
    fi
    [ "$(wc -l < "$sent" | tr -d ' ')" = 1 ] || break   # an extra delivery: judged below
    sleep 0.1
  done
  reap "$pid"
  count=$(wc -l < "$sent" | tr -d ' ')
  [ "$count" = 1 ] || fail "an unchanged pane was nudged $count times, not once: $(cat "$sent")"
  [ "$refused" = 1 ] \
    || fail "the refusal was not recorded: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  pass "a byte-identical pane receives one delivery, and further due rungs are refused"
}

test_a_non_claude_pane_is_never_resumed() {
  local dir state window pane out cy
  dir=$(make_stall_case other-harness); state="$dir/state"
  window="test:fm-codex"; pane="$dir/pane.txt"; out="$dir/watch.out"
  cy=$(write_pane "$pane" bare "" '  ⎿  API Error: 529 overloaded_error')
  fm_write_meta "$state/codexy.meta" "window=$window" "backend=tmux" "kind=ship" "harness=codex"
  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  assert_never_resumed "$dir" "$state" codexy $! "a codex pane"
  pass "a pane on another harness is left entirely unchanged"
}

test_switching_auto_resume_off_leaves_the_pane_alone() {
  local dir state window pane out cy
  dir=$(make_stall_case switched-off); state="$dir/state"
  window="test:fm-off"; pane="$dir/pane.txt"; out="$dir/watch.out"
  cy=$(write_pane "$pane" bare "" '  ⎿  API Error: 529 overloaded_error')
  arm_claude_task "$state" offtask "$window" idle stop-failure
  printf 'off\n' > "$dir/config/auto-resume"
  stall_watch_bg "$dir" "$window" "$pane" "$cy" "$out"
  assert_never_resumed "$dir" "$state" offtask $! "a home with auto-resume switched off"
  pass "a home that switched auto-resume off keeps the previous behavior exactly"
}

test_overload_banners_classify_with_their_status_code
test_limit_banners_classify_with_a_parsed_reset_time
test_the_observed_session_limit_banner_parses
test_a_reset_that_already_passed_does_not_park_the_worker_for_a_day
test_a_limit_banner_outranks_an_overload_banner
test_an_untimed_limit_still_classifies_but_carries_no_reset
test_displayed_content_without_error_framing_is_not_a_stall
test_a_banner_must_hug_the_composer
test_the_banner_scan_window_is_bounded
test_unparseable_reset_times_degrade_to_no_reset
test_leading_zero_reset_times_parse_in_base_ten
test_backoff_ladder_is_bounded_and_repeats_its_last_rung
test_auto_resume_is_default_on_for_claude_only
test_an_episode_walks_the_ladder_then_escalates_once
test_an_escalated_episode_whose_stall_returns_never_rearms
test_an_episode_survives_a_brief_clear_and_restarts_after_a_long_one
test_a_still_showing_stall_is_never_marked_clear
test_a_limit_episode_schedules_its_first_attempt_for_the_reset
test_a_damaged_or_foreign_record_reads_as_a_fresh_episode
test_a_class_change_keeps_the_ladder_position
test_an_unchanged_pane_refuses_a_due_resume
test_an_overloaded_pane_is_resumed_without_waking_the_supervisor
test_a_usage_limit_pane_waits_for_its_reset_instead_of_resuming
test_a_spent_ladder_surfaces_one_stale_wake_carrying_its_history
test_a_working_pane_is_never_resumed
test_a_pane_with_text_already_in_its_composer_is_never_resumed
test_a_reused_window_logs_a_fresh_decline_for_its_new_task
test_a_recovered_workers_stale_banner_is_never_retriggered
test_a_pane_unchanged_since_the_last_delivery_is_not_nudged_again
test_a_non_claude_pane_is_never_resumed
test_switching_auto_resume_off_leaves_the_pane_alone
