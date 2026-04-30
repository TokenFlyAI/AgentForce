# AgentForce

An adversarial verification system for AI agents, implemented as a Claude Code slash command.

The Orchestrator (Claude itself, using Claude Code's built-in planning) maintains a **Running Tree** of hypotheses and spawns two kinds of isolated sub-agents: an **Executor** that does the work, and a **Verifier** that does not know the task and only fact-checks the Executor's literal claims. A step passes only when the Verifier cannot break it.

---

## Try It Now

Install in one command:

```bash
curl -fsSL https://raw.githubusercontent.com/TokenFlyAI/AgentForce/main/install.sh | bash
```

Then in any Claude Code project:

```
/agentforce <your task>
```

Re-run the install command any time to update. See [Installation](#installation) for alternative install paths.

---

## The Problem

Standard AI agents have a fundamental flaw: they generate answers and declare success themselves.

| Problem | Symptom |
|---|---|
| Self-certification | Agent announces "done" — no external check |
| Fake verification | "Looks correct", "should work" — no evidence |
| No course correction | Wrong direction → keeps going anyway |
| Repeated failures | Same mistake made again |
| Single-shot | Complex tasks cause the agent to collapse |

**Root cause**: agents have generation capability, but no execution and verification system.

---

## Two Core Features

### ⚔️ Zero-Context Adversarial Loop

The Executor and the Verifier are not two modes of one agent — they are **two freshly spawned sub-agents with completely separate context windows**, set against each other. The Orchestrator controls exactly what each one sees.

| | Executor | Verifier |
|---|---|---|
| Knows the task? | ✅ Yes — needs context to do the work | ❌ **No** — only sees the literal claim |
| Knows the hypothesis? | ✅ Yes | ❌ No |
| Knows prior history? | Recent steps only | ❌ No |
| Job | Execute the step, state a concrete claim | Falsify the claim |

The Verifier not knowing the task is the strongest part. A Verifier that knows the task will rationalize:

> *"The test fails, but maybe the broader goal is X, so it's still progress…"*

By stripping task context, the Verifier becomes a pure fact-checker: *is this literal claim true, yes or no?* This forces the Executor to make claims that are concretely checkable in isolation — not *"the bug is fixed"* but *"`pytest tests/auth.py` exits 0 with 12 passed tests"*.

The Verifier attacks with real execution: running the command, diffing the file, hitting the API. Phrases like *"looks correct"* and *"should work"* are banned. Evidence is required.

### 🌳 Running Tree

A tree of hypotheses, **stored as a markdown file** so Claude can read the entire tree at a glance. Branching can happen at any step — when a path fails, the system backtracks to the nearest ancestor and tries a sibling branch instead of restarting.

```markdown
## plan_a — "Redirect handler is broken" [active]
- ✅ a_s1 — reproduce login failure
- ❌ a_s2 — patch redirect handler [retries 2/2 exhausted]
  - 🔄 a_s2b — try middleware bypass [CURRENT]

## plan_b — "Cookie handling" [untried]
## plan_c — "Session expiry" [untried]
```

Markdown was chosen deliberately. JSON encodes a tree as parent/children pointers — Claude has to mentally walk references to see structure. Markdown shows the tree visually, with status icons, claims, and verifier evidence inline. The Orchestrator (Claude itself, using Claude Code's built-in planning) reads and rewrites this file every iteration. Steps are generated **lazily** — one at a time after the previous step is verified — so the tree shape is determined by what is learned, not pre-committed.

---

> **🧠 Plus one more (additional, not essential): the Thinker.**
> Every 10 iterations, AgentForce spawns a third sub-agent — the Thinker — for first-principles review. Unlike the Executor/Verifier pair (which run every step and are non-negotiable), the Thinker is **advisory and periodic**: it reads the full history, suggests pivots and out-of-box angles, and drafts roadmap items aligned to the goals. The Orchestrator may incorporate, defer, or dismiss. Details below in [The Thinker](#the-thinker--periodic-first-principles-review).

---

## The Idea

Transform agents from "answer generators" into "search systems":

```
Old:  generate answer → self-declare complete

New:  propose hypothesis → execute step → adversarial verification
                                                    ↓
                                        PASS → advance in Running Tree
                                        FAIL → navigate / reshape the tree
```

Every Verifier result drives how the tree evolves:

```
FAIL + retries left      →  Retry        same step, different method
FAIL + retries exhausted →  New Branch   sibling node with a different approach
FAIL + branch exhausted  →  Backtrack    walk up the tree, try from a higher node
FAIL + plan exhausted    →  New Plan     generate a new hypothesis, informed by what failed
```

**Example** — task: *"Users can't log in after the auth refactor"* — final state of `running-tree.md`:

```markdown
# Running Tree

**Task:** Users can't log in after the auth refactor
**Status:** done
**Iteration:** 7

## plan_b — "Session cookie is not being set" [done]

- ✅ b_s1 — reproduce login failure
  *verifier:* curl /login returns 401
- ✅ b_s2 — trace Set-Cookie header in /login response
  *verifier:* response has no Set-Cookie header
- ✅ b_s3 — fix Set-Cookie in auth handler
  *verifier:* response now contains Set-Cookie: session=...; HttpOnly
- ✅ b_s4 — end-to-end login test
  *verifier:* curl /login returns 200, subsequent /me returns 200 with user data

## plan_c — "CORS policy blocking credentials" [untried]

---

## Abandoned plans

- **plan_a — "JWT token validation is broken"**
  Reason: JWT decode logic verified valid; signature also valid;
  patches to expiry and signature both confirmed by Verifier as having
  no effect on the actual failure. Login still 401 → JWT not the cause.
```

Plan A's abandoned-section evidence ("decode and signature both valid; login still 401") directly informed the Orchestrator's switch to Plan B. The tree searched where it needed to, stopped when it found a verified path, and never touched Plan C.

**Core principle**: don't let the agent prove itself right — let the system try to prove it wrong. Only results that survive attack are accepted, and every failure actively reshapes the search.

---

## The Thinker — Periodic First-Principles Review

Every **10 iterations**, AgentForce spawns a third sub-agent: the **Thinker**. Unlike the Executor (does work) and Verifier (attacks claims), the Thinker steps back and reviews the entire run from first principles:

- Is the current trajectory the most efficient path to the goals?
- What blind spots is the Orchestrator missing?
- What out-of-box angles haven't been tried?
- What roadmap items naturally follow the current goals?

The Thinker has **full context** — task, goals, complete running tree, all verifier evidence, and prior thinker notes (so it doesn't repeat itself). Its output is appended to `.agentforce/thinker-notes.md` and read by the Orchestrator at the next THINK phase.

Crucially, **the Thinker is advisory, not authoritative**. Its suggestions are not binding. The Orchestrator decides whether to incorporate, defer, or dismiss — but should pay attention. This is a "second opinion" mechanism: a fresh perspective that catches drift the per-cycle loop can't see, while keeping the verify-driven core intact.

```
.agentforce/thinker-notes.md  (excerpt)

## Thinker Notes (iteration 20)

### Assessment
Plan A's 4 attempts have all failed at the same step. Likely the
hypothesis is wrong, not the implementation.

### Suggestions
- Move plan_a to abandoned. Promote plan_c (CORS) — recent verifier
  evidence at iter 17 showed an OPTIONS preflight failing, which
  plan_a doesn't explain.

### Out-of-box ideas
- The bug may not be in this codebase at all — check the load balancer
  config (nginx.conf) for header stripping.

### Roadmap thoughts (beyond current goals)
- Once login works, the same Set-Cookie path handles refresh tokens.
  Worth a regression test even though it's not in the original task.
```

---

## Goals: The Definition of Done

On init, the Orchestrator extracts **2–6 concrete checkable goals** from the task and writes them to running-tree.md. Each goal is a literal fact you could verify with a command — not vague intent.

```markdown
## Goals (definition of done)
- ⏳ `pytest tests/auth.py` exits 0 with all tests passing
- ⏳ `curl http://localhost:3199/health` returns 200 with body `{"ok": true}`
- ⏳ The `Set-Cookie: session=...` header is present on `/login` 200 response
```

As the Verifier proves goals over time, ⏳ → ✅. A run is **only `done` when every goal is ✅** AND (for multi-step runs) the Final Verifier confirms they all hold simultaneously. This makes the success criteria explicit upfront and gives Phase 6 something concrete to attack.

## THINK Before Execute

Each iteration, before spawning the Executor, the Orchestrator gets a deliberate **THINK** moment:

```
Phase 0 → Phase 1.5 (THINK) → Phase 2 (Executor) → Phase 3 (Verifier) → Phase 4 (state)
```

THINK is where Claude's natural planning happens — review the last Verifier evidence, check which Goals are still ⏳, decide whether to continue with the planned step or pivot. Tools like `TaskList()` and reading `running-tree.md` are **available but not mandatory**: most cycles you just continue, occasionally you reshape. The default is to keep moving; THINK is the moment to pivot when warranted.

This trades a rigid loop for one that can replan mid-flight without breaking the verify cycle's invariants.

---

## Live Planning vs Durable Record

AgentForce uses **two surfaces** for state, separated by purpose:

| | TaskList (Claude Code built-in) | running-tree.md (custom) |
|---|---|---|
| **Role** | Live planning — what's `in_progress` now | Durable record — verified history + tree shape |
| **Audience** | User sees in Claude Code's task UI | Inspect on disk, persists across sessions |
| **Lifecycle** | Per-session; rebuilt from running-tree.md on resume | Persistent; source of truth |
| **Status flow** | `pending → in_progress → completed` | history-only (`✅`/`❌` frozen once written) |
| **Granularity** | The current step | All steps that ever ran, claims, evidence, branches, abandoned plans, live processes |

The Orchestrator uses `TaskCreate` / `TaskUpdate` (with `owner: "agentforce"`) for live planning. **Exactly one** AgentForce task is `in_progress` at any time — that IS the current step. After Verifier passes, the task becomes `completed` and the step moves into the running-tree.md as part of the verified history; a new task is created for the next step.

This means: as a user, you can watch the live spinner in Claude Code's task UI without parsing markdown, and the running-tree.md captures the full evidence trail you can audit later.

---

## Anti-Drift: The Protocol File

After many iterations, the Orchestrator's context grows. The strict rules ("MUST spawn Verifier for every step", "no PASS without evidence") sit far back in context and can drift — the model may start skipping the Verifier or self-certifying near the end of a long task.

**Defense:** the critical rules live in a separate file (`.agentforce/protocol.md`) that the Orchestrator **re-reads at the start of every iteration**. Even if the conversation context is compacted, a fresh file read restores the rules verbatim.

```
Phase 0 (every iteration):     read .agentforce/protocol.md
Phase 1.5 (every iteration):   THINK — pivot, replan, or continue
Phase 6 (conditional, before done):  final adversarial Verifier on the overall outcome
                                     — fires only on multi-step / branched / multi-plan runs;
                                       single-step tasks rely on the per-step Verifier
```

The protocol explicitly anticipates the failure modes ("forbidden drift modes") and forces a self-check before any state.md write: did I spawn an Executor *and* a Verifier this iteration via `Agent()` calls?

---

## Persistent Processes

Some steps need to start things that **must outlive the iteration that started them** — a game server you'll iterate on, a watcher, a daemon. By default, processes started inside a sub-agent are tied to that sub-agent's lifecycle and get killed when it ends. AgentForce handles this with two patterns:

| Pattern | When | How |
|---|---|---|
| **One-shot** (default) | Tests, builds, file ops, scripts that run-then-exit | Plain `Bash` |
| **Persistent** | Servers, daemons, watchers that must outlive the iteration | `setsid nohup ... &; disown` + manifest at `.agentforce/processes/<name>.json` |

The Executor decides **per-command**, not per-run. Within one `/agentforce` invocation iter 3 might use the persistent pattern to start a server, iter 4 might use the one-shot pattern to curl the server, iter 5 might one-shot a test, iter 7 might persist a worker.

Persistent processes survive the Executor sub-agent, the Orchestrator, and the entire `/agentforce` run. A future `/agentforce` invocation reads `.agentforce/processes/*.json`, verifies the PIDs are still alive, and surfaces them in the "Live processes" header of running-tree.md so the next Executor knows what's already running.

```
.agentforce/
├── protocol.md                      ← anti-drift rules (re-read each iter)
├── running-tree.md                  ← the tree + Live processes header
└── processes/
    ├── game-server.json             ← manifest (pid, port, log, purpose)
    ├── game-server.pid
    └── game-server.log              ← detached stdout/stderr
```

---

## How It Runs

```
Orchestrator  (Claude itself, running the /agentforce skill)
    │   plans, decides, maintains state — does NOT execute
    │
    ├── Running Tree  (.agentforce/running-tree.md, plain markdown)
    │       ├── Goals (definition of done)
    │       ├── plan_a  (hypothesis 1)
    │       │     └── step_1 ── step_2a
    │       │                └── step_2b  ← branch on failure
    │       ├── plan_b  (hypothesis 2)
    │       └── plan_c  (hypothesis 3)
    │
    ├── Executor sub-agent     (fresh context, KNOWS the task)
    │       └── executes one step, returns a concrete factual claim
    │
    ├── Verifier sub-agent     (fresh context, does NOT know the task)
    │       └── attacks the literal claim, returns pass/fail + evidence
    │
    └── Thinker sub-agent      (every 10 iters, full context, advisory)
            └── first-principles review → suggestions, out-of-box ideas, roadmap
```

Every loop: Orchestrator reads protocol → THINKs → spawns Executor → spawns Verifier → checks off goals → rewrites the markdown with updates → loops. Every 10 iterations, Thinker runs first to provide strategic advice. State is fully persisted between iterations and human-readable at any time.

---

## Installation

Requires [Claude Code](https://claude.ai/code). Pick whichever path you prefer.

### One-line install script (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/TokenFlyAI/AgentForce/main/install.sh | bash
```

The script puts `agentforce.md` into `~/.claude/commands/` so `/agentforce` works in any directory. Re-run to update.

### Direct file download (one curl, no script)

```bash
mkdir -p ~/.claude/commands && \
curl -fsSL https://raw.githubusercontent.com/TokenFlyAI/AgentForce/main/.claude/commands/agentforce.md \
  -o ~/.claude/commands/agentforce.md
```

### For contributors (clone + symlink)

```bash
git clone https://github.com/TokenFlyAI/AgentForce.git ~/AgentForce
mkdir -p ~/.claude/commands
ln -sf ~/AgentForce/.claude/commands/agentforce.md ~/.claude/commands/agentforce.md
```

Edit the cloned file to iterate — the symlink keeps it in sync globally.

---

## Usage

```
/agentforce <task description>
```

**Example:**
```
/agentforce Fix the failing test in auth.py
```

**What happens:**

```
[Iter 1] hyp="JWT validation broken" / step="reproduce failure" → PASS
         claim: "pytest tests/auth.py::test_login exits 1 with AssertionError"
         verifier: confirmed via pytest run

[Iter 2] hyp="JWT validation broken" / step="patch token expiry" → FAIL
         claim: "test_login now passes"
         verifier: ran pytest, test still fails (AssertionError unchanged)

[Iter 3] switching hypothesis: JWT decode logic is valid; failure is elsewhere
         new current: "Cookie not set"

[Iter 4] hyp="Cookie not set" / step="fix Set-Cookie in auth handler" → PASS
         claim: "curl /login response includes Set-Cookie: session=...; HttpOnly"
         verifier: confirmed via curl -i

[Iter 5] hyp="Cookie not set" / step="run full test suite" → PASS
         claim: "pytest exits 0 with 42 passed"
         verifier: confirmed

✅ DONE
```

**Resuming a session:** state lives in `.agentforce/running-tree.md`. Run `/agentforce` again to continue.

---

## State File

Inspect the Running Tree at any time — it's just markdown:

```bash
cat .agentforce/running-tree.md
```

```markdown
# Running Tree

**Task:** Build and verify a multiplayer game server
**Status:** executing
**Iteration:** 5

## Goals (definition of done)
- ✅ `node game.js` starts a process listening on port 3199
- ✅ `curl http://localhost:3199/health` returns 200
- ⏳ Two `wscat -c ws://localhost:3199` clients can connect simultaneously
- ⏳ State sent by client A is received by client B within 100ms

## Live processes
- 🟢 **game-server** (pid 12345, port 3199) — started iter 3, log: .agentforce/processes/game-server.log

## plan_a — "Build with Node + ws" [active]

- ✅ a_s1 — scaffold project
  *claim:* package.json contains ws@^8 dependency
  *verifier:* confirmed via cat
- ✅ a_s2 — implement game.js
  *claim:* file game.js exists with ~120 lines
  *verifier:* confirmed via wc -l
- ✅ a_s3 — start server (Pattern 2 persistent process)
  *claim:* pid 12345 listening on port 3199
  *verifier:* confirmed via kill -0 and curl

(current step is in TaskList: "Connect two test clients" — in_progress)
```

The whole file is human-readable — you can follow exactly what the agent has tried, what worked, what failed, what processes are still alive, and where it is now.

---

## Implementation Phases

| Phase | Scope | Status |
|---|---|---|
| **1** | Executor + Verifier adversarial loop with isolated context | ✅ Skill implemented |
| **2** | Running Tree managed by Orchestrator, hypothesis switching | ✅ Skill implemented |
| **3** | Stronger Level-1 verification: sandboxed execution, test runner integration | 🔜 Planned |
| **4** | Failure pattern analytics, multi-task memory across sessions | 🔜 Planned |

---

## File Structure

```
AgentForce/
├── .claude/
│   └── commands/
│       └── agentforce.md    ← the /agentforce slash command (Orchestrator)
├── PLAN.md                  ← design document
└── README.md
```

At runtime, the working directory gets:
```
.agentforce/
├── protocol.md              ← anti-drift rules, re-read every iteration
├── running-tree.md          ← live state: goals, tree, claims, evidence, live processes
├── thinker-notes.md         ← periodic first-principles advice (every 10 iters)
└── processes/               ← persistent process manifests + logs (if any)
    ├── <name>.json
    ├── <name>.pid
    └── <name>.log
```

---

## Design Constraints

1. **Verifier has no task context** — it only verifies a literal factual claim
2. **Executor must produce checkable claims** — "the bug is fixed" is rejected; "`pytest` exits 0 with N passed" is accepted
3. **Orchestrator does not execute** — it plans (using Claude Code's built-in TaskList + reasoning), decides, and writes state; all concrete actions go through sub-agents
4. **Live planning via built-in TaskList** — `TaskCreate` / `TaskUpdate` (owner: "agentforce") for the current step; exactly one task `in_progress` at any time
5. **Durable record via running-tree.md** — append-only verified history, branching tree, abandoned plans, live processes
6. **Two Agent() calls per step, every step** — Executor + Verifier; enforced by self-check before any state write
7. **Final verification gate before done** — the most common drift point is the finish line; one final adversarial Verifier on the overall outcome blocks the shortcut
8. **Protocol re-read every iteration** — `.agentforce/protocol.md` is read fresh in Phase 0, immune to context compaction
9. **Persistent processes survive sub-agent boundaries** — `setsid` + manifest at `.agentforce/processes/<name>.json`; per-command decision (one-shot vs persistent)
10. **Failed plans carry evidence** — failure reasons from the Verifier become negative examples when generating new plans
11. **Resource ceilings** — `max_retry_per_step: 2`, `max_branches_per_node: 3`, `max_plans: 5`

---

## License

MIT
