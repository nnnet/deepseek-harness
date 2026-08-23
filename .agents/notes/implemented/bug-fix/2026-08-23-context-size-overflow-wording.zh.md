# Agent Note: Classify passive context-size wording as context overflow

Status: implemented

[English](2026-08-23-context-size-overflow-wording.md) | 中文

## Problem

`isContextWindowExceededError` 只把 `length` 与 `window` 识别为被超出的界限，并且只接受合并的 `context_length_exceeded` 形式或带显式主语（`input`、`prompt`、`request`、`messages`）的措辞。llama.cpp 系服务器（包括 LM Studio）在 HTTP 500 信封中把溢出报告为 `Context size has been exceeded.`：`Engine protocol predict stream returned an error: {"code":500,"message":"Context size has been exceeded.","type":"server_error"}`。其名词是 `size`，句式为无主语被动，因此两个模式都不匹配。

漏判带来两个后果，会话日志中均已观察到。pi-ai 分类器落到 `\b5\d\d\b` 规则并将失败标记为 `SERVER`，而该 code 位于默认可重试集合中，于是 harness 反复重发已经超长的请求，直到重试次数耗尽。溢出恢复只响应 `CONTEXT_WINDOW_EXCEEDED`，因此在唯一需要压缩修复的失败上压缩从未运行，turn 以错误结束。

## Decision

`STRUCTURED_CONTEXT_OVERFLOW` 在 `length` 与 `window` 之外接受 `size`，并允许界限与表示超出的动词之间出现可选系动词序列（`has|have|is|are|was|were` 与 `been`）。合并 code 形式仍然在没有分隔词时匹配。分类器保持纯文本且提供方无关：没有提供方名单，也没有状态码特例。

该模式对校验类措辞仍然保守。`context size must be positive` 与 `context size has been reduced to 4096` 依旧不会被分类，因为系动词序列只连接到 `exceed`／`overflow`／`limit exceeded`。

## Alternatives considered

**调整 pi-ai 分类器顺序，让溢出判断先于 HTTP 状态规则。** 已否决：分类器本来就先判断溢出——`mapStopReason` 在状态规则运行之前就调用 `isContextWindowExceededError`。缺陷从来不在顺序，而在模式本身。

**在 `dsh-llm-pi-ai` 中为 LM Studio 信封做特例。** 已否决：该措辞源自 llama.cpp，许多本地服务器都嵌入它，而两个适配器共用同一个分类器。提供方特例会让 `dsh-llm-deepseek` 以及未来每个适配器对同一文本继续失明。

**放宽 `EXCEEDS_MODEL_CONTEXT`，使其主语变为可选。** 已否决：该模式的主语要求正是把 `temperature exceeds maximum allowed value` 这类参数校验文本挡在外面的机制。在结构化模式中把 `size` 列为上下文界限，可以在不削弱主语约束的前提下涵盖该措辞。

**把任何包含 `context` 的 HTTP 500 都当作溢出。** 已否决：状态码不携带任何关于哪个界限失败的信息，而把真正的服务端故障误判为溢出会触发无意义的压缩并丢弃历史。

## Testing

`packages/llm/llm/tests/service.spec.ts` 逐字固定 LM Studio 信封、被动的 `context window was exceeded` 形式以及裸的 `context size exceeded` 形式为溢出，并固定两条校验措辞为非溢出。`packages/llm/llm-pi-ai/tests/convert.spec.ts` 断言同一信封到达 `mapStopReason` 时为 `CONTEXT_WINDOW_EXCEEDED`，而不是其 `500` 原本会产生的 `SERVER`。

## Consequences

本地 llama.cpp 后端服务器在溢出时现在会触发压缩，而不是重试风暴。任何在溢出消息中使用 `context size` 的提供方都获得同样的路由。分类器表面增加了一个界限名词与一段可选系动词序列，随着新的提供方措辞出现，需要保持保守的文本也更多；非溢出断言正是防止这种漂移的护栏。
