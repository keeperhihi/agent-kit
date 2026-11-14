# agent-kit

我的 Claude Code 和 Codex 配置：全局指令、skills 和客户端偏好，一条命令装到本机。

| 内容 | 位置 |
| --- | --- |
| 全局指令 | `instructions.md` |
| skills | `skills/`；第三方的放在 `vendor/skills/` |
| Claude Code 偏好和状态栏 | `claude/` |
| Codex 偏好 | `codex/config.toml` |
| 网关适配 | `gateways/` |
| Claude Code、Codex 本身的安装和更新 | `update.sh`、`update.ps1` |

## 安装

需要 Python 3.9 或以上。第一次运行会在仓库里建 `.venv` 并下载依赖。

```sh
./install.sh            # Claude Code 和 Codex 都装
./install.sh codex      # 只装其中一个
./install.sh --copy     # 复制文件而不是链接，装完可以删掉仓库
```

装完之后（用不用网关都一样）：

- `CLAUDE.md`、`AGENTS.md` 和各个 skill 都链接到仓库，改仓库里的文件立即生效，增删 skill 后再运行一次安装。
  用 `--copy` 时是复制进去的：重装会用仓库内容覆盖它们，回滚会删掉它们，在上面做的修改都不会保留。
- 客户端的 `skills` 目录里只留仓库的 skill。客户端自带的不动，也就是以点开头的条目（如 Codex 的 `.system`）
  和 Claude Code 的 `synced`。
- firecrawl 的 3 个 skill 只在装了 `firecrawl` 命令时安装。没装时安装器会给出安装命令，装好后再运行一次即可。
- `settings.json`、`config.toml` 只写入仓库里指定的字段，模型、MCP 等其他设置和登录都不动。
- 第一次安装时，被替换掉的文件和 skill 原样备份到 `<客户端目录>/.agent-kit/`，回滚时放回。
  之后再出现在这些位置上的东西，重装时会被直接替换，不再备份。

客户端目录默认是 `~/.claude` 和 `~/.codex`，设置了 `CLAUDE_CONFIG_DIR`、`CODEX_HOME` 时以它们为准。

### Windows

只处理 Codex。先以管理员身份启动 PowerShell，进入仓库目录再运行；加 `-Copy` 或开启了开发者模式时，
普通身份也可以。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Copy
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Gateway magpie
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Gateway codexmanager -CmKey '你的网关 key'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Restore
```

## 使用网关

```sh
./install.sh --gateway magpie
./install.sh codex --gateway codexmanager --cm-key '你的网关 key'
```

网关只在偏好之外额外写配置，指令和 skill 照常安装：

- [CodexManager](gateways/codexmanager/README.md)：把 Codex 接到本机的 CodexManager 网关，写入 `cm` 提供方和网关 key。
- [Magpie](gateways/magpie/README.md)：不额外写配置。装完后 Magpie 会识别装好的指令和 skill，询问是否交给它管理。

换一种方式就直接用新的方式重装，上一个网关写的配置会自动撤掉，CodexManager 替换过的登录也会换回来。

## 回滚

```sh
./install.sh -r
```

回到第一次安装之前的样子：撤掉链接或复制进去的文件，放回备份，偏好字段恢复原值，
之后被你或客户端改过的字段不动；用过的网关写的配置和登录也一并换回。用 `--copy` 装完又删掉了仓库的话，
重新克隆一份再回滚。

## 状态栏

偏好里已经配好 claude-hud 状态栏，插件本身每台机器装一次，需要 Node.js：

```sh
claude plugin marketplace add jarrodwatts/claude-hud
claude plugin install claude-hud@claude-hud
```

## 安装或更新 Claude Code、Codex 本身

```sh
./update.sh --port 7897             # 两个都处理
./update.sh --port 7897 codex
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\update.ps1 -Port 7897
```

通过官方安装器更新到最新版，没装的直接装上。大文件分片并发下载，中断后重跑会续传，不会因为网速慢
被官方安装器的超时打断。`--port` 必须指定：所有请求都走 `http://127.0.0.1:端口` 的代理，
环境变量和系统里的代理设置都不生效。macOS/Linux 需要 curl 7.71 或以上。

## 开发

- 安装逻辑都在 `preferences.py`。网关适配放在 `gateways/<名称>/`，包括 `gateway.json` 和可选的 `adapter.py`；
  `adapter.py` 用 `prepare` 规划安装时要写的字段和文件，用 `release` 规划撤销，再由 `apply` 执行。
- `install.sh` 保持 Bash 3.2 兼容。`update.sh` 用 POSIX sh，因为它要在同一个 shell 里加载官方 Codex 安装器。
  `install.ps1`、`update.ps1` 保持 ASCII 和 Windows PowerShell 5.1 兼容。
- `.gitignore` 是白名单，新增顶层文件要放行。
- skill 的调用策略同时写在 `SKILL.md` 和 `agents/openai.yaml` 里。
- 更新 `vendor/skills/firecrawl` 时保留固定的 CLI 版本和 `--skip-skills`；版本变了，同步 `preferences.py`
  里的 `FIRECRAWL_SETUP`。
- 测试都在临时目录里运行，不碰真实配置。安装测试会从 PyPI 下载一次 tomlkit 的 wheel，更新测试不联网：

  ```sh
  bash tests/install.sh
  bash tests/update.sh
  ```

  Windows 上对应 `tests/install.ps1` 和 `tests/update.ps1`。
- 真实配置目录的安装和回滚，只在用户要求时执行。
