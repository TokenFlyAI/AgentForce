# AgentForce

An adversarial verification system for AI agents, implemented as a Claude Code slash command.

The Orchestrator (Claude itself, using Claude Code's built-in planning) maintains a **Running Tree** of hypotheses and spawns two kinds of isolated sub-agents: an **Executor** that does the work, and a **Verifier** that does not know the task and only fact-checks the Executor's literal claims. A step passes only when the Verifier cannot break it.

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

**Task:** Fix the failing test in auth.py
**Status:** executing
**Current:** a_s2b
**Iteration:** 4

## plan_a — "Cookie handling is broken" [active]

- ✅ a_s1 — reproduce login failure
  *claim:* curl /login returns 401
  *verifier:* confirmed via curl -i, status code 401
- ❌ a_s2 — patch redirect handler [retries 2/2 exhausted]
  *failure:* test still red after patch
  - 🔄 a_s2b — try Set-Cookie header in auth handler [CURRENT]
    *retry:* 0/2

## plan_b — "Session expiry mismatch" [untried]
## plan_c — "CORS blocking credentials" [untried]
```

The whole file is human-readable — you can follow exactly what the agent has tried, what worked, what failed, and where it is now.

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
└── running-tree.md          ← live state: tree of plans, steps, claims, evidence
```

---

## Design Constraints

1. **Verifier has no task context** — it only verifies a literal factual claim
2. **Executor must produce checkable claims** — "the bug is fixed" is rejected; "`pytest` exits 0 with N passed" is accepted
3. **Orchestrator does not execute** — it plans (using Claude Code's built-in planning), decides, and writes state; all concrete actions go through sub-agents
4. **State is markdown, not JSON** — Running Tree is human-readable, the tree shape is visible at a glance, and Claude reads it without parsing pointers
5. **State writes happen every iteration** — Running Tree is always inspectable and resumable
6. **Failed plans carry evidence** — failure reasons from the Verifier become negative examples when generating new plans
7. **Resource ceilings** — `max_retry_per_step: 2`, `max_branches_per_node: 3`, `max_plans: 5`

---

## License

MIT
