# AgentForce

An adversarial verification system for AI agents, implemented as a Claude Code slash command.

The Orchestrator (Claude itself) maintains a **Running Tree** — recent history, near-future plan, and long-term hypotheses — and spawns two kinds of isolated sub-agents: an **Executor** that does the work, and a **Verifier** that does not know the task and only fact-checks the Executor's literal claims. A step passes only when the Verifier cannot break it.

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

A live three-layer state, **managed by the Orchestrator (Claude itself)**, not a pre-built decision tree.

```
running-tree.json
├── long_term     hypotheses: current, alternatives, abandoned (+ why)
├── history       append-only log of executed steps with claims & evidence
└── near_future   1–3 concrete steps planned next
```

The Orchestrator commits only to the next 1–3 steps. Deeper planning happens inline using Claude's own reasoning — no rigid tree algorithm. The shape of the search emerges from the history of hypotheses tried and abandoned, with each Verifier result reshaping what comes next.

---

## The Idea

Transform agents from "answer generators" into "search systems":

```
Old:  generate answer → self-declare complete

New:  hypothesize → execute → adversarial verify → update Running Tree
                                    ↓
                          PASS → advance, plan next step
                          FAIL → retry, replan, or switch hypothesis
```

Every Verifier result drives how the Running Tree evolves:

```
FAIL + retries left           →  Retry        same step, different method
FAIL + retries exhausted      →  Replan step  replace step in near_future
FAIL + hypothesis seems wrong →  Switch hyp.  abandon current, promote alternative
All hypotheses abandoned      →  Stuck        report what was learned
```

**Example** — task: *"Users can't log in after the auth refactor"*

```
long_term:
  current: "JWT validation is broken"
  alternatives: ["Cookie not set", "CORS blocking credentials"]
  abandoned: []

history:
  iter 1: reproduce login failure          → PASS  ("curl /login returns 401")
  iter 2: inspect JWT decode               → PASS  ("decode logic returns valid claims")
  iter 3: patch token expiry               → FAIL  ("login still 401 after patch")
  iter 4: patch token signature            → FAIL  ("signature already valid, no change")

→ Orchestrator concludes JWT is not the issue. Switch hypothesis.

long_term:
  current: "Cookie not set"
  alternatives: ["CORS blocking credentials"]
  abandoned: [
    { hypothesis: "JWT validation is broken",
      evidence: "decode + signature both valid; login still fails" }
  ]

history (continued):
  iter 5: trace Set-Cookie in /login response  → PASS  ("header missing")
  iter 6: fix Set-Cookie in auth handler        → PASS  ("header now present")
  iter 7: end-to-end login test                 → PASS  ("200 OK, session active")

✅ DONE
```

The abandoned JWT hypothesis directly shaped the switch to "cookie not set." The CORS hypothesis was never explored — the search stopped as soon as a verified path existed.

**Core principle**: don't let the agent prove itself right — let the system try to prove it wrong. Only results that survive attack are accepted, and every failure actively reshapes the search.

---

## How It Runs

```
Orchestrator  (Claude itself, running the /agentforce skill)
    │   plans, decides, maintains state — does NOT execute
    │
    ├── Running Tree  (.agentforce/running-tree.json)
    │       ├── long_term     current/alternative/abandoned hypotheses
    │       ├── history       append-only execution log
    │       └── near_future   1–3 planned steps
    │
    ├── Executor sub-agent     (fresh context, KNOWS the task)
    │       └── executes one step, returns a concrete factual claim
    │
    └── Verifier sub-agent     (fresh context, does NOT know the task)
            └── attacks the literal claim, returns pass/fail + evidence
```

Every loop: Orchestrator picks a step → spawns Executor → spawns Verifier → updates Running Tree → loops. State is fully persisted between iterations.

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
  "long_term": {
    "current_hypothesis": "Cookie not set",
    "alternatives": ["CORS blocking credentials"],
    "abandoned": [
      {
        "hypothesis": "JWT validation is broken",
        "evidence": "decode and signature both valid; login still fails"
      }
    ]
  },
  "history": [
    {
      "iter": 1,
      "step": "reproduce login failure",
      "executor_claim": "curl /login returns 401",
      "verifier_passed": true,
      "verifier_evidence": "confirmed via curl -i"
    }
  ],
  "near_future": ["fix Set-Cookie in auth handler", "run full test suite"]
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
3. **Orchestrator does not execute** — it plans, decides, and writes state; all concrete actions go through sub-agents
4. **State writes happen every iteration** — Running Tree is always inspectable and resumable
5. **Failed hypotheses carry evidence** — abandoned entries are negative examples for future planning
6. **Resource ceilings** — `max_retry_per_step: 2`, hypothesis switches bounded by alternatives + new ones generated on demand

---

## License

MIT
