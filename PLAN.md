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

核心转变：

```
旧：生成答案 → 自我声明完成

新：提出假设 → 执行 → 被对抗验证 → 通过才继续
                              ↓
                        失败 → 修复或换方向
```

两个核心机制支撑这个转变：

1. **Adversarial Execution（对抗式执行）** — 用一个专门找错的 Verifier 攻击 Worker 的每一步输出
2. **Plan Tree（路径搜索）** — 同时持有多个假设，失败时切换方向，而不是原地重试

**最核心一句话**：
> 不是让 Agent 证明自己对，而是让系统尽力证明它错。只有"无法被打败"的结果，才算对。

---

## 核心 Feature

### Feature 1：Adversarial Execution（对抗式执行）

Worker 做事，Verifier 专门找错，两者对抗。Worker 不再能"自证正确"。

**Verifier 的两个层级：**

**Level 1 — 真实执行验证（优先）**

Verifier 必须动手，不能评论：

- 写了代码 → 跑测试，找未覆盖的 case
- 修了 Bug → 复现原始 bug，看是否真的消失
- 调了 API → 检查真实返回值，不看声明
- 改了文件 → diff 验证内容符合预期

**Level 2 — 对抗 Agent（无执行环境时降级）**

另起一个 LLM 专门攻击：

- 构造反例
- 找逻辑漏洞
- 质疑边界条件
- 禁止输出"看起来对" / "应该没问题"

**结果只有两种**：

```
PASS → Verifier 无法攻破 → 才允许继续
FAIL → Verifier 找到漏洞 → 必须重做
```

---

### Feature 2：Plan Tree（路径搜索）

不是一个 Plan，而是一棵 Plan 树。每个 Plan 是一个假设方向。

```
Root
 ├── Plan A：问题在 redirect handler
 ├── Plan B：问题在 cookie
 └── Plan C：问题在 session 过期
```

**四种修复机制**，根据失败层级触发：

| 机制 | 触发条件 | 动作 |
|------|----------|------|
| **Retry** | Step 失败，未超上限 | 同一步换方法重试 |
| **Rollback** | retry 全败 | 回上一步，走不同路径 |
| **Replan** | rollback 失败 | 重写当前 Plan 的后续步骤 |
| **New Plan** | Plan 整体方向错 | 标记 FAILED，生成全新假设 |

**新 Plan 生成规则**：必须与所有 FAILED Plan 的方向不同，失败原因作为负样本输入。

---

### Feature 3：Orchestrator 状态机

统一调度 Worker、Verifier、Plan Tree，对外暴露可观测的执行状态。

```
INIT → PLANNING → EXECUTING → DONE
                      │
                   STUCK（所有 Plan 失败）→ 上报
```

**关键约束**：
- Verifier 独立于 Worker，不读 Worker 的自信度
- 每个 Plan 有资源上限（最多 M 步、N 次 retry）
- 所有失败必须记录原因，供后续 Plan 生成参考

---

## 最小可跑 Demo

任务：`"Fix the failing test in auth.py"`

```
Plan A: redirect handler 问题
  Step 1: reproduce  → PASS  (Verifier 确认 test 确实失败)
  Step 2: patch      → FAIL  (Verifier 跑测试，还是红)
  retry              → FAIL
  Plan A FAILED

Plan B: cookie 问题
  Step 1: reproduce  → PASS
  Step 2: fix cookie → PASS  (Verifier 跑测试，绿了)
  Step 3: full suite → PASS

DONE
```

---

## 实现阶段

| 阶段 | 内容 | 验收标准 |
|------|------|----------|
| Phase 1 | Worker + Verifier 对抗循环，单 Plan | 一个 Step 的完整对抗轮次跑通 |
| Phase 2 | Plan Tree + Orchestrator 状态机 | 有歧义的任务自动探索多个方向 |
| Phase 3 | Level 1 真实验证（bash 沙箱、测试运行器） | 代码修复任务靠跑测试判断成败 |
| Phase 4 | 持久化 + 可视化 | Plan Tree 实时状态可见，失败链路可查 |
