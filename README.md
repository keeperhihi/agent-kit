# agent-kit

个人 AI 指令、skills 和客户端偏好。默认给客户端安装偏好，并把指令和技能直接链接到仓库。
使用网关管理器时，通过 `--gateway` 显式选择相应的安装适配。

| 内容 | 维护位置 | 默认安装方式 |
| --- | --- | --- |
| 共享指令 | `instructions.md` | 链接到客户端的全局指令文件 |
| 自己维护的 skills | `skills/` | 逐个链接到客户端技能目录 |
| 有本地改动的第三方 skills | `vendor/skills/` | 逐个链接到客户端技能目录 |
| Claude Code 偏好与 HUD | `claude/` | 按字段合并 |
| Codex 偏好 | `codex/config.toml` | 按字段合并 |
| 终端、Git、npm、SSH 等 | dotfiles 仓库 | dotfiles 安装器 |
| Claude Code、Codex 本体的安装和更新 | `update.sh`、`update.ps1` | 按需手动运行 |

仓库是指令与 skills 的持续来源，安装后保留仓库目录。账号和密钥由客户端或所选网关
管理，不提交进 Git。默认安装沿用客户端现有的登录和请求接入设置；
选择网关后，接管范围由对应适配说明定义。

## 安装

需要 Python 3.9 或以上。AI 客户端和 Node.js 等运行环境另行安装。

```sh
./install.sh
./install.sh claude
./install.sh codex
```

不指定客户端则处理 Claude Code 和 Codex。安装器遵循 `CLAUDE_CONFIG_DIR`、
`CODEX_HOME`，未设置时使用 `~/.claude`、`~/.codex`。

安装器会自动创建仓库内的 `.venv` 并安装固定版本的 tomlkit。环境完整时直接复用，
不调用 pip、不联网检查。无需手动创建或激活环境，也不会向全局 Python 安装包。
首次准备环境或依赖版本变化时需要下载依赖；准备失败会停止，不修改客户端配置。

### 偏好

只合并以下补丁中的指定字段：

- `claude/settings.json` → Claude Code 的 `settings.json`
- `claude/plugins/claude-hud/config.json` → 同名 HUD 配置
- `codex/config.toml` → Codex 的 `config.toml`

对象逐字段合并，数组作为一个字段整体应用。重装重新应用仓库拥有的字段；
其他字段保留。TOML 使用 tomlkit 保留其他字段的格式和注释。
Claude 偏好包含 `idleCompaction: false`。仓库中的权限偏好允许全权限运行，按个人需要修改。

共用安装逻辑不读写登录文件，也不修改 Shell 启动函数。模型、推理强度、上下文窗口及 MCP
的显式配置保留。CodexManager 适配会在明确选择时设置 Codex 的提供方和 `auth.json`；
默认模式和 Magpie 模式保留现有登录及 API 地址。
遇到格式错误的客户端配置或指向别处的配置文件链接，会在写入前停止。

### 指令和技能

默认创建以下链接：

- Claude Code 的 `CLAUDE.md`、Codex 的 `AGENTS.md` → 仓库 `instructions.md`
- 客户端 `skills/<名称>` → 仓库 `skills/<名称>` 或 `vendor/skills/<名称>`

客户端的 `skills` 目录只保留仓库的技能。客户端自己维护的条目不动：以点开头的隐藏条目
（例如 Codex 自带的 `.system`），以及 Claude Code 存放账号同步技能的 `synced`。

名为 `firecrawl` 或以 `firecrawl-` 开头的技能依赖 Firecrawl CLI，只在 PATH 上有 `firecrawl`
命令时安装。没有这个命令时，安装器跳过它们，并给出安装 CLI 并登录的命令（需要 Node.js），
装好后再运行一次安装即可；已经装上的，之后在没有这个命令时重装也会撤下。

第一次接管时，指令文件和 `skills` 目录里已有的文件、目录或链接原样移入
`<客户端目录>/.agent-kit/resource-backups/`：仓库提供的换成链接，其余的从 `skills` 目录移走。
每个路径只在第一次接管时备份，之后重装时，这些路径上的其他内容会被直接替换。
重复的技能名称会让安装在写入客户端配置前停止。

编辑仓库内已有资源后，客户端通过链接读取新内容。新增、删除技能或移动仓库后，
重新运行安装命令来更新链接。仓库删除的技能会被撤下，接管前的原件留在备份里。

### Windows

Windows 只处理 Codex，使用同一套 Python 实现：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

默认创建指令和技能的符号链接，需要 Windows 开发者模式或相应权限。

## 使用网关

```sh
./install.sh --gateway magpie
./install.sh claude --gateway magpie
./install.sh codex --gateway codexmanager --cm-key '你的网关 key'
```

也接受 `-gateway`。PowerShell 使用 `-Gateway`，CodexManager 的密钥参数为 `-CmKey`。

| 网关 | 接入设置 | 指令和技能 |
| --- | --- | --- |
| 不指定 | 保留客户端现有设置 | 直接链接仓库 |
| [Magpie](gateways/magpie/README.md) | 在 Magpie 中管理 | 由 Magpie 分发 |
| [CodexManager](gateways/codexmanager/README.md) | 配置 `cm` 提供方和网关 API key | 直接链接仓库 |

适配不下载或启动网关软件。网关专属配置和逻辑位于各自目录中。
查看某个适配的参数可用 `./install.sh --gateway codexmanager --help`。

同一客户端的资源只由一种方式管理。从默认安装切换到网关接管前，先回滚该客户端的
原生安装，再按网关说明完成接管。存在 Agent Kit 资源管理记录时，网关接管模式会停止，
避免两边同时维护同一路径。
已有网关凭据管理记录时，切换到其他模式前须先用同一网关选项回滚。

## 回滚

默认安装的回滚同时处理偏好、指令和技能：

```sh
./install.sh -r
./install.sh -r claude
```

网关模式按同一适配规则回滚。Magpie 模式只回滚本仓库应用的偏好：

```sh
./install.sh -r --gateway magpie
./install.sh -r codex --gateway codexmanager
```

Windows 使用 `-Restore`；网关模式同时传入对应的 `-Gateway`。

`.agent-kit/preferences.json` 保存受管字段第一次接管前的值和上次应用值。
这包括选中网关时由其接管的配置字段。
回滚只恢复仍等于上次应用值的字段；用户或客户端之后修改的值保留。
仓库删除一个偏好字段或补丁文件后，重装也按此规则交还该字段。

`.agent-kit/resources.json` 记录直接分发的资源。回滚把备份放回原处，包括从 `skills` 目录
移走的技能；用户后来替换过的目标保留。完成后清理资源记录和对应备份。

旧版本的 `.agent-kit/managed`、`.agent-kit/original/`、`.agent-kit-state`
和 `.agent-kit-backups` 不用于新安装器回滚，也不会被自动清理。
默认安装包含两个技能目录，不再使用 `--with-vendor` 参数。
`--cm-key` 只在显式选择 CodexManager 时有效。

## Claude Code 状态栏

偏好安装会应用 claude-hud 的状态栏与显示设置。插件本体每台机器安装一次，
需要 PATH 上有 Node.js：

```sh
claude plugin marketplace add jarrodwatts/claude-hud
claude plugin install claude-hud@claude-hud
```

已有插件可继续使用。显示配置在 `claude/plugins/claude-hud/config.json`；
`/claude-hud:configure` 修改本机副本，需要长期保留的偏好应同步回仓库。

## 安装和更新 Claude Code、Codex

`update.sh` 通过官方安装器把原生版 Claude Code 和 Codex 更新到最新版本，尚未安装的直接装上最新版。
它只接管其中的大文件下载：按 4 MiB 分片、最多 16 路并发，单个分片失败会自动重试，
不受官方下载时限（Codex 安装器 5 分钟、`claude update` 10 分钟）的影响。
中断后再运行，只补下缺少的分片。

```sh
./update.sh --port 7897
./update.sh --port 7897 codex
```

`--port` 必须指定，填本机代理端口：所有请求都经过 `http://127.0.0.1:端口`，没传就报错，
不开始更新。环境变量里的代理设置会被它覆盖，`no_proxy`、`NO_PROXY` 也会清空，避免有请求绕过代理。
不指定客户端则两个都处理。Windows 使用 `-Port`，同样不走系统代理：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\update.ps1 -Port 7897
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\update.ps1 -Port 7897 claude
```

- Claude Code：已是最新版本时不下载。下载后按官方 manifest 校验 SHA-256，再交给该版本的
  `claude install` 完成安装，安装命令直接使用这份文件，不会重复下载。macOS/Linux 装有 zstd 时
  改下载压缩版，体积约为三分之一。
- Codex：以非交互方式运行官方 `install.sh` 或 `install.ps1`，由它解析版本、校验和安装。
- macOS/Linux 首次安装时，若 `~/.local/bin` 不在 PATH 中，Codex 安装器会把它写入 shell
  配置文件，Claude Code 只提示添加方法。
- macOS/Linux 需要 curl 7.71 或以上。下载中的分片保存在 `~/.cache/agent-kit/downloads/`
  （Windows 为 `%LOCALAPPDATA%\agent-kit\downloads\`），文件拼好后删除。

## 开发与验证

`install.sh` 保持 Bash 3.2 兼容，`install.ps1` 保持 ASCII 与 Windows PowerShell 5.1
兼容；二者使用同一安装实现。配置合并和原生资源安装集中在 `preferences.py`。

网关专属内容放在 `gateways/<名称>/`。`gateway.json` 声明展示名称和资源归属：
`resources: "native"` 使用原生链接，`resources: "gateway"` 由网关管理指令和技能。
该目录的 README 说明软件准备和接管步骤；需要专属实现时也放在该目录。
可选的 `adapter.py` 通过 `add_arguments` 注册参数、`prepare` 生成配置字段变更和附加写入计划、
`apply` 执行附加写入。所有选中客户端的配置和资源预检通过后才写入。
需要认证回滚记录的适配将其放在 `.agent-kit/gateways/<名称>.json`；共用安装器据此阻止未回滚的跨网关切换。

```sh
.venv/bin/python tests/preferences.py
bash tests/install.sh
```

Windows 的 `tests/install.ps1` 验证 Magpie 模式下的偏好安装和回滚。
测试使用临时仓库和配置目录，不读取本机凭据、不调用网关。
环境准备测试使用临时下载的 wheel，之后离线验证创建、补齐依赖和重装。
真实配置的应用与回滚按用户要求执行。

`update.sh` 使用 POSIX sh，因为它要在同一个 shell 中加载官方 Codex 安装器；
`update.ps1` 同样保持 ASCII 与 Windows PowerShell 5.1 兼容，其中的下载函数也在
Codex 安装器的 `Set-StrictMode -Version Latest` 下运行。

```sh
bash tests/update.sh
```

Windows 的 `tests/update.ps1` 验证分片下载、续传、对 Codex 安装包下载的接管和代理设置。
两个更新测试都使用本地服务器 `tests/range_server.py`，它同时充当代理；测试不联网、不安装客户端。

`.gitignore` 使用白名单，新增顶层文件需显式放行。
skill 调用策略同时维护 `SKILL.md` 和 `agents/openai.yaml`；
更新 `vendor/skills/firecrawl` 时保留固定 CLI 版本和 `--skip-skills` 等本地修改；
CLI 版本变化时同步 `preferences.py` 里的 `FIRECRAWL_SETUP`。
