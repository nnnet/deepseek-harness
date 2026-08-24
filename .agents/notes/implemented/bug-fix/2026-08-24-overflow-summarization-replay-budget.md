# Agent Note: Bound the overflow summarization replay to the routed window

Status: implemented

English | [中文](2026-08-24-overflow-summarization-replay-budget.zh.md)

## Problem

Context-overflow recovery selected its region with `retainTokens = 0`, so it shadowed every surface node except the newest indivisible unit. `compactSurfaceRegion` then replayed that whole region through `summarizeWithLlm`, behind the same system prompt and tools the rejected request carried, appended the 459-token compaction instruction, and reserved `maxTokens` — `8192` by default — for the summary itself. The recovery request was therefore larger than the request the provider had just refused, and a server that enforces its window refused it for the same reason. `compactIfNeeded` threw, and the `agent/request-error` listener preserved the original `CONTEXT_WINDOW_EXCEEDED`.

The real-loop regression prices the gap: against a 4000-token window, a 4916-token conversation request overflows and the recovery request that follows costs 5617 tokens.

Session logs show the failure distribution behind this. In one 32768-token local-server session, 28 of 74 compaction attempts ended with an `error` field: 18 summaries truncated at the token cap, 5 provider errors, 3 empty summaries, and 2 summaries no smaller than the content they replaced. One turn retried compaction 28 times across 2.6 hours.

For llama.cpp-derived servers this path was unreachable until [passive context-size wording](2026-08-23-context-size-overflow-wording.md) began classifying their overflow as `CONTEXT_WINDOW_EXCEEDED`, so that fix is what exposed this one.

## Decision

`BasicCompactionEngine` derives a replay budget for the `context-overflow` trigger and passes the tail that does not fit to `selectCompactableRange` as `retainTokens`. `overflowRetainTokens` in `region.ts` prices the budget as `contextWindow - maxTokens - envelope - instruction`, where `envelope` is the measured difference between request pressure and surface tokens — the same system prompt and tools the replay reuses — and `instruction` is `compactionInstructionMessage()` priced through the meter that the summarization call sends verbatim. The retained tail is `surfaceTokens - budget`, so the replayed head is bounded by the budget and the summarization call fits the window by construction.

`contextWindow` comes from the session's durable `request/context` metadata, which the loop logs from the resolved route before each request. That is exactly the window the failing request exceeded, so the budget needs no adapter call inside the recovery path and no capacity metadata beyond what the session already records.

Two configurations keep the previous unbounded replay. A configured `summarizationProvider`/`summarizationModel` pair answers on a window this session says nothing about, and a route that advertises no `contextWindow` leaves nothing to derive from. A `maxTokens` that alone exhausts the window is not a bounded case either: the engine warns with the provider, model, cap, and window, and replays the whole compactable head, because the provider has already established that compaction is necessary and a best-effort attempt is the only remaining chance at recovery.

## Alternatives considered

**Cap the summarization output instead of the input.** Rejected because `maxTokens` was already capped; the 18 cap-truncated summaries in the logs are what an output-only bound produces. Nothing in an output cap keeps the replayed input inside the window, which is the term that made the request unsendable.

**Shadow a configured fraction of the surface — an `overflowInputRatio` config field.** Rejected because a fraction is a guess that no evidence sets: 0.5 fixes a request 5% over the window and fails one 3× over, while the window-derived budget is exact and needs no new key. Package rules require evidence for a public default, and there is none for a ratio.

**Fail plugin load when `maxTokens` plus the instruction cannot fit a policy's window.** Rejected because the window belongs to the routed model, not the config: `modelPolicies` entries name targets whose capacity is unknown until an adapter resolves them, and a dynamic route can change per request. The check has to run where the window is known, which is recovery time.

**Resolve the summarizer's window through `ctx.llm.resolveModelInfo` inside recovery.** Rejected because it adds an await and a failure mode to the last recovery attempt: a routed provider that is no longer registered — a resumed session, a changed composition — would throw where recovery previously worked. The durable `request/context` metadata answers the same question for the conversation's own route without a call.

## Testing

`packages/compaction/compaction-basic/tests/compaction-loop-repro.spec.ts` runs the whole path through the real loop against `WindowEnforcingAdapter`, which rejects any request whose replayed input plus reserved generation cap exceeds its advertised window, summarization included. The test asserts exactly one rejection, that the summarization request fits the window, and that the retried conversation carries the checkpoint and the newest history while the oldest is gone. Reverting the budget makes the summarization call the second rejection.

`packages/compaction/compaction-basic/tests/compaction-basic.spec.ts` prices `overflowRetainTokens` directly at three points — a budget smaller than the surface, one larger than it, and one the cap exhausts — and pins the three engine behaviors: a bounded replay under a declared window, an unbounded replay when a separate summarizer is configured, and the warning when the cap alone exhausts the window.

## Consequences

Overflow recovery now converges on servers that enforce `n_ctx`, which is where the harness meets local llama.cpp backends. Each recovery keeps a recent tail verbatim instead of replacing everything but the last unit, so a single recovery reclaims less than the previous maximal reduction and `maxOverflowRetries` governs how far a conversation walks back. Sessions whose route advertises no window, and compositions with a separate summarizer, keep the old unbounded behavior and the gap they leave is recorded in the package README's Known Limitations.
