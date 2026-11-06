# agent-kit

Claude Code 与 Codex 的全局指令、skills 和配置。默认安装 Codex，并将模型请求指向本机 CodexManager 网关。

执行安装会先备份已有目标，再用仓库版本完整替换。配置的来源是仓库：需要统一调整时，直接编辑仓库文件，再重新安装。

## macOS / Linux

在克隆后的仓库目录运行：

```bash
./install.sh --cm-key 'YOUR_CODEXMANAGER_KEY'
```

不传 `--cm-key` 也能完成安装，生成的 `auth.json` 中 `OPENAI_API_KEY` 为空，之后需要手动填写。

```bash
./install.sh                            # 默认安装 Codex，key 留空
./install.sh --dry-run                   # 预览，不写入文件
./install.sh --status                    # 检查安装文件，不验证网关或凭证
./install.sh --with-vendor --cm-key 'YOUR_CODEXMANAGER_KEY'
./install.sh --target claude             # 安装 Claude Code 的配置与 skills
./install.sh --target both --cm-key 'YOUR_CODEXMANAGER_KEY'
```

使用 Bash 和系统文件工具；安装 Claude 插件配置还需要 Git。安装不依赖 jq、Python 或 TOML 解析器。其他选项见 `./install.sh --help`。

配置和凭证安装为普通文件；全局指令、skills、Claude agents/commands 和插件配置使用符号链接。安装后请保留仓库目录。`--uninstall` 只移除指向本仓库的链接，配置、凭证和备份仍保留。

## Windows（Codex）

在仓库目录的 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 --cm-key 'YOUR_CODEXMANAGER_KEY'
# key 留空：
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
# 同时安装第三方 skills：
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -WithVendor -CmKey 'YOUR_CODEXMANAGER_KEY'
```

直接在 PowerShell 内调用脚本时，使用 `.\install.ps1 -CmKey 'YOUR_CODEXMANAGER_KEY'`。上面的 `--cm-key` 写法用于 `powershell.exe -File` 命令。

使用系统自带的 Windows PowerShell，安装内容全部复制到配置目录；无需 Git Bash、管理员权限或符号链接支持。`-ExecutionPolicy Bypass` 只对这次 PowerShell 进程生效。

## 配置目录与备份

| 目标 | 默认配置目录 | 自定义目录 |
| --- | --- | --- |
| Codex，macOS / Linux | `~/.codex` | `CODEX_HOME` |
| Codex，Windows | `%USERPROFILE%\.codex` | `CODEX_HOME` |
| Claude Code，macOS / Linux | `~/.claude` | `CLAUDE_CONFIG_DIR` |

每次安装的备份写入 `<配置目录>/.agent-kit-backups/<run-id>/`，保留原相对路径。例如 `config.toml`、`auth.json` 和 `skills/example/` 都在同一个运行目录下。已有且指向当前仓库的 Unix 符号链接无需替换；其他同名目标在替换前备份。Unix 上会备份有效符号链接指向的内容，以便恢复；断开的链接保留链接本身。

macOS/Linux 新建的备份目录权限为 `700`，`auth.json` 为 `600`。备份可能包含旧登录凭证，应按凭证文件保管。安装器不会将 key 打印到输出中；命令行参数可能出现在 shell 历史和进程参数里，需要避免时可以省略 `--cm-key`，之后编辑本机 `auth.json`。

恢复时先退出客户端，移除安装后的对应文件或同名 skill，再将备份中的对应条目移回原路径。对于符号链接，只删除链接本身，避免通过链接编辑仓库内容。未出现在备份里的条目表示该次安装没有替换它。

## 安装会影响什么

| 内容 | 安装行为及影响 |
| --- | --- |
| Codex `config.toml` | 完整替换。原有信任目录、模型/推理选择、profiles、自定义 MCP、provider、插件开关和界面偏好等，只要不在模板中，就不再保留在该文件里；原文件在备份中。 |
| Codex `auth.json` | 备份旧文件后写入新的 API key 登录配置。传入 `--cm-key` 时写入该值，省略时写入空字符串；重新安装也遵循此规则。旧 ChatGPT 登录信息或旧 key 留在备份中。 |
| Claude `settings.json` | 完整替换。模板之外的 hooks、插件启用记录、权限规则、环境变量和 `statusLine` 等需要重新配置。 |
| 全局指令、同名 skills、选中的 Claude agents/commands 和插件配置 | 替换为仓库内容；旧内容先备份。 |
| 其他名称的 skills、未选中的 vendor skills | 保留。 |
| 会话、历史、数据库、插件本体与缓存、项目配置 | 安装器不修改这些文件。项目配置和环境变量仍可能影响客户端行为。 |

因此，影响不只受信任目录。尤其是自定义 MCP、插件和登录方式，切换后可能需要重新设置。Claude HUD 的 `statusLine` 由插件按机器生成，重新安装 Claude 配置后需要再运行 `/claude-hud:setup`；首次安装插件的步骤见 `claude/plugins/<plugin-name>/README.md`。

## CodexManager

前提是已经安装 Codex 客户端和 CodexManager，并启动网关。安装器配置客户端连接，不负责安装或启动这些程序，也不向 CodexManager 导入账号。

模板使用 `http://localhost:48760/v1`。传入的 key 应当是 **CodexManager 网关 key**。安装器生成：

```json
{
  "auth_mode": "apikey",
  "OPENAI_API_KEY": ""
}
```

模板通过 `cli_auth_credentials_store = "file"` 和 `[model_providers.cm]` 下的 `requires_openai_auth = true` 读取该凭证。认证机制见 [OpenAI 官方认证文档](https://learn.chatgpt.com/docs/auth#alternative-model-providers)。空 key 只用于待配置状态，不能代替网关认证。

安装后完全退出并重新启动 Codex，再新建会话，选择网关提供的模型和推理强度。模板不固定这两个选项，重新安装会清除之前写在全局配置中的选择。已有会话可能保留自身的设置。

模板保留个人偏好，包括 Full access（`approval_policy = "never"`、`sandbox_mode = "danger-full-access"`）、`model_context_window = 1000000` 和桌面界面设置。上下文设置不能增加模型或网关实际支持的容量，使用的模型仍需与网关能力匹配。字段说明见 [官方配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)。

Windows 原生客户端与 WSL 使用不同的配置目录。在 WSL 中使用 Linux 安装方式，并确认 WSL 能访问模板中的网关地址。默认本机地址不保证能直接访问 Windows 主机上的网关，按实际网络环境调整仓库模板。

## 可选第三方 skills

默认安装 `skills/` 中的通用 skills。`vendor/skills/` 中的 Firecrawl 等第三方 skills 使用 macOS/Linux 的 `--with-vendor` 或 Windows 的 `-WithVendor` 选择安装。

该选项只控制本次安装内容，不带选项重新安装会保留已安装的 vendor skills。安装器只安装这些 skill 文件；第三方服务的登录和认证按各自 skill 的说明完成。

`vendor/skills/firecrawl` 已按 Firecrawl CLI 1.19.27 和本仓库保留的 skill 做过本地修改，包括 `firecrawl init --skip-skills`，从上游同步时需核对这些改动。

## 目录与维护

```text
skills/                         通用 skills
vendor/skills/                  可选第三方 skills
vendor/skill-lock.json          第三方 skill 的来源与版本
claude/
  CLAUDE.md                     指向 ../codex/AGENTS.md
  settings.json                 Claude 全局配置
  agents/                       自定义 subagents
  commands/                     自定义 slash commands
  plugins/                      插件安装说明与可移植配置
codex/
  AGENTS.md                     全局指令的唯一源文件
  config.toml.tmpl              Codex 全局配置模板
install.sh                      macOS / Linux 安装器
install.ps1                     Windows Codex 安装器
```

- 全局指令在 `codex/AGENTS.md` 中维护。
- 调整公共配置时编辑 `claude/settings.json` 或 `codex/config.toml.tmpl`。只写入可跨机器共用的设置，凭证和机器专属路径留在本机。
- skill 的调用策略分别由 Claude 的 `SKILL.md` frontmatter 和 Codex 的 `agents/openai.yaml` 声明；新增或修改时保持一致。
- `claude/plugins/<plugin-name>/files/` 映射到该插件的用户配置目录。插件本体、Marketplace、缓存和注册表由客户端管理。
- 凭证、会话记录、数据库和 `settings.local.json` 不入库。

安装回归测试使用临时目录：macOS/Linux 运行 `for test_file in tests/*.sh; do bash "$test_file" || break; done`（测试需要 jq）；Windows 运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\install_windows_test.ps1`。
