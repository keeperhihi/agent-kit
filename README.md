# agent-kit

个人 AI 指令、skills 和客户端偏好。Magpie 管理账号、网关、模型、推理强度、
上下文、MCP，以及指令和 skills 向各客户端的分发。

| 内容 | 维护位置 | 应用方式 |
| --- | --- | --- |
| 共享指令 | `instructions.md` | Magpie 关联本地文件 |
| 自己维护的 skills | `skills/` | Magpie 从本地文件夹添加 |
| 有本地改动的第三方 skills | `vendor/skills/` | Magpie 从本地文件夹添加 |
| Claude Code 偏好与 HUD | `claude/` | `./install.sh claude` 按字段合并 |
| Codex 偏好 | `codex/config.toml` | `./install.sh codex` 按字段合并 |
| 终端、Git、npm、SSH 等 | dotfiles 仓库 | dotfiles 安装器 |

仓库是指令与 skills 的持续来源，关联后保留仓库目录。修改来源路径时，
在 Magpie 中重新关联。账号和密钥保存在 Magpie，不提交进 Git。

## 应用个人偏好

本机需要 Python 3.9 或以上。直接运行安装入口即可：

```sh
./install.sh
```

安装器会在仓库中自动创建 `.venv`，并安装 `requirements.txt` 中固定版本的
tomlkit。已有环境会复用；依赖已符合版本要求时，直接应用偏好，不调用 pip，
不联网检查。无需手动创建或激活环境，也不会向全局 Python 安装包。
首次准备环境或依赖版本变化时需要下载依赖；准备失败会停止，不修改客户端配置。
JSON 使用 Python 标准库；TOML 使用 tomlkit 保留其他字段的格式和注释。

默认应用 Claude Code 和 Codex，也可以只指定一个。安装器遵循
`CLAUDE_CONFIG_DIR`、`CODEX_HOME`，未设置时使用 `~/.claude`、`~/.codex`。
它只修改三个偏好文件里的指定字段：

- `claude/settings.json` → Claude Code 的 `settings.json`
- `claude/plugins/claude-hud/config.json` → 同名 HUD 配置
- `codex/config.toml` → Codex 的 `config.toml`

这些文件是偏好补丁，不是可直接覆盖客户端配置的完整模板。对象逐字段合并，
数组作为一个字段整体应用。重装重新应用仓库拥有的字段；模型、提供方、
客户端新增的其他字段保留。仓库中的权限偏好仍允许全权限运行，按个人需要修改。

安装器不管理 `auth.json`、指令文件、skills 或 MCP，也不创建、删除它们。
遇到格式错误的客户端配置或指向别处的配置文件链接，会在写入前停止。

Windows 只应用 Codex，同样自动准备环境并使用这一套 Python 实现：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

### 回滚与删除偏好

```sh
./install.sh -r
./install.sh -r codex
```

Windows 使用 `-Restore`。各客户端目录中的 `.agent-kit/preferences.json`
只保存受管字段第一次接管前的值和上次应用值，不保存整个客户端配置。
回滚只恢复仍等于上次应用值的字段；用户或客户端之后修改的值保留，
同一对象里的其他字段保留。仓库删除一个偏好字段或补丁文件后，重装也按此规则交还该字段。

旧版本的 `.agent-kit/managed`、`.agent-kit/original/`、`.agent-kit-state`
和 `.agent-kit-backups` 不用于新安装器回滚，也不会被自动清理。
不再支持 `--cm-key`、`--with-vendor` 等旧参数；第三方 skills 在 Magpie 中选择。

### Claude Code 状态栏

偏好安装会应用 claude-hud 的状态栏与显示设置。插件本体每台机器安装一次，
需要 PATH 上有 Node.js：

```sh
claude plugin marketplace add jarrodwatts/claude-hud
claude plugin install claude-hud@claude-hud
```

已有插件可继续使用。显示配置在 `claude/plugins/claude-hud/config.json`；
`/claude-hud:configure` 修改本机副本，需要长期保留的偏好应同步回仓库。

## 在 Magpie 中设置

先用 Magpie 的备份功能保存当前可用状态。带登录信息的备份需明确选择包含登录，
CLI 对应 `magpie backup --sign-ins`；备份和口令单独保存。

### 共享指令

1. 资源库 → 指令 → 新建一套，命名为 `agent-kit`。
2. 在点「添加」之前，选择「保存在一个文件里…」，填写本机仓库的完整路径，
   例如 `/Users/jin/Workspace/agent-kit/instructions.md`，然后点「添加」。
3. 展开新建的指令，确认已读取现有文件内容，并确认这套指令处于使用中。
4. 开启需要使用这些指令的客户端开关。

以后主要编辑仓库的 `instructions.md`，Magpie 会同步到各客户端。
通过 Magpie 编辑关联指令也会写回这个文件，应检查 Git diff 后再提交。

旧版安装曾创建以下链接，仓库结构调整后它们可能已失效：

```text
~/.codex/AGENTS.md  → agent-kit/codex/AGENTS.md
~/.claude/CLAUDE.md → agent-kit/claude/CLAUDE.md
```

在开启指令分发前，确认是这些旧的失效链接再移除链接本身；保留仓库顶层的
`instructions.md`。不要把共享指令来源设成 Magpie 正要写入的客户端指令文件。
对于仓库位于 `~/Workspace/agent-kit` 的这台机器，可用以下命令只移除对应旧链接：

```sh
if [ -L "$HOME/.codex/AGENTS.md" ] && \
   [ "$(readlink "$HOME/.codex/AGENTS.md")" = "$HOME/Workspace/agent-kit/codex/AGENTS.md" ] && \
   [ ! -e "$HOME/.codex/AGENTS.md" ]; then
  unlink "$HOME/.codex/AGENTS.md"
fi
if [ -L "$HOME/.claude/CLAUDE.md" ] && \
   [ "$(readlink "$HOME/.claude/CLAUDE.md")" = "$HOME/Workspace/agent-kit/claude/CLAUDE.md" ] && \
   [ ! -e "$HOME/.claude/CLAUDE.md" ]; then
  unlink "$HOME/.claude/CLAUDE.md"
fi
```

### Skills

资源库 → 技能，从本地文件夹添加仓库的 `skills/`，选择需要启用的客户端。
`vendor/skills/` 单独添加；其中 Firecrawl skills 有本地修改，应继续使用本地来源。
已经被发现的同一份 skills 可从「发现」列表导入，核对来源仍指向本仓库，避免重复添加。
源文件留在仓库，客户端的链接和启用范围交给 Magpie。新机器需克隆仓库并重新关联本地来源。

### MCP 与客户端

资源库 → MCP 服务器，添加或导入需要的服务器。原来的 OpenAI 文档 MCP 为：

```text
名称：openaiDeveloperDocs
URL：https://developers.openai.com/mcp
```

将它分配给需要的客户端。已有条目先导入或复用，避免重复。
模型、账号、推理强度继续在 Magpie 的供应商、路由和 Agent 页面设置。
应用仓库偏好不会重置这些选择。新开客户端会话验证指令、skills 和实际请求路由。

## 开发与验证

`install.sh` 保持 Bash 3.2 兼容，`install.ps1` 保持 ASCII 与 Windows PowerShell 5.1
兼容；二者只是同一偏好实现的入口。结构化配置合并集中在 `preferences.py`，
不要再在 Shell 或 PowerShell 中维护另一套解析与合并逻辑。

```sh
.venv/bin/python tests/preferences.py
bash tests/install.sh
```

Windows 运行 `tests/install.ps1`。测试使用临时仓库和配置目录，不读取本机凭据、
不调用 Magpie。环境准备测试使用临时下载的 wheel，之后离线验证创建、补齐依赖和重装。
真实配置的应用与回滚按用户要求执行。
`.gitignore` 使用白名单，新增顶层文件需显式放行。
skill 调用策略同时维护 `SKILL.md` 和 `agents/openai.yaml`；
更新 `vendor/skills/firecrawl` 时保留固定 CLI 版本和 `--skip-skills` 等本地修改。
