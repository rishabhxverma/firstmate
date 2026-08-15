---
name: task-reflection
description: >-
  Agent-only procedure for folding a finished task's harvested reflection material into durable knowledge.
  Load on a `check: reflection` wake.
user-invocable: false
metadata:
  internal: true
---

# Task reflection fold-in

`bin/fm-teardown.sh` harvests every finished task's reflection material through `bin/fm-reflect.sh` before cleanup destroys the event log, the task metadata, and the isolated copy that reflection reads.
That script owns what is captured and where it lands; this skill owns the only thing it deliberately leaves to an agent, which is deciding what in the capture is worth keeping.

## Procedure

Read the `data/<id>/reflection.md` named by the wake.
It carries the task record, the instructions given, the event log cleanup removed, and the branch history that went away with the isolated copy.

Compare what was asked against what actually happened, and look specifically for what the next task should do differently: where the work stalled, what had to be escalated and why, a question the instructions should have answered up front, a wrong tool or runtime choice, an assumption that cost a rework cycle, and how the change's size compared to its intent.
Ignore the ordinary parts.
A task that ran straight through teaches nothing, and inventing a lesson to have one is worse than recording none.

Route whatever survives that filter by `AGENTS.md` section 6, which is the owner of knowledge placement.
Fleet-local operational facts and gotchas go into this home's `data/learnings.md`, dated and evidence-backed, by rewriting and pruning the existing entries rather than appending forever.
Captain preferences and working style belong in `data/captain.md`.
Knowledge useful to almost every contributor to the project belongs in that project's committed `AGENTS.md`, which only a crewmate may write through the project's delivery path.

Delete `data/<id>/reflection.md` once its content is either recorded or judged not worth keeping.
The capture is working material, not an archive, and leaving it behind turns the task's data directory into a second undecided knowledge store.

## Boundaries

Nothing here authorizes project work.
A reflection may recommend a change; that recommendation is evidence for the backlog, not permission to dispatch or implement.

Do not report a routine fold-in to the captain.
It is internal knowledge upkeep, so it belongs in the next natural reply only when it changed something the captain should know.
