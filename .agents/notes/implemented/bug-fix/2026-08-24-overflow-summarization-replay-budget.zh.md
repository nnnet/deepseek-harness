# Agent Note：将溢出摘要重放限制在已路由窗口内

Status: implemented

[English](2026-08-24-overflow-summarization-replay-budget.md) | 中文

## Problem

上下文溢出恢复以 `retainTokens = 0` 选择区域，因此除最新的不可分单元外，它会遮蔽每一个表层节点。随后 `compactSurfaceRegion` 通过 `summarizeWithLlm` 重放整个区域，前面带着被拒绝请求所携带的同一套系统提示与工具，再追加 459 token 的压缩指令，并为摘要本身预留 `maxTokens`（默认 `8192`）。因此，恢复请求比提供方刚刚拒绝的请求更大，而强制执行窗口的服务器会以同样的理由拒绝它。`compactIfNeeded` 抛出异常，`agent/request-error` listener 保留原始的 `CONTEXT_WINDOW_EXCEEDED`。

真实循环回归测试量化了这一差距：在 4000 token 的窗口下，4916 token 的对话请求溢出，而随后的恢复请求需要 5617 token。

会话日志展示了背后的失败分布。在一次 32768 token 的本地服务器会话中，74 次压缩尝试有 28 次以 `error` 字段结束：18 次摘要在 token 上限处被截断、5 次提供方错误、3 次空摘要，以及 2 次摘要不小于其所替换的内容。其中一个轮次在 2.6 小时内重试压缩 28 次。

对于 llama.cpp 衍生的服务器，在[被动式 context size 措辞](2026-08-23-context-size-overflow-wording.zh.md)开始将其溢出分类为 `CONTEXT_WINDOW_EXCEEDED` 之前，这条路径根本无法到达，因此正是那个修复暴露了本缺陷。

## Decision

`BasicCompactionEngine` 为 `context-overflow` 触发条件推导出重放预算，并把放不下的尾部作为 `retainTokens` 传给 `selectCompactableRange`。`region.ts` 中的 `overflowRetainTokens` 将预算定价为 `contextWindow - maxTokens - envelope - instruction`：其中 `envelope` 是请求压力与表层 token 之间的实测差值，也就是重放复用的同一套系统提示与工具；`instruction` 是经计量器定价的 `compactionInstructionMessage()`，摘要调用会逐字发送它。保留尾部为 `surfaceTokens - budget`，因此重放的头部受预算约束，摘要调用在构造上就能放进窗口。

`contextWindow` 来自会话中持久化的 `request/context` 元数据，循环会在每次请求前从已解析的路由记录它。那正是失败请求所超出的窗口，因此该预算在恢复路径内不需要适配器调用，也不需要会话记录之外的任何容量元数据。

有两种配置保持此前的无界重放。已配置的 `summarizationProvider`／`summarizationModel` 对在本会话并未描述的窗口上作答；未公布 `contextWindow` 的路由则无从推导。`maxTokens` 本身就耗尽窗口同样不属于有界情形：引擎会带上提供方、模型、上限与窗口发出警告，并重放整个可压缩头部，因为提供方已确立压缩的必要性，而尽力而为的一次尝试是恢复仅剩的机会。

## Alternatives considered

**限制摘要输出而不是输入。** 已拒绝，因为 `maxTokens` 本来就已受限；日志中 18 次上限截断的摘要正是仅限输出的约束所产生的结果。输出上限无法把重放的输入保持在窗口内，而正是这一项使请求无法发送。

**遮蔽表层的一个可配置比例——一个 `overflowInputRatio` 配置键。** 已拒绝，因为没有证据能确定这个比例：0.5 能修复超出窗口 5% 的请求，却修复不了超出 3 倍的请求，而由窗口推导的预算是精确的，且不需要新配置键。包规则要求公开默认值必须有证据支撑，而比例并没有。

**当 `maxTokens` 加上指令无法放入某个策略的窗口时，让插件加载失败。** 已拒绝，因为窗口属于已路由模型而非配置：`modelPolicies` 条目所命名的目标，其容量在适配器解析之前是未知的，而动态路由可能逐请求变化。该检查必须在窗口已知处运行，也就是恢复时。

**在恢复内部通过 `ctx.llm.resolveModelInfo` 解析摘要器窗口。** 已拒绝，因为这会给最后一次恢复尝试增加一个 await 和一个失败模式：不再注册的已路由提供方——恢复的会话、变更的组合——会在此前可正常恢复处抛出异常。持久化的 `request/context` 元数据无需调用即可为对话自身的路由回答同一问题。

## Testing

`packages/compaction/compaction-basic/tests/compaction-loop-repro.spec.ts` 通过真实循环，针对 `WindowEnforcingAdapter` 运行整条路径；该适配器会拒绝任何重放输入加预留生成上限超出其公布窗口的请求，摘要调用也不例外。测试断言恰好发生一次拒绝、摘要请求能放进窗口，以及重试的对话携带 checkpoint 与最新历史、而最旧的历史已消失。还原该预算会使摘要调用成为第二次拒绝。

`packages/compaction/compaction-basic/tests/compaction-basic.spec.ts` 在三个点上直接为 `overflowRetainTokens` 定价——预算小于表层、大于表层，以及被上限耗尽——并固定三种引擎行为：在已公布窗口下的有界重放、配置了独立摘要器时的无界重放，以及上限本身耗尽窗口时的警告。

## Consequences

溢出恢复现在能在强制执行 `n_ctx` 的服务器上收敛，而这正是本 harness 与本地 llama.cpp 后端相遇之处。每次恢复都会逐字保留一段近期尾部，而不是替换掉除最后一个单元以外的全部内容，因此单次恢复回收的量少于此前的最大缩减，由 `maxOverflowRetries` 决定一个对话能回退多远。路由未公布窗口的会话，以及配置了独立摘要器的组合，仍保持旧的无界行为，其留下的缺口记录在包 README 的「已知限制」中。
