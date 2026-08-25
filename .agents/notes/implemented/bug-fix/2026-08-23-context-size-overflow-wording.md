# Agent Note: Classify passive context-size wording as context overflow

Status: implemented

English | [中文](2026-08-23-context-size-overflow-wording.zh.md)

## Problem

`isContextWindowExceededError` recognized only `length` and `window` as the exceeded bound, and only in the joined `context_length_exceeded` form or with an explicit subject (`input`, `prompt`, `request`, `messages`). llama.cpp-derived servers, including LM Studio, report overflow as `Context size has been exceeded.` inside an HTTP 500 envelope: `Engine protocol predict stream returned an error: {"code":500,"message":"Context size has been exceeded.","type":"server_error"}`. The noun is `size` and the phrasing is passive with no subject, so neither pattern matched.

Two consequences follow from the miss, both observed in session logs. The pi-ai classifier falls through to its `\b5\d\d\b` rule and labels the failure `SERVER`, which is in the default retryable set, so the harness re-sent an already-oversized request until retries were exhausted. Overflow recovery reacts only to `CONTEXT_WINDOW_EXCEEDED`, so compaction never ran on the one failure that compaction exists to repair, and the turn ended in error.

## Decision

`STRUCTURED_CONTEXT_OVERFLOW` accepts `size` beside `length` and `window`, and admits an optional copula run (`has|have|is|are|was|were` and `been`) between the bound and the exceeded verb. The joined code form still matches with no separator words. The classifier stays text-only and provider-neutral: no provider list, no status-code special case.

The pattern remains conservative about validation wording. `context size must be positive` and `context size has been reduced to 4096` stay unclassified, because the copula run only bridges to `exceed`/`overflow`/`limit exceeded`.

## Alternatives considered

**Reorder the pi-ai classifier so overflow is tested before the HTTP-status rules.** Rejected because the classifier already tests overflow first — `mapStopReason` checks `isContextWindowExceededError` before the status rules run. The order was never the defect; the pattern was.

**Special-case the LM Studio envelope in `dsh-llm-pi-ai`.** Rejected because the wording originates in llama.cpp, which many local servers embed, and both adapters route on the same shared classifier. A provider-specific branch would leave `dsh-llm-deepseek` and every future adapter blind to the same text.

**Widen `EXCEEDS_MODEL_CONTEXT` to make its subject optional.** Rejected because that pattern's subject requirement is what keeps `temperature exceeds maximum allowed value` and similar parameter-validation text out. Naming `size` as a context bound in the structured pattern adds the wording without weakening the subject guard.

**Treat any HTTP 500 carrying `context` as overflow.** Rejected because a status code carries no information about which bound failed, and misclassifying a genuine server fault as overflow would trigger a pointless compaction and discard history.

## Testing

`packages/llm/llm/tests/service.spec.ts` pins the verbatim LM Studio envelope, the passive `context window was exceeded` form, and the bare `context size exceeded` form as overflow, and pins the two validation phrasings as non-overflow. `packages/llm/llm-pi-ai/tests/convert.spec.ts` asserts that the same envelope reaches `mapStopReason` as `CONTEXT_WINDOW_EXCEEDED` rather than the `SERVER` its `500` would otherwise produce.

## Consequences

Local llama.cpp-backed servers now trigger compaction instead of retry storms on overflow. Any provider whose overflow message names `context size` gains the same routing. The classifier's surface grows by one bound noun and an optional copula run, which is more text to keep conservative as new provider wording appears; the non-overflow assertions are the guard against that drift.
