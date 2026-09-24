---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Updates this firstmate repo's default branch and every local or remote secondmate through its guarded convergence path (never forced, never disruptive), then re-reads AGENTS.md and restarts every live second mate through the persist-gated restart, with a fallback re-read nudge only where a restart cannot be proven.
  On a fork it also checks the community `upstream` remote and reports when a merge is needed, without merging.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

Pulling the files is only half of it.
A running agent holds `AGENTS.md` and every skill it has already loaded frozen from the moment it launched, and no verified harness offers a reload, so new bytes on disk change nothing for it until it starts a fresh conversation.
A re-read cannot substitute: it appends a second copy of the mate's own job description with no defined precedence, and it cannot reach a skill that is already loaded.
Replacing the agent is also the only thing that re-resolves the launch-time wiring - turn-end hooks, harness flags, per-harness feature switches - which the mate froze when it started and which nothing on disk describes.

That is why **every live second mate is restarted after a successful update, including one that was already on the target commit.**
Launch-time wiring is not derivable from a file diff, so an unchanged tracked surface is not evidence the running agent is already on the current behavior.
The only live mates that do not restart are the ones whose home the update pass had to skip, and the ones whose runtime cannot prove a restart; the updater keeps both cases honest and neither is reported as a reload.

**One-time rollout note:** the update that carries this change is still executed by the previous release, which restarts only the mates whose `AGENTS.md` or `.agents/skills/` moved on that pass. After it completes, run `bin/fm-secondmate-restart.sh <fm-id>...` once with every live second mate ID, not only the ones that release named; later updates follow the normal flow below.

The primary update is fast-forward only, while each secondmate uses the same guarded convergence path plus one narrow recovery for squash-merged local history.
For a remote route, it updates the configured Firstmate code root on that host from its own origin, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never creates a merge commit, and never stashes.
A clean secondmate divergence advances with `reset --keep` only when a three-way tree proof shows its complete local result is already present at the target, which recognizes squash-merged contributions without discarding unique content.
Every other dirty, diverged, offline, or wrong-branch target is skipped and reported, and a genuine divergence leaves a durable `state/.secondmate-update-reconcile/<id>.pending` record that future bootstrap and update passes surface until convergence clears it.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

**Forks and the community upstream.**
Following origin is not enough on a fork, because origin is the fork itself and can never carry a community change.
When the repo has an `upstream` remote that names a different repository, the updater also fetches it and compares the primary with upstream's default branch on every run.
That comparison is read-only: it counts commits, predicts whether the merge would be clean, and never merges, fast-forwards, stashes, or moves HEAD.
A catch-up on a fork with local commits is a real merge, and it belongs on a task branch delivered through the fork's own PR path, where conflicts are judged on the rule that local customizations win and merges are never rebased; doing it inside the live primary checkout could strand the running session mid-conflict.
Secondmates keep following origin, so community changes reach them only after such a merge has landed there.
A repo with no `upstream` remote, or one that points at the same repository as origin, prints nothing extra and behaves exactly as before.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from origin, then updates every registered local or remote secondmate home through its placement-specific guarded path.
   It prints one status line per target (`updated <old>..<new>` / `reconciled redundant divergence <old>..<new>` / `already current` / `skipped: <reason>`), followed by the action lines that tell you exactly what to do next.
   A `skipped: dirty working tree (...)` line names what made the target dirty (modified versus untracked, and the first few paths), so say those paths rather than only "dirty".
   On a fork the primary also gets a `firstmate upstream: ...` line and an extra action line:
   - `upstream-merge: needed|none|unchecked` (absent when there is no distinct `upstream` remote)
   The always-present action lines are:
   - `reread-firstmate: yes|no`
   - `restart-secondmates: fm-<id>...|none`
   - `nudge-secondmates: fm-<id>...|none`

   The two second-mate sets are disjoint and the script owns the split; do not re-derive it.
   `restart-secondmates:` carries every live mate the pass left on the latest commit, whether it advanced or was already there.
   A mate reaches neither set only because its home was skipped, because it has no live endpoint recorded here, or because its endpoint was positively classified as dead or missing.
   A skipped genuine divergence still requires attention through its durable reconciliation record; the other two cases need no update action from you.

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a real `@AGENTS.md` pointer to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

3. **Act on `upstream-merge:` when it is present.**
   - `none` needs nothing.
   - `unchecked` means the community upstream could not be compared (its reason is on the `firstmate upstream:` line, usually an unreachable remote); say so and never read it as up to date.
   - `needed` means the community upstream holds commits this checkout lacks.
     Tell the captain the divergence in plain terms (how many upstream commits are missing, how many local commits the fork carries, and whether the merge is predicted clean or conflicting) and ask whether to start the merge now.
     Do not merge, rebase, or fast-forward in the primary checkout yourself, and do not treat a `needed` result as authority to dispatch on its own.
     On a yes, dispatch one ship task for the firstmate repo (load `firstmate-coding-guidelines` in its instructions): merge `upstream/<default>` onto its task branch with a single merge commit, never rebase, squash, or force, resolve conflicts so local customizations win after understanding what upstream changed, and open a PR against origin whose body documents the upstream changes, each conflict and its resolution, and any feature overlap.
     The merge lands on origin only through that PR and the captain's word on merging it.
   - **After the merge lands**, the ordinary origin update carries it: run `bin/fm-update.sh` again, expect `upstream-merge: none`, and follow steps 2, 4, and 5 for whatever it reports, since a large merge nearly always changes `AGENTS.md`, `bin/`, and `.agents/skills/` under the running session.
     Merged bytes can also raise new tool floors or startup diagnostics, so run `bin/fm-bootstrap.sh` once afterwards and handle anything it prints through the bootstrap diagnostics owner.

4. **Restart every second mate the updater named.**
   Pass the whole `restart-secondmates:` list to one command (skip this step entirely when it says `none`):
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-secondmate-restart.sh <fm-id>...
   ```
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is automatic and needs no per-mate confirmation from the captain.
   Local and remote mates go in the same list; the command owns the transport, the profile each replacement runs on, and the wait.

   It asks every listed mate first to write down the open work it holds only in its conversation, and restarts one only after that mate's own answer comes back.
   A mate that is mid-turn queues the request behind that turn.
   That is the whole point of the step, so do not work around it: it is what keeps a captain call the mate had formed but never registered from being lost with the conversation.
   Its header owns the request, the bound, and the two knobs that change them.

   Read its per-mate lines and its closing `summary:` line as the outcome:
   - `restarted: <id>` - that mate is now genuinely running the current instructions and launch-time settings.
   - `nudged: <id>: <reason>` - the restart was not safe, so the mate got the older re-read message instead and is still running the conversation and launch-time settings it started with.
     Never report one of these as a clean reload.
   - `unreached: <id>: <reason>` - no safe running outcome could be confirmed, including an ambiguous relaunch result.

5. **Send the re-read message to the rest.**
   For every target on the `nudge-secondmates:` line (do nothing when it says `none`), send the one-line re-read steer:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   These are the mates that are on the latest bytes but could not be restarted provably, so the steer is the most this pass can honestly do for them.
   It is a gentle steer, not an interruption: the mate already got a safe tracked-files fast-forward, and the steer never forces, tears down, or discards its work.
   Never describe one of these as reloaded; its agent is still running the wiring it launched with.

6. **Report to the captain in plain outcomes, in one line where you can.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Captain, firstmate and both second mates are now on the latest."
   Say plainly when a mate got the message rather than a clean reload, and why - never let a partial reload read as a full one.
   Include an `upstream-merge: needed` result and the question that goes with it.
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Guarded convergence only.**
  A dirty, offline, non-default, or uniquely diverged target is skipped and reported, never forced or stashed.
  Only a clean secondmate divergence whose complete local result is already present upstream may move without ancestry, and `reset --keep` still refuses conflicting working-tree changes.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **The community upstream is never merged by the updater.**
  It is fetched and compared read-only, and a needed merge goes through a task branch and PR, so a running session is never left mid-conflict and the fork's `main` only moves through its own delivery path.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Nothing with work in it is disrupted.**
  A local or remote second mate gets a tracked-files fast-forward only when its own checkout is safe to advance, and a mate whose home was skipped is not restarted either.
  A restart replaces that mate's agent in the same home and endpoint after its open work is written down; it is never a teardown and never forced.
  Its crewmates keep running in their own endpoints, and every durable record - backlog, held captain calls, unread status, unhandled instructions - is re-presented to the replacement at startup.
  A restart refused before it is attempted leaves that mate on the re-read path; once a relaunch is attempted, any failed or ambiguous result is reported as unknown rather than attributed to either incarnation.
