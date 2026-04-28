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

A tree of hypotheses where **branching can happen at any step**, not just at the top level. When a path fails, the system backtracks to the nearest ancestor and tries a sibling branch — it does not restart from scratch.

```
root
├── Plan A  (hypothesis: redirect handler)
│   └── Step 1 ── Step 2a  ✗ failed
│             └── Step 2b  ← new branch, different approach
├── Plan B  (hypothesis: cookie)
└── Plan C  (hypothesis: session expiry)
```

The Orchestrator is Claude itself — it uses Claude Code's built-in planning capabilities to generate and reshape the tree. Steps are generated **lazily** — one at a time after the previous step is verified — so the tree shape is determined by what is learned, not pre-committed.

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

**Example** — task: *"Users can't log in after the auth refactor"*

```
root
├── Plan A: "JWT token validation is broken"
│   ├── Step 1: reproduce login failure          ✅ PASS
│   ├── Step 2: inspect JWT decode logic         ✅ PASS
│   └── Step 3: patch token expiry check         ❌ FAIL  (Verifier: login still fails in test)
│             └── Step 3b: patch token signature ❌ FAIL  (Verifier: signature valid, not the issue)
│                          ↑ branch exhausted → backtrack → Plan A exhausted
│
├── Plan B: "Session cookie is not being set"     ← new hypothesis from Plan A's failure evidence
│   ├── Step 1: reproduce login failure          ✅ PASS
│   ├── Step 2: trace cookie set-header in logs  ✅ PASS  (Verifier: header missing on /login)
│   ├── Step 3: fix Set-Cookie in auth handler   ✅ PASS  (Verifier: header now present)
│   └── Step 4: end-to-end login test            ✅ PASS  (Verifier: 200 OK + session active)
│                                                          ↑ DONE
│
└── Plan C: "CORS policy blocking credentials"   ← never reached
```

Plan A's failure evidence ("token logic is valid but login still fails") directly informed Plan B's hypothesis. The tree searched where it needed to, stopped when it found a verified path, and never touched Plan C.

**Core principle**: don't let the agent prove itself right — let the system try to prove it wrong. Only results that survive attack are accepted, and every failure actively reshapes the search.

---

## How It Runs

```
Orchestrator  (Claude itself, running the /agentforce skill,
               using Claude Code's built-in planning)
    │   plans, decides, maintains state — does NOT execute
    │
    ├── Running Tree  (.agentforce/running-tree.json)
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

Every loop: Orchestrator picks the current step → spawns Executor → spawns Verifier → applies retry/branch/backtrack/new-plan logic → updates Running Tree → loops. State is fully persisted between iterations.

---

## Installation

Requires [Claude Code](https://claude.ai/code).

**Project-level** (available only in the cloned directory):
```bash
git clone https://github.com/TokenFlyAI/AgentForce.git
cd AgentForce
```
Claude Code picks up `.claude/commands/agentforce.md` automatically.

**Global** (available in every directory):
```bash
git clone https://github.com/TokenFlyAI/AgentForce.git ~/your/path/AgentForce
mkdir -p ~/.claude/commands
ln -sf ~/your/path/AgentForce/.claude/commands/agentforce.md ~/.claude/commands/agentforce.md
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

**Resuming a session:** state lives in `.agentforce/running-tree.json`. Run `/agentforce` again to continue.

---

## State File

Inspect the Running Tree at any time:

```bash
cat .agentforce/running-tree.json
```

```json
{
  "task": "Fix the failing test in auth.py",
  "status": "executing",
  "current_node": "a_s2b",
  "nodes": {
    "root": { "children": ["plan_a", "plan_b", "plan_c"], "tried": [] },
    "plan_a": { "hypothesis": "cookie handling is broken", "status": "active" },
    "a_s1": {
      "status": "passed",
      "executor_claim": "curl /login returns 401",
      "verifier_evidence": "confirmed via curl -i"
    },
    "a_s2a": { "status": "failed", "failure_reason": "test still red after patch" },
    "a_s2b": { "status": "pending", "retry_count": 0 }
  }
}
```

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
└── running-tree.json        ← live state: long_term + history + near_future
```

---

## Design Constraints

1. **Verifier has no task context** — it only verifies a literal factual claim
2. **Executor must produce checkable claims** — "the bug is fixed" is rejected; "`pytest` exits 0 with N passed" is accepted
3. **Orchestrator does not execute** — it plans (using Claude Code's built-in planning), decides, and writes state; all concrete actions go through sub-agents
4. **State writes happen every iteration** — Running Tree is always inspectable and resumable
5. **Failed plans carry evidence** — failure reasons from the Verifier become negative examples when generating new plans
6. **Resource ceilings** — `max_retry_per_step: 2`, `max_branches_per_node: 3`, `max_plans: 5`

---

## License

MIT
