# agent-config

我的 coding agent 配置：全局指令 + skills，一份内容同时给 **Claude Code**（`~/.claude`）和 **Codex**（`~/.codex`）用。

新机器上：

```bash
git clone <this-repo> ~/workspace/agent-config
cd ~/workspace/agent-config
./install.sh                    # 装到 ~/.claude
./install.sh --target both      # 顺带装到 ~/.codex
```

## 结构

```
skills/          我自己的 24 个 skill —— 单一事实源，两个 agent 共用
vendor/skills/   第三方 skill（firecrawl 全家桶，32 个）
vendor/skill-lock.json   第三方 skill 的来源与版本，用于日后重新同步
claude/
  CLAUDE.md      Claude Code 的全局指令
  settings.json  可提交的那部分设置
  agents/        自定义 subagent（*.md）
  commands/      自定义 slash command（*.md）
codex/
  AGENTS.md      → 符号链接到 ../claude/CLAUDE.md，两边永远同一份内容
  config.toml.tmpl  Codex 配置模板，机器专属部分留空待填
install.sh
```

## install.sh

```bash
./install.sh                      # 装到 ~/.claude
./install.sh --target codex       # 装到 ~/.codex
./install.sh --target both
./install.sh --dry-run            # 只看会做什么
./install.sh --status             # 检查安装状态与漂移
./install.sh --force              # 目标已存在时，备份为 .bak.<时间戳> 再覆盖
./install.sh --no-vendor          # 不装第三方 skill
./install.sh --uninstall          # 只删本仓库装出去的符号链接
```

默认**不覆盖任何已存在的文件**——遇到冲突就跳过并打印提示，要覆盖得显式 `--force`（会先备份）。`--uninstall` 只删指向本仓库的符号链接，普通文件一律不碰。

## 几个设计决定

**除 settings.json 外一律用符号链接。** 在哪台机器上改了 skill，仓库里 `git diff` 立刻看得到，不用记着同步回来——这是这个仓库的全部意义。Claude Code 的 skill 加载器显式接受符号链接目录，所以这条路走得通。

**settings.json 是拷贝，不是链接。** 因为 Claude Code 自己会重写它（`/model`、`/config`、主题切换都会写），做成链接的话每次调档位都会弄脏仓库。想把本机改动收回仓库：

```bash
cp ~/.claude/settings.json claude/settings.json
```

`./install.sh --status` 会提示两边是否已经漂移。

**skill 里不写死 "Codex" 或 "Claude"，统一说 "the agent"。** 这是一份 skill 能被两个 agent 共用的前提，比维护两份分叉划算。新写 skill 时请守住这条。

**`vendor/` 里的第三方 skill 直接 vendoring 进来（共 376K 纯 markdown），不依赖任何 skill 安装器。** 新机器上 clone 完就能用，代价是它们会随上游更新而变旧——需要时照 `vendor/skill-lock.json` 里的 source 重新同步。

## 从 Codex 迁过来时改了什么

- `code-review` → **`two-axis-review`**：Claude Code 有内置的 `/code-review`（含 `ultra` 云端模式），同名会互相遮蔽。`tdd` / `ask-matt` / `implement` 里的交叉引用已同步改掉。
- 删掉了每个 skill 里的 `agents/openai.yaml`：Codex 专有的 UI 元数据（display_name / short_description），Claude Code 不读。其中唯一有行为含义的是 `policy.allow_implicit_invocation: false`（= 只许用户斜杠触发）；16 个带该策略的 skill 里有 13 个在 SKILL.md frontmatter 已有等价的 `disable-model-invocation: true`，**`humanizer-zh` 和 `research` 两个没有，已补上**，否则删掉 yaml 后它们会变成模型可自主调用。
- `humanizer-zh` / `research` 的描述里，Codex 的调用语法 `$skill-name` 改成了 Claude Code 的 `/skill-name`。
- `andrej-karpathy-skill` 里的 "Codex" 字样改成中性表述。**注意它和 `claude/CLAUDE.md` 内容高度重合**（同一套 Karpathy 四条），一个常驻 context、一个按需加载。想省 token 的话可以删掉这个 skill 只留 CLAUDE.md。
- Codex 侧的 `.system/` 内置 skill、`plugins/`（visualize）、`rules/default.rules`、`mcp_servers.openaiDeveloperDocs` 都没搬——Claude Code 有对应物，或纯属 OpenAI 专用。

## 绝不入库

`.gitignore` 是白名单式的（默认忽略一切），因为这个仓库紧挨着配置目录，误拷的代价很大。以下东西即使手滑 `cp` 进来也会被挡掉：

- `auth.json`、`.credentials.json`、`~/.claude.json`（含 OAuth 与 machineID）
- `history.jsonl`、`session_index.jsonl`、`sessions/`
- `*.sqlite*`（Codex 那个 `logs_2.sqlite` 有 6.4 GB）
- `settings.local.json`（机器专属设置与密钥放这里）
- Codex `config.toml` 里的 `[projects."/abs/path"]` 信任列表、`model_catalog_json` 绝对路径、私有网关 IP —— 所以入库的是 `config.toml.tmpl` 而不是 `config.toml`
