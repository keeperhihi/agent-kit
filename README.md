# agent-kit

## 致程序员

本项目用于管理 Claude Code 和 Codex 的全局指令、skills 和配置。

### 安装

```sh
git clone https://github.com/KeeperHihi/agent-kit.git
cd agent-kit
./install.sh --cm-key '<key>'   # <key> 是 CodexManager 网关 key
```

默认两个客户端都装，只装一个就加上 `claude` 或 `codex`，比如 `./install.sh claude`。Windows 只支持 Codex，在仓库目录的 PowerShell 里运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -CmKey '<key>'
```

装之前请留意：

- 装的是副本，装完可以删掉仓库。
- 安装是替换，不是合并。本机已有的同名文件（`settings.json`、`config.toml`、`auth.json`、全局指令、skills 等）会换成仓库版本，原样在第一次被替换时存进配置目录（`~/.claude`、`~/.codex`）下的 `.agent-kit/`。
- 这是作者的个人配置：Claude Code 默认 Opus、xhigh 推理强度，Codex 走本机 CodexManager 网关（`localhost:48760`），两边都以全权限运行、不弹确认。不合适就先改 `claude/settings.json`、`codex/config.toml` 再装。

只想要 skills 的话，把 `skills/` 下需要的目录复制到 `~/.claude/skills/` 或 `~/.codex/skills/` 就行。

### 回滚

```sh
./install.sh -r
```

恢复成第一次安装之前的样子，并删除 `.agent-kit/`。Windows 用 `-Restore`。

### 改配置

改仓库里的文件，再重新运行安装。受管文件以仓库为准：在本机直接改的内容，包括客户端自己写进去的设置（`/model`、Codex 记下的信任目录等），重装时都会被覆盖；仓库里删掉的 skill，重装时会从本机移除。不带 `--cm-key` 时，`auth.json` 里已有的 CodexManager key 会保留。

### Claude Code 状态栏

状态栏用 claude-hud。状态栏命令和显示配置随安装装好，插件本体每台机器装一次，需要 PATH 上有 node：

```sh
claude plugin marketplace add jarrodwatts/claude-hud
claude plugin install claude-hud@claude-hud
```

不用再跑 `/claude-hud:setup`。更新插件用 `claude plugin update claude-hud@claude-hud`，状态栏会自动用已装的最新版。显示配置在 `claude/plugins/claude-hud/config.json`，`/claude-hud:configure` 只改本机副本，重装会被覆盖。

## 致 Agent

先看 `install.sh`：装哪些文件、装到哪、怎么记录和恢复原样，都在里面。

| 位置 | 内容 |
| --- | --- |
| `instructions.md` | 全局指令，装成 `CLAUDE.md` 和 `AGENTS.md` |
| `claude/`、`codex/` | 每个文件装到对应配置目录的同一相对路径，隐藏文件除外 |
| `skills/` | 两边共用的 skills |
| `vendor/skills/` | 第三方 skills，`--with-vendor` 才装；来源见 `vendor/skill-lock.json` |
| `install.ps1` | Windows 安装器，只装 Codex |
| `tests/` | 两个安装器的测试，只用临时目录 |

约定：

- 两个安装器行为一致，改一个就同步另一个。
- 配置只放跨机器通用的设置，凭证、本机路径和代理不入库。
- skill 的调用策略写在 `SKILL.md` 的 `disable-model-invocation` 和 `agents/openai.yaml` 的 `allow_implicit_invocation` 两处，保持一致。
- `.gitignore` 是白名单，新增顶层路径要显式放行。
- `install.sh` 要兼容 macOS 自带的 Bash 3.2 和 BSD 工具，不引入 jq、Python 等依赖；`install.ps1` 只用 ASCII，兼容 Windows PowerShell 5.1。
- `vendor/skills/firecrawl` 有本地改动（固定 CLI 版本、`--skip-skills`），同步上游时核对。

改完跑测试（需要 jq）：

```sh
bash tests/install.sh
```

macOS 上用 `/bin/bash tests/install.sh` 可以顺带验证 Bash 3.2。Windows 安装器对应 `tests/install.ps1`。真实配置目录的安装和回滚按用户请求执行。
