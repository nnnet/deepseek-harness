# 实操手册：为本地模型的 dsh 配置做回归测试

[English](regression-testing-local-model-configs.md) | 中文

本地部署的小模型对系统提示词长度、人设措辞和工具面的反应与前沿模型截然不同，而且它的单次运行间方差大到足以在少量样本下掩盖真实效应。本文给出的是这样一套流程：针对一个存活的本地模型度量一次 `dsh` 配置改动（下文称为**调整项**），并把一次得到验证的收益固化为受保护的默认配置——这套流程与具体任务或具体模型无关。

## 1. 编写参考任务和机器门禁

选一个能代表部署实际工作负载的任务，把它写成单条逐字提示消息——不做多轮脚本化。编写一个从结构上检查产出物的门禁脚本，全程不启动 `dsh`、不调用模型：把候选代码要读取的工具注册表和主目录都换成桩实现，在一个短超时的子进程里直接导入并驱动候选代码导出的 `apply`/`execute`，只有每一项检查（模块能加载、导出预期的插件形态、注册了预期的工具、在不止一个 fixture 上执行出预期值）都通过时才以 `0` 退出。最后打印一行 `gate=1` 或 `gate=0`——第 3 步的执行器会读取它。在把门禁用于真实运行之前，先用已知通过和已知失败的 fixture 对它做自检。

## 2. 把待测配置作为 `--patch` 叠加层

任何 `dsh` profile 都会按参数顺序把 `--patch <file>.yml` 叠加层堆叠在其组合包之上；每个 patch 按 `id:` 定位一行，要么整体替换它的 `config`，要么插入新行（参见[Profile 与组合包](../architecture.zh.md#profiles-and-bundles)）。`dsh --profile <profile> --dump-config` 会打印带有每一行 id 的组合树——只对这些 id 打 patch，写完叠加层后再跑一次 `--dump-config`，确认 id 确实命中了某一行。

headless profile 完全不挂载 `agent-presets` 服务——它直接基于核心注册表构造一个 `Agent`。这里模型可见的人设文本落在 `id: system-prompt` 的 `config.persona` 字段上，由 headless 组合包自带的 patch 文件负责——而不是 `id: persona` 插件，后者只存在于 agent 预设的组合文件中（`apps/cli/config/agent-presets/*/agent.cordis.yml`）。写叠加层之前先确认待测 profile 里到底是哪个 id 携带人设文本；这两者不可互换，打错 id 的 patch 会悄无声息地什么也不做——没有匹配的行，也不报错。

```yaml
# Disables an LLM-visible tool row: its JSON Schema stops being appended to
# every request. Background services the row's tool depended on stay
# mounted unless they are patched too — check whether another tool resolves
# a provider by name before disabling the row that publishes it.
- id: tool-web
  disabled: true
```

## 3. 对一个干净的工作目录反复运行并记录指标

每次运行前清空任务工作目录。`dsh` 退出后，在 `~/.dsh/sessions/--<工作目录路径，斜杠替换为短横线>--/session-<uuid>/` 下找到它刚写出的会话目录，取运行开始前紧贴着 touch 的标记文件之后新建的那一个——被恢复的会话目录的创建时间可能早于待测的这次运行。解压 `session.jsonl.zstd` 并按换行分隔的 JSON 事件读取，提取：

- **wall** ——`(max turn/end 时间 − min turn/start 时间) / 1000` 秒。不是会话目录自身的时间戳：`session/end-seed` 及其之前的配置事件携带的是会话最初创建的时间，对一次被恢复的运行来说可能早了好几天。
- **steps** ——`step/start` 事件的计数。
- **in_med / in_max** ——从 `chunk.type` 为 `usage` 的 `assistant/chunk` 事件中取出的 `usage.inputTokens` 的中位数/最大值。
- **think_ratio** ——`reasoning-chunks / (reasoning-chunks + text-chunks)`，按事件出现次数计，不按 token 数计。
- **tool_err** ——`tool/result` 事件中携带 `type: 'tool-result'` 且 `isError: true` 的内容块的计数。
- **compactions** ——`compaction/start` 事件的计数。
- **gate** ——若第 1 步的门禁脚本对产出物判定通过则为 `1`，否则为 `0`。

把每次运行的结果各追加一行到一张记录表（`timestamp | lever | session | wall | steps | in_med | in_max | think_ratio | tool_err | compactions | gate`）——一张扁平的 Markdown 表格就够了，它是之后每次运行唯一需要比对的记录。

## 4. 用观测到的离散程度决定样本量，而不是固定次数

先跑基线配置至少三次，计算这几次 `wall` 的 `(max − min) / min`。如果这个离散程度超过 50%，本次比较里之后的每个调整项都测五次，而不是三次——本地小模型在三次采样下的方差足以盖过待测改动的效应量，固定的低 `n` 会以大致相当的比例报出假阳性和假阴性。

## 5. 依据聚合结果判断一个调整项，而不是依据单次运行

把该调整项的聚合结果（`wall` 的均值和中位数、门禁通过率，以及该改动具体针对的那个指标——措辞类改动看 `tool_err`，token 预算类改动看 `compactions`）与基线在同样样本量下的聚合结果做比较。只有在门禁通过率没有变差、且改动具体针对的指标改善幅度超出第 4 步测得的离散程度时才采纳这个调整项——在这个样本量下单看 `wall` 不是可靠信号；一个只挪动了 `wall`、却没挪动它理应引起变化的那个指标的改动，更可能是采样噪声而非真实效应。

## 6. 把已验证的组合打包为 agent 预设

一旦一个或多个调整项被采纳，就把它们收进一个可安装的预设，而不是继续留作零散的叠加层：

```
~/.dsh/.agent-presets/<name>/
  preset.yml         # name + description display text only — trust and discovery
                      # come from the root this directory is found under, not this file
  agent.cordis.yml    # a cordis-plugin-include row + the preset's own delta rows
```

`agent.cordis.yml` 以一行 `cordis-plugin-include` 开头，它的 `config.path` 是指向本套 harness 自带的 `apps/cli/config/agent-presets/standard/agent.cordis.yml` 的**字面、安装时写死的绝对路径**——group 行（include 行正是其一）会跳过加载器的插值，所以这里不能写成 `!!js` 表达式。随后 `config.patches` 对这个被包含的组合内部的 `id:` 打 patch，方式与 `--patch` 叠加层对一个 profile 组合内部的 id 打 patch 相同——但这是另一棵组合树，id 也不同：agent 预设 patch 的是 `id: persona`，不是 `id: system-prompt`。把 headless 叠加层里禁用的 id 列表照搬进预设之前，先对目标标准组合逐个 grep 这些 id——至少有一个 id 在 headless 叠加层里禁用是安全的，放进预设里却是明确不安全的：某个工具行注册的是进程级单例上的一段可续接的初始化，而不是一个普通的按会话工具，如果预设对它打了 patch，同一进程里挂载的第二个预设就会在此抛出。标准组合会在这类 id 所在行旁边的注释里说明。

`dsh --profile <profile> --dump-config` 只显示静态的、编译期的组合树——它永远不反映 `settings.yaml` 里的 `agent-presets.default`，因为该值是在运行期通过 settings 能力动态解析的，不经过静态 patch 树。要验证一个新预设，改用结构性检查（每个被 patch 的 id 都确实存在于目标组合中；预设目录和两个文件都是格式良好的 YAML），并通过一个真正会挂载 agent 预设的入口（headless profile 不会）跑一次参考任务来验证。

## 7. 验证

1. `node <gate-script> --self-test` 在已知通过和已知失败的 fixture 上都通过。
2. 基线，n ≥ 3（若第 4 步的离散程度检查触发则 n ≥ 5）：每次运行的 `gate` 都是 `1`，记录表为每次运行都记下了 wall/steps/in_med/in_max/think_ratio/tool_err/compactions。
3. 每个候选调整项，样本量与基线比较时相同：门禁通过率没有变差，且该调整项针对的指标改善幅度超出第 4 步测得的离散程度。
4. 把已采纳的调整项打包为预设之后：确认每个被 patch 的 id 都存在于目标标准组合中（对 `tool-*` 的 id，还要确认它不是由进程级单例支撑的），并且通过一个挂载 agent 预设的入口跑一次参考任务，全程没有出现加载期错误。

## 本仓库实测的冠军配置

于 2026-08-27 至 29 日在本仓库自己的参考任务上、针对 `qwen/qwen3.8-27b`（Q4_K_M，LM Studio）、按上述流程测得：

| 配置 | n | wall 均值 / 中位数（秒） | gate | tool_err 均值 | compactions 均值 |
|---|---|---|---|---|---|
| 基线 | 3 | 959.6 / 671.4 | 3/3 | 0.33 | 2.33 |
| + 精简工具面 | 5 | 600.5 / 628.7 | 5/5 | 0.80 | 0.00 |
| + 小步人设 | 5 | 694.9 / 496.2 | 5/5 | 0.20 | 0.80 |

已安装的 `local-fast` 预设合并了这两个被采纳的调整项。这个工作负载自身的单次运行间离散程度在 n = 5 时（第 4 步）就已达到约 180%，因此回归检查应当把「五次运行里门禁通过率低于 4/5」或「`wall` 中位数超过上表人设那一行的大约两倍」当作值得深入排查的信号,而不是当作紧凑的统计边界——它本身就不是紧凑的统计边界。完整数据、被拒绝的调整项，以及每次取舍背后的推理都在 [local-fast Agent Note](../../.agents/notes/implemented/feature/2026-08-29-local-fast-preset.zh.md) 中。
