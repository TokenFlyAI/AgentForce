# AgentForce

An adversarial verification system for AI agents, implemented as a Claude Code slash command.

Instead of letting an agent self-certify its work, AgentForce runs a Worker and an adversarial Verifier as isolated sub-agents, managed by an Orchestrator that navigates a Plan Tree. A result only passes when the Verifier cannot break it.

---

## Two Core Features

### ⚔️ Adversarial Verifier

A dedicated agent whose only job is to **break** the Worker's output — not review it.

> Don't let the agent prove itself right. Let the system try to prove it wrong.
> Only results that survive attack are accepted.

The Verifier runs real execution first: tests, diffs, API responses, reproduced failures. If no execution environment exists, it constructs counterexamples and attacks logic. Phrases like *"looks correct"* or *"should work"* are banned — evidence is required.

### 🌳 Plan Tree

A tree of hypotheses where **branching can happen at any step**, not just at the top level. When a path fails, the system backtracks to the nearest ancestor and tries a sibling branch — it does not restart from scratch.

```
root
├── Plan A  (hypothesis: redirect handler)
│   └── Step 1 ── Step 2a  ✗ failed
│             └── Step 2b  ← new branch, different approach
├── Plan B  (hypothesis: cookie)
└── Plan C  (hypothesis: session expiry)
```

Steps are generated **lazily** — one at a time based on what was learned — so the system adapts rather than commits to a fixed plan upfront.

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

## The Idea

Transform agents from "answer generators" into "search systems":

```
Old:  generate answer → self-declare complete

New:  propose hypothesis → execute step → adversarial verification
                                                    ↓
                                        PASS (attack failed) → continue
                                        FAIL (attack succeeded) → fix or switch direction
```

**Core principle**: don't let the agent prove itself right — let the system try to prove it wrong. Only results that survive attack are accepted.

---

## Architecture

```
Orchestrator  (the /agentforce skill)
    │
    ├── Plan Tree  (.agentforce/state.json)
    │       ├── Plan A  (hypothesis 1)
    │       │     └── Step 1 ── Step 2a
    │       │                └── Step 2b  ← branch on failure
    │       ├── Plan B  (hypothesis 2)
    │       └── Plan C  (hypothesis 3)
    │
    ├── Worker sub-agent       (isolated context window)
    │       └── executes one step, returns structured result
    │
    └── Verifier sub-agent     (isolated context window)
            └── attacks the result, returns pass/fail + evidence
```

### Context Isolation

Worker and Verifier are spawned via Claude Code's `Agent` tool — each gets a completely fresh context window. They share nothing. The Orchestrator controls exactly what each sees via the prompt string and reads only their final output. This prevents the Verifier from being anchored to the Worker's reasoning.

---

## Core Features

### 1. Adversarial Execution

The Verifier's job is to **break** the Worker's output, not review it.

**Level 1 — Real execution (preferred):**
- Code written → run the tests, check actual output
- Bug fixed → reproduce the original failure, confirm it's gone
- Files changed → diff them against intent
- API called → inspect the actual return value

**Level 2 — Adversarial reasoning (fallback when no execution environment):**
- Construct concrete counterexamples
- Find unhandled boundary conditions
- Identify logical contradictions

Banned Verifier phrases: *"looks correct"*, *"seems fine"*, *"should work"*, *"likely"*, *"appears to"*. The Verifier must produce evidence, not opinions.

### 2. Plan Tree

A tree structure where branching can occur at any step, not just at the top level. Stored in `.agentforce/state.json` as a flat node map.

```
root
├── plan_a  ← hypothesis 1
│   └── a_s1 (passed)
│       ├── a_s2a (failed)  ← tried, dead end
│       └── a_s2b (active)  ← new branch generated on failure
├── plan_b  ← hypothesis 2
└── plan_c  ← hypothesis 3
```

Steps are generated **lazily** — one at a time, based on what was learned from the previous step. This avoids committing to a full plan upfront.

### 3. Four Recovery Mechanisms

| Mechanism | Trigger | Action |
|---|---|---|
| **Retry** | Step fails, retry count < max | Same step, different method |
| **New Branch** | Retries exhausted | Generate sibling step with different approach, same parent |
| **Backtrack** | All branches at a node exhausted | Walk up tree, find nearest ancestor with branch capacity |
| **New Plan** | Entire plan subtree exhausted | Mark plan failed (with reason), generate new hypothesis |

Failed plans and their failure reasons are fed as negative examples when generating new hypotheses — the system learns which directions not to revisit.

### 4. Orchestrator State Machine

```
INIT → PLANNING → EXECUTING → DONE
                      │
                   STUCK  (all plans exhausted)
```

Every state transition is written to `state.json` immediately. The tree is fully inspectable at any point:

```bash
cat .agentforce/state.json
```

---

## Installation

Requires [Claude Code](https://claude.ai/code).

**Project-level** (only available in this directory):
```bash
git clone https://github.com/TokenFlyAI/AgentForce.git
cd AgentForce
```
Claude Code will pick up `.claude/commands/agentforce.md` automatically.

**Global** (available in every directory):
```bash
git clone https://github.com/TokenFlyAI/AgentForce.git ~/your/path/AgentForce
mkdir -p ~/.claude/commands
ln -sf ~/your/path/AgentForce/.claude/commands/agentforce.md ~/.claude/commands/agentforce.md
```

Now `/agentforce` works in any directory. Edit the cloned file to iterate — the symlink keeps it in sync globally.

---

## Usage

Open Claude Code in your project directory and run:

```
/agentforce <task description>
```

**Example:**
```
/agentforce Fix the failing test in auth.py
```

**What happens:**

```
[Iter 1] Generating Plan Tree: 3 hypotheses
[Iter 2] plan_a / a_s1 (reproduce bug) → PASS ✓  (L1: test confirmed failing)
[Iter 3] plan_a / a_s2a (patch redirect) → FAIL — retry 1/2
[Iter 4] plan_a / a_s2a → FAIL — new branch a_s2b
[Iter 5] plan_a / a_s2b (fix cookie) → PASS ✓  (L1: all tests green)
[Iter 6] plan_a / a_s3 (full suite) → PASS ✓  (L1: 42/42)

✅ DONE
Winning path: plan_a → a_s1 → a_s2b → a_s3
Total iterations: 6  |  Dead ends: 1
```

**Resuming a session:**

State is persisted in `.agentforce/state.json`. If a session is interrupted, just run `/agentforce` again in the same directory — it resumes from where it left off.

---

## State File

The Plan Tree is fully transparent. Inspect it any time:

```bash
cat .agentforce/state.json
```

```json
{
  "task": "Fix the failing test in auth.py",
  "status": "executing",
  "current_node": "a_s2b",
  "nodes": {
    "root": { "children": ["plan_a", "plan_b", "plan_c"], "tried": [] },
    "plan_a": { "hypothesis": "cookie handling is broken", "status": "active" },
    "a_s1": { "status": "passed", "verification_evidence": "test confirmed failing" },
    "a_s2a": { "status": "failed", "failure_reason": "test still red after patch" },
    "a_s2b": { "status": "pending", "retry_count": 0 }
  }
}
```

---

## Implementation Phases

| Phase | Scope | Status |
|---|---|---|
| **1** | Worker + Verifier adversarial loop, single plan, retry | ✅ Skill implemented |
| **2** | Full Plan Tree with backtracking, plan switching | ✅ Skill implemented |
| **3** | Level 1 real verification — bash sandbox, test runner | 🔜 Planned |
| **4** | Persistence, visualization, failure pattern analytics | 🔜 Planned |

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

At runtime, the task directory gets:
```
.agentforce/
└── state.json               ← live Plan Tree state
```

---

## Design Constraints

1. Verifier never reads Worker's `confidence` field — it must form an independent judgment
2. Step results must be reproducible — "the side effect already happened" is not evidence
3. Every plan failure is recorded with a reason — fed as negative examples to future plan generation
4. Orchestrator sees only structured output from sub-agents, never their internal reasoning
5. Resource limits: `max_retry_per_step: 2`, `max_branches_per_node: 3`, `max_depth: 8`, `max_plans: 5`

---

## License

MIT
