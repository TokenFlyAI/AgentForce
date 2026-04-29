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

## Anti-Drift: The Protocol File

After many iterations, the Orchestrator's context grows. The strict rules ("MUST spawn Verifier for every step", "no PASS without evidence") sit far back in context and can drift — the model may start skipping the Verifier or self-certifying near the end of a long task.

**Defense:** the critical rules live in a separate file (`.agentforce/protocol.md`) that the Orchestrator **re-reads at the start of every iteration**. Even if the conversation context is compacted, a fresh file read restores the rules verbatim.

```
Phase 0 (every iteration):  read .agentforce/protocol.md
Phase 1 (first iteration):  write protocol.md alongside running-tree.md
Phase 6 (before done):      run a final adversarial Verifier on the overall outcome
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
Orchestrator  (Claude itself, running the /agentforce skill,
               using Claude Code's built-in planning)
    │   plans, decides, maintains state — does NOT execute
    │
    ├── Running Tree  (.agentforce/running-tree.md, plain markdown)
    │       ├── plan_a  (hypothesis 1)
    │       │     └── step_1 ── step_2a
    │       │                └── step_2b  ← branch on failure
    │       ├── plan_b  (hypothesis 2)
    │       └── plan_c  (hypothesis 3)
    │
    ├── Executor sub-agent     (fresh context, KNOWS the task)
    │       └── executes one step, returns a concrete factual claim
    │
    └── Verifier sub-agent     (fresh context, does NOT know the task)
            └── attacks the literal claim, returns pass/fail + evidence
```

Every loop: Orchestrator reads the markdown tree → picks the current step → spawns Executor → spawns Verifier → rewrites the markdown with updates → loops. State is fully persisted between iterations and human-readable at any time.

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
**Current:** a_s4
**Iteration:** 5

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
- 🔄 a_s4 — connect two test clients [CURRENT]
  *retry:* 0/2
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
├── running-tree.md          ← live state: tree, claims, evidence, live processes
└── processes/               ← persistent process manifests + logs (if any)
    ├── <name>.json
    ├── <name>.pid
    └── <name>.log
```

---

## Design Constraints

1. **Verifier has no task context** — it only verifies a literal factual claim
2. **Executor must produce checkable claims** — "the bug is fixed" is rejected; "`pytest` exits 0 with N passed" is accepted
3. **Orchestrator does not execute** — it plans (using Claude Code's built-in planning), decides, and writes state; all concrete actions go through sub-agents
4. **Two Agent() calls per step, every step** — Executor + Verifier; enforced by self-check before any state.md write
5. **Final verification gate before done** — the most common drift point is the finish line; one final adversarial Verifier on the overall outcome blocks the shortcut
6. **Protocol re-read every iteration** — `.agentforce/protocol.md` is read fresh in Phase 0, immune to context compaction
7. **State is markdown, not JSON** — Running Tree is human-readable, the tree shape is visible at a glance
8. **Persistent processes survive sub-agent boundaries** — `setsid` + manifest at `.agentforce/processes/<name>.json`; per-command decision (one-shot vs persistent)
9. **Failed plans carry evidence** — failure reasons from the Verifier become negative examples when generating new plans
10. **Resource ceilings** — `max_retry_per_step: 2`, `max_branches_per_node: 3`, `max_plans: 5`

---

## License

MIT
