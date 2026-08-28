# Cookbook: regression-testing a local-model dsh configuration

English | [中文](regression-testing-local-model-configs.zh.md)

A locally-hosted small model reacts to system-prompt size, persona wording, and tool surface very differently than a frontier model, and its run-to-run variance is large enough to hide a real effect at a handful of samples. This is the procedure for measuring a `dsh` configuration change (a *lever*) against a live local model and turning a verified win into a guarded default, independent of any particular task or model.

## 1. Write a reference task and a machine gate

Pick one task representative of the deployment's real workload, phrased as a single verbatim prompt message — no multi-turn scripting. Write a gate script that checks the produced artifact structurally, without invoking `dsh` or the model: stub the tool registry and the home directory the candidate code reads, import and drive the candidate's exported `apply`/`execute` directly inside a short-timeout child process, and exit `0` only when every check (module loads, exports the expected plugin shape, registers the expected tool, executes to the expected value on more than one fixture) passes. Print a final `gate=1` or `gate=0` line — the runner in step 3 reads it. Self-test the gate against known-good and known-bad fixtures before trusting it on real runs.

## 2. Layer the configuration under test as a `--patch` overlay

Any `dsh` profile layers `--patch <file>.yml` overlays on top of its bundles in argument order; each patch targets a row by `id:` and either replaces its whole `config` or inserts new rows ([profiles and bundles](../architecture.md#profiles-and-bundles)). `dsh --profile <profile> --dump-config` prints the composed tree with every row's id — patch exactly those ids, and re-run `--dump-config` after writing an overlay to confirm the id matched something.

A headless profile does not mount the `agent-presets` service at all — it builds an `Agent` directly off the core registry. The model-visible persona text there lives on `id: system-prompt`'s `config.persona` field, bundled by the headless bundle's own patch file — not on the `id: persona` plugin, which exists only inside agent-preset composition files (`apps/cli/config/agent-presets/*/agent.cordis.yml`). Confirm which id actually carries persona text in the profile under test before writing an overlay; the two are not interchangeable, and a patch against the wrong id silently does nothing — no matching row, no error.

```yaml
# Disables an LLM-visible tool row: its JSON Schema stops being appended to
# every request. Background services the row's tool depended on stay
# mounted unless they are patched too — check whether another tool resolves
# a provider by name before disabling the row that publishes it.
- id: tool-web
  disabled: true
```

## 3. Run repeatedly against a clean workspace and log metrics

Empty the task workspace directory before every run. After `dsh` exits, find the session directory it just wrote under `~/.dsh/sessions/--<workspace-path-with-slashes-replaced-by-dashes>--/session-<uuid>/`, picking the newest one created after a marker file touched immediately before the run — a resumed session's directory can predate the run under test. Decompress `session.jsonl.zstd` and read it as newline-delimited JSON events; extract:

- **wall** — `(max turn/end time − min turn/start time) / 1000` seconds. Not the session directory's own timestamp: `session/end-seed` and the config events that precede it carry the original session-creation time, which can be days older than a resumed run.
- **steps** — count of `step/start` events.
- **in_med / in_max** — median / max of `usage.inputTokens` read off `assistant/chunk` events whose `chunk.type` is `usage`.
- **think_ratio** — `reasoning-chunks / (reasoning-chunks + text-chunks)`, counting event occurrences, not token counts.
- **tool_err** — count of `tool/result` events carrying a content block with `type: 'tool-result'` and `isError: true`.
- **compactions** — count of `compaction/start` events.
- **gate** — `1` if step 1's gate script passed against the produced artifact, else `0`.

Append one row per run to a ledger table (`timestamp | lever | session | wall | steps | in_med | in_max | think_ratio | tool_err | compactions | gate`) — a flat Markdown table is enough; it is the only record a later run needs to compare against.

## 4. Size the sample from the observed spread, not a fixed count

Run the baseline configuration first, at least three times, and compute `(max − min) / min` on `wall` across those runs. If that spread exceeds 50%, every subsequent lever in this comparison is measured over five runs, not three — a small local model's sampling variance at three runs can dwarf the effect size of the change under test, and a fixed low `n` reports false wins and false regressions in roughly equal measure.

## 5. Judge a lever from the aggregate, not one run

Compare the lever's aggregate (mean and median `wall`, gate rate, and whichever metric the change specifically targets — `tool_err` for a wording change, `compactions` for a token-budget change) against the baseline's aggregate over the same sample size. Accept the lever only when the gate rate does not regress and the specifically targeted metric improves by more than the spread measured in step 4 — `wall` alone is not a reliable signal at this sample size; a change that only moves `wall` without moving a metric it plausibly causes is more likely sampling noise than a real effect.

## 6. Package a verified combination as an agent preset

Once one or more levers are accepted, fold them into an installable preset instead of leaving them as ad hoc overlays:

```
~/.dsh/.agent-presets/<name>/
  preset.yml         # name + description display text only — trust and discovery
                      # come from the root this directory is found under, not this file
  agent.cordis.yml    # a cordis-plugin-include row + the preset's own delta rows
```

`agent.cordis.yml` starts with a `cordis-plugin-include` row whose `config.path` is a **literal, install-baked absolute path** to the harness's own `apps/cli/config/agent-presets/standard/agent.cordis.yml` — group rows (an include row is one) skip loader interpolation, so this cannot be a `!!js` expression. `config.patches` then targets `id:`s inside that included composition, the same way a `--patch` overlay targets ids inside a profile's composition — but it is a different composition tree with different ids: an agent preset patches `id: persona`, not `id: system-prompt`. Grep the target standard composition for each id before copying a headless overlay's disabled-id list into a preset — at least one id proven safe to disable in a headless overlay is provably unsafe inside a preset: a tool row that registers a continuable setup on a process-wide singleton rather than an ordinary per-session tool throws on the second preset mounted in one process if a preset patches it. The standard composition documents which ids fall into this category in the comment beside their row.

`dsh --profile <profile> --dump-config` shows only the static, compile-time composition tree — it never reflects `agent-presets.default` from `settings.yaml`, because that value resolves dynamically at runtime through the settings capability, not through the static patch tree. Verify a new preset by structural inspection instead (every patched id exists in the target composition; the preset directory and both files are well-formed YAML) and by running the reference task once through a surface that actually mounts agent presets — headless profiles do not.

## 7. Verify

1. `node <gate-script> --self-test` passes against known-good and known-bad fixtures.
2. Baseline, n ≥ 3 (n ≥ 5 if step 4's spread check trips): every run's `gate` is `1`, and the ledger records wall/steps/in_med/in_max/think_ratio/tool_err/compactions for each.
3. Each candidate lever, same sample size as the baseline comparison: gate rate does not regress, and the metric the lever targets improves outside the spread measured in step 4.
4. After packaging accepted levers as a preset: every patched id is confirmed present (and, for `tool-*` ids, confirmed not process-singleton-backed) in the target standard composition, and one run of the reference task through a preset-mounting surface completes without a load-time error.

## Champion configuration measured in this repository

Measured 2026-08-27–29 against `qwen/qwen3.8-27b` (Q4_K_M, LM Studio) on this repository's own reference task, following the procedure above:

| configuration | n | wall mean / median (s) | gate | tool_err mean | compactions mean |
|---|---|---|---|---|---|
| baseline | 3 | 959.6 / 671.4 | 3/3 | 0.33 | 2.33 |
| + reduced tool surface | 5 | 600.5 / 628.7 | 5/5 | 0.80 | 0.00 |
| + short-steps persona | 5 | 694.9 / 496.2 | 5/5 | 0.20 | 0.80 |

The installed `local-fast` preset combines both accepted levers. This workload's own run-to-run spread already reaches roughly 180% at n = 5 (step 4), so a regression check treats a gate rate under 4/5 across five runs, or a median `wall` past roughly double the persona row above, as a signal worth investigating rather than as sampling noise — not as a tight statistical bound. Full data, the rejected levers, and the reasoning behind each accept/reject call are in [the local-fast Agent Note](../../.agents/notes/implemented/feature/2026-08-29-local-fast-preset.md).
