# AgentForce

## 背景

AI Agent 正在从"对话助手"演变为"执行系统"——它不只是回答问题，而是真正去做事：写代码、调 API、修 bug、完成任务。

但现有的 Agent 框架本质上还是一个"生成器"：给任务 → 推理 → 调工具 → 输出 → 宣布完成。它缺乏一个真正能运行的执行系统。

---

## 问题

当前 Agent 有五个根本缺陷：

| # | 问题 | 表现 |
|---|------|------|
| 1 | **自证正确** | 自己做，自己说完成，不可信 |
| 2 | **假验证** | "看起来对"、"应该没问题"——不动手 |
| 3 | **不会纠错** | 方向错了继续走，不会主动切换 |
| 4 | **重复失败** | 同样的错误会反复犯 |
| 5 | **一次性爆炸** | 不能持续运行，遇到复杂任务就崩 |

**本质**：Agent 只有生成能力，没有执行与验证系统。

---

## 我们的 Idea

让 Agent 从"生成答案"变成"在搜索空间中推进"。

```
旧：生成答案 → 自我声明完成

新：提出假设 → 执行 → 被对抗验证 → 通过才继续
                              ↓
                        失败 → 修复或换方向
```

**最核心一句话**：
> 不是让 Agent 证明自己对，而是让系统尽力证明它错。只有"无法被打败"的结果，才算对。

---

## 实现形态

AgentForce 实现为一个 **Claude Code skill**：单个 markdown 文件 `.claude/commands/agentforce.md`，用户输入 `/agentforce <task>` 触发。

**安装方式**（一行）：
```bash
curl -fsSL https://raw.githubusercontent.com/TokenFlyAI/AgentForce/main/install.sh | bash
```

**为什么是 skill**：零基础设施、立即可用、利用 Claude Code 原生的 sub-agent 机制（保证 context 隔离）和 TaskList（live planning UI）。

---

## 三个 Sub-Agent（核心架构）

Orchestrator（运行 skill 的 Claude 自己）协调三种 sub-agent，全部通过 `Agent` tool 派生，**fully isolated context window**。

| 角色 | 是否知道任务？ | 频率 | 输出权威 |
|------|---------------|------|----------|
| **Executor** | ✓ 是（task + hypothesis + step） | 每步 | 结果直接进 running-tree |
| **Verifier** | ✗ 否（只看 claim 和 artifacts） | 每步 | pass/fail 是 binding |
| **Thinker** | ✓ 是（task + goals + 全部历史 + 之前的 thinker notes） | 每 10 个迭代 | **建议**，不绑定 |

**为什么 Verifier 不知道任务**：知道任务的 verifier 会合理化（"测试失败但任务大方向是对的"）。剥离任务上下文 → 它只能成为纯 fact-checker：*这个具体声明是真的吗？*

**为什么有 Thinker**：每个迭代都在做眼前的事，容易陷入局部最优。每 10 步派一个能看到全局的 Thinker，从第一性原理出发，找盲点、提 out-of-box 想法、画 roadmap。它的话是建议，Orchestrator 自己决定采纳还是搁置。

---

## 核心 Feature

### Feature 1：Adversarial Execution（对抗式执行）

Executor 做事，Verifier 专门找错，两者**完全独立的 context window**。

**Executor 必须输出 concrete checkable claim**：
- ✅ `pytest tests/auth.py exits 0 with 12 passed`
- ❌ `bug is fixed`

**Verifier 的攻击协议**：
1. 解析 claim — 在断言什么具体事实？
2. 用 Bash/Read 等真实检查（不是评论）
3. 至少尝试一个 falsification attack 才能 PASS
4. 进程类 claim：`kill -0 <pid>` AND 功能性检查（curl/log/netstat）

**禁止输出**：「看起来对」、「应该没问题」、「likely」、「appears to」

**结果**：
```
PASS → Verifier 无法攻破 → 才允许继续
FAIL → Verifier 找到漏洞 → 必须重做或换方向
```

---

### Feature 2：Running Tree（树状状态记录，markdown）

存储位置：`.agentforce/running-tree.md`（**markdown，不是 JSON**——LLM 读 markdown 远好过解析指针结构）

**Schema**：
```markdown
# Running Tree

**Task:** <一句话>
**Status:** executing | done | stuck
**Iteration:** N

## Goals (definition of done)
- ⏳ <具体可验证的目标 1>
- ✅ <已被 Verifier 证明的目标>

## Live processes
- 🟢 game-server (pid 12345, port 3199) — started iter 4

## plan_a — "<假设>" [active]
- ✅ a_s1 — <步骤> *claim:* ... *verifier:* ...
- ❌ a_s2 — <步骤> *failure:* ...
  - ✅ a_s2b — <分支> *claim:* ... *verifier:* ...

## plan_b — "<假设>" [untried]

## Abandoned plans
- **plan_x — "<失败假设>"**
  Reason: <作为负样本传给新 plan 生成>
```

**任意节点都可分支**（不只是 Plan 层），失败时不重启而是 backtrack。

---

### Feature 3：四种修复机制

按失败的严重层级触发：

| 机制 | 触发条件 | 动作 |
|------|----------|------|
| **Retry** | Step 失败，retry < 上限 | 同一步换方法重试 |
| **New Branch** | retry 耗尽 | 同父节点添兄弟分支，换思路 |
| **Backtrack** | 当前层分支耗尽 | 走到祖先节点，从那里开新分支 |
| **New Plan** | 整个 Plan 子树废了 | 标记 abandoned（带失败原因），生成全新假设 |

**新 Plan 生成规则**：必须与所有 abandoned plan 方向不同，失败原因作为负样本输入。

---

### Feature 4：Goals — 显式的 Definition of Done

任务开始时，Orchestrator 提取 2-6 个**具体可验证的目标**写进 running-tree.md。

| 不是这样 | 而是这样 |
|----------|----------|
| ❌ 测试能跑 | ✅ `pytest tests/auth.py exits 0 with all tests passing` |
| ❌ 服务器起来了 | ✅ `curl http://localhost:3199/health returns 200` |
| ❌ 登录正常 | ✅ `Set-Cookie: session=...` 在 `/login` 200 响应里出现 |

每个目标随 Verifier 证据 ⏳ → ✅。**所有目标 ✅ 才算 done**，Phase 6 Final Verifier 会逐条独立攻击。

---

### Feature 5：Anti-Drift Protocol

长时间运行后，Orchestrator 的 context 膨胀，严格规则可能漂移（开始跳过 Verifier、自我认证）。

**防御**：硬规则放在独立文件 `.agentforce/protocol.md`，每个迭代开头**都重新读一次**（Phase 0）。即使 conversation context 被压缩，文件读取一次性恢复规则原貌。

protocol.md 显式列出 **forbidden drift modes**："因为结果显然就跳过 Verifier"、"因为快完成了就自我认证"——预先点名，让 Orchestrator 警觉。

**Phase 6 Final Verification Gate**：在 `Status: done` 之前，对**所有 Goals** 派一个最终对抗 Verifier。任何一个 Goal 失败都打回去。

---

### Feature 6：Persistent Processes（长期进程管理）

某些 step 需要启动**会跨越 sub-agent 生命周期**的进程（游戏服务器、daemon、watcher）。

| Pattern | 何时用 | 怎么做 |
|---------|-------|--------|
| **Pattern 1: One-shot**（默认） | 测试、build、curl、文件操作 | 普通 `Bash` |
| **Pattern 2: Persistent** | 服务器、daemon、watcher | `setsid nohup ... &; disown` + manifest |

Pattern 2 详情：
```bash
setsid nohup <cmd> > .agentforce/processes/<name>.log 2>&1 &
echo $! > .agentforce/processes/<name>.pid
disown
```
+ 写 manifest 到 `.agentforce/processes/<name>.json`（含 pid、port、purpose 等）

**Per-command 决定**——同一个 `/agentforce` 运行内可以混用：iter 3 用 Pattern 2 起服务器，iter 4 用 Pattern 1 curl 它。进程跨越 Executor、Orchestrator、整个 `/agentforce` 调用，下次再调用还能找到。

---

### Feature 7：TaskList × Running Tree（live + durable 双层）

利用 Claude Code 内置的 `TaskCreate` / `TaskUpdate`：

| | TaskList（内置） | running-tree.md（自定义） |
|---|------|------|
| **角色** | live planning | durable record |
| **可见性** | Claude Code 任务 UI（实时 spinner） | 磁盘文件，跨 session 持久化 |
| **粒度** | 当前 step（exactly one in_progress） | 整棵树 + 历史 + 失败 + 进程 |
| **生命周期** | per-session | persistent |

跨 session resume：TaskList 是 per-session 的，新 session 启动时从 running-tree.md 重建当前 task。

---

### Feature 8：THINK Phase（动态 loop）

每个迭代在 spawn Executor 之前，Orchestrator 有一个**显式的思考时刻**：

```
Phase 0 → Phase 1.5 (THINK) → Phase 2 (Executor) → Phase 3 (Verifier) → Phase 4
```

THINK 是 Orchestrator 决定**继续还是 pivot** 的窗口：
- 上次 Verifier 揭示了什么？
- 哪些 Goals 还是 ⏳？现在的 step 真的在推进它们吗？
- 最近有 Thinker notes 吗？要不要采纳？

**工具是可选的**（不是仪式）：
- `TaskList()` — 仅在 resume 或换 plan 时用
- 读 `running-tree.md` — 仅在需要更广的 context 时
- 改 `running-tree.md` — 罕见，仅在 reshape 时

**默认是继续**。THINK 是 pivot 的窗口，不是为变而变。

---

## 完整运行 Loop

```
PHASE 0  — 读 .agentforce/protocol.md（每个迭代，防 drift）
PHASE 1  — 初始化或 resume（仅首次或新 session）
            • 写 protocol.md
            • 提取 2-6 个 Goals
            • 生成 3 个 plan 假设 + plan_a 第一步
            • TaskCreate + in_progress
PHASE 1.25 — Thinker（仅当 iteration % 10 == 0）
            • 全局回顾，输出建议到 thinker-notes.md
PHASE 1.5 — THINK
            • 反思上次结果，决定继续 or pivot
            • 可选读 thinker-notes.md / TaskList() / running-tree.md
PHASE 2  — Agent(Executor)：执行一步，输出可检验 claim
PHASE 3  — Agent(Verifier)：攻击 claim（不知道 task）
PHASE 4  — 更新状态
            • Self-check gate（必须 spawn 了 Executor + Verifier）
            • PASS：append running-tree.md，✅ 已达成的 goals，TaskUpdate(completed)，TaskCreate 下一步
            • FAIL：Retry / New Branch / Backtrack / New Plan / Stuck
PHASE 5  — 打印状态，loop 回 Phase 0
PHASE 6  — Final Verification Gate（仅当所有 Goals ✅，且多步/多分支/多 plan 时）
            • Agent(Final Verifier) 逐条独立攻击每个 Goal
            • 任一失败 → 该 Goal 翻回 ⏳，进 escalation ladder
            • 全部通过 → Status: done
```

---

## 关键设计约束

1. **Verifier 没有任务上下文** — 只验证 literal 事实
2. **Executor 必须输出 checkable claim** — 拒绝 "fixed"，要 "`pytest exits 0 with N passed`"
3. **Orchestrator 不直接执行** — 只规划/决策/写状态，所有动作走 sub-agent
4. **每步两个 Agent() 调用** — Executor + Verifier 是硬约束，self-check gate 强制
5. **Final Verification 是条件触发** — 单步任务里 per-step Verifier 就是 final
6. **protocol.md 每迭代重读** — 不受 context 压缩影响
7. **State 是 markdown 不是 JSON** — LLM 读起来更舒服
8. **Persistent process 跨越 sub-agent 边界** — `setsid` + manifest
9. **Failed plan 必带 evidence** — 作为负样本喂给新 plan 生成
10. **Thinker 是 advisory** — 不绑定 Orchestrator 的决策
11. **资源上限** — `max_retry_per_step: 2`, `max_branches_per_node: 3`, `max_plans: 5`

---

## 文件结构

```
~/.claude/commands/agentforce.md  ← skill（用户全局可用）

工作目录运行时生成：
.agentforce/
├── protocol.md          ← anti-drift 规则，每迭代重读
├── running-tree.md      ← 状态：goals + tree + claims + evidence + 进程
├── thinker-notes.md     ← Thinker 的建议（每 10 迭代）
└── processes/           ← 持久进程的 manifest + log
    ├── <name>.json
    ├── <name>.pid
    └── <name>.log
```

---

## 最小可跑 Demo

任务：`/agentforce Fix the failing test in auth.py`

```
[Iter 1]  Init — Goals: 3 articulated. Plans: 3 hypotheses. plan_a starts.
[Iter 1]  plan_a / a_s1 (reproduce)        → PASS ✓ — goals: 0/3
[Iter 2]  plan_a / a_s2 (patch redirect)   → FAIL — retry 1/2
[Iter 3]  plan_a / a_s2                    → FAIL — new branch a_s2b
[Iter 4]  plan_a / a_s2b (patch middleware)→ FAIL — backtrack, plan_a abandoned
[Iter 5]  plan_b / b_s1 (reproduce)        → PASS ✓ — goals: 1/3
[Iter 6]  plan_b / b_s2 (fix Set-Cookie)   → PASS ✓ — goals: 2/3
[Iter 7]  plan_b / b_s3 (full test suite)  → PASS ✓ — goals: 3/3
[Iter 7]  PHASE 6: Final Verifier on all 3 goals → PASS ✓
✅ DONE
```

---

## 实现阶段

| 阶段 | 内容 | 状态 |
|------|------|------|
| Phase 1 | Worker + Verifier 对抗循环 + 单 Plan + retry | ✅ 已实现 |
| Phase 2 | Plan Tree + 4 种修复机制 + Orchestrator 状态机 | ✅ 已实现 |
| Phase 3 | Markdown state（取代 JSON）+ 持久 protocol.md | ✅ 已实现 |
| Phase 4 | Persistent processes（Pattern 1/2）+ manifest | ✅ 已实现 |
| Phase 5 | TaskList × Running Tree（live + durable 双层） | ✅ 已实现 |
| Phase 6 | Goals 作为 definition of done + Final Verifier | ✅ 已实现 |
| Phase 7 | THINK phase + 动态 loop | ✅ 已实现 |
| Phase 8 | Thinker（每 10 迭代的 first-principles 建议） | ✅ 已实现 |
| Phase 9 | One-line install（curl install.sh）+ 网站宣传 | ✅ 已实现 |
| Phase 10 | 失败模式分析 + 跨 session memory + dashboard | 🔜 计划中 |

---

## 仓库与发布

- **GitHub**: <https://github.com/TokenFlyAI/AgentForce>
- **网站**: 集成在 [TokenFly](https://github.com/ccyjava/tokenfly) 主站，专题页 `/agentforce`
- **License**: MIT
