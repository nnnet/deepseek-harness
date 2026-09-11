# Launched on pin/dsh-v0.1.2-rc.1 (260905-19:09)

**Dsh web работает на 0.1.2-rc.1**: `http://127.0.0.1:3080/?token=4bqzrlOQO7NLwk2dSivlV7ePzJNQRjKvrQyk0jqr9B4`

## Доказательства версии

1. **Git**: `HEAD=pin/dsh-v0.1.2-rc.1`, commit `a66e470204`, tag `dsh-v0.1.2-rc.1`.
2. **`package.json#version`**: `0.1.2-rc.1`.
3. **`@deepseek-ai/dsh-llm` 0.1.2-rc.1**: экспортирует `ToolCallId`, **не** `CallId`.
4. **dsh process running**: `pid 788992`, `node --import tsx/esm apps/cli/src/bin.ts web --no-open`.
5. **Порт 3080**: `LISTEN 0 511 127.0.0.1:3080`.
6. **Startup message**: `dsh web: http://127.0.0.1:3080/?token=...` — 0.1.2-специфичная фича.
7. **dsh-llm симлинк** на `packages/llm/llm/` собран из HEAD = 0.1.2-rc.1.
8. **HTTP /api/typert** отвечает `401 Unauthorized` (новый auth), не `404` (падение boot).
