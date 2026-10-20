# agent-kit

Claude Code 与 Codex 的全局指令、skills 和插件配置。

## macOS / Linux 安装

```bash
git clone <repo-url>
cd <repo-directory>
./install.sh                    # 安装到 Claude Code
./install.sh --target codex     # 安装到 Codex
./install.sh --target both      # 同时安装到 Codex
./install.sh --status           # 检查安装状态
./install.sh --target codex --with-vendor  # 同时安装 Firecrawl 等第三方 skill
```

其他选项见 `./install.sh --help`。Claude Code 插件的首次安装命令见 `claude/plugins/<plugin-name>/README.md`。

Claude Code 的 `settings.json` 合并需要 `jq`。

## Windows 安装（Codex）

在仓库目录的 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
# 同时安装第三方 skill：
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -WithVendor
```

使用系统自带的 Windows PowerShell，将配置、`AGENTS.md` 和 `skills/` 复制到 `%USERPROFILE%\.codex`；无需 Git Bash、管理员权限或符号链接支持。命令中的 `-ExecutionPolicy Bypass` 只对本次 PowerShell 进程生效，不修改系统执行策略。

已有同名目标默认保留。需要更新时，在上述命令末尾加 `-Force`，先备份到 `%USERPROFILE%\.codex\.agent-kit-backups\<run-id>\`，再整体替换本次选中的配置、指令文件和同名 skill。Windows 安装不合并 TOML；已有本机设置时，可以保留默认跳过行为并手动更新配置，或在覆盖后从备份恢复相应字段。其他名称的 skill 和 `auth.json` 不受影响。

也可以在新设备上手动将 `codex/config.toml.tmpl` 复制为 `%USERPROFILE%\.codex\config.toml`；这种方式只安装配置。

## 可选第三方 skills

默认只安装 `skills/` 中的 24 个通用 skill。`vendor/skills/` 保留 Firecrawl 系列等依赖外部服务或额外认证的第三方 skill，目前共 3 个；macOS/Linux 使用 `--with-vendor`，Windows 使用 `-WithVendor` 才会一并安装。`vendor/skills/firecrawl` 已按 Firecrawl CLI 1.19.27 和本仓库保留的 skill 做过本地修改：删去已移除 skill 的引用和过时命令，并给 `firecrawl init` 加上 `--skip-skills`，防止它把上游整套 skill 再装进各 agent 的 skills 目录。从上游同步时需重新核对这些改动。

这些参数只控制本次安装内容；不带参数重新安装不会卸载已经安装的第三方 skill。安装器只安装 skill 文件，不进行服务登录，也不写入 API key 或添加 MCP 配置；使用第三方服务时再按对应 skill 的说明配置认证。

## CodexManager 首次配置

前提：已安装 Codex 客户端，并启动 CodexManager 网关。模板使用 `http://localhost:48760/v1`，网关需提供 `gpt-6-astra` 的 Responses API。以下步骤使用 Codex 的默认配置目录；若设置了 `CODEX_HOME`，应把配置和凭证放进该目录。

| 系统 | 默认配置目录 |
| --- | --- |
| macOS / Ubuntu | `~/.codex` |
| 原生 Windows | `%USERPROFILE%\.codex` |

1. 按上面的方式安装配置。
2. 在配置目录创建 `auth.json`，将占位内容替换为自己的 **CodexManager 网关 key**：

   ```json
   {
     "auth_mode": "apikey",
     "OPENAI_API_KEY": "YOUR_CODEXMANAGER_API_KEY"
   }
   ```

3. 完全退出并重新启动 Codex，新建会话。

模板通过 `cli_auth_credentials_store = "file"` 和 `[model_providers.cm]` 内的 `requires_openai_auth = true` 使用该文件，无需另外设置 API key 环境变量。认证机制见 [OpenAI 官方认证文档](https://learn.chatgpt.com/docs/auth#alternative-model-providers)。安装器不创建、读取或覆盖 `auth.json`。

模板默认使用 `gpt-6-astra`，普通模式与 Plan 模式都设为 `max`，权限设为 `Full access`（`approval_policy = "never"`、`sandbox_mode = "danger-full-access"`）。`desktop.enabled-reasoning-efforts` 按 Windows App 的实测需要保留；它是桌面端设置，不能替代网关和模型对 `max` 的支持。已有会话的模型、推理强度和权限可能保留会话自己的选择，检查模板时应使用新会话。字段说明见 [官方配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)。

模板保留网关连接、凭证存储约定和个人偏好，不重复声明已确认的客户端默认值。`/review` 跟随当前会话模型；`model_verbosity` 和 `service_tier` 作为可调整的回答长度与服务档位保留。`cli_auth_credentials_store = "file"` 虽然也是当前默认值，仍显式保留以表达 `auth.json` 的存储约定。桌面端字段的默认值未公开，按个人偏好保留。

上下文容量和自动压缩阈值使用模型默认值。若旧机器已设置 `model_context_window` 或 `model_auto_compact_token_limit`，需手动删除本机这些覆盖项才能恢复模型默认值；macOS/Linux 的 overlay 安装不会删除模板之外的键。

旧配置中的 `model_supports_reasoning_summaries` 也应手动删除；当前 [官方 JSON schema](https://learn.chatgpt.com/docs/config-schema.json) 已不包含此字段。摘要详细程度仍由 `model_reasoning_summary = "detailed"` 指定。

Windows 原生客户端与 WSL 默认使用不同的配置目录。运行在 WSL 中时，应按 Linux 环境配置，并确认该环境能够访问网关；目录说明见 [官方 Windows 文档](https://learn.chatgpt.com/docs/windows/windows-app#share-config-auth-and-sessions-with-wsl)。

## 目录

```text
skills/                         通用 skills
vendor/skills/                  可选第三方 skills，默认不安装
vendor/skill-lock.json          第三方 skill 的来源与版本
claude/
  CLAUDE.md                     链接到 ../codex/AGENTS.md
  settings.json                 可移植设置
  agents/                       自定义 subagents
  commands/                     自定义 slash commands
  plugins/                      插件安装说明与可移植配置
codex/
  AGENTS.md                     全局指令的唯一源文件
  config.toml.tmpl              Codex 可移植配置 overlay
install.sh                      macOS / Linux 安装器
install.ps1                     Windows Codex 安装器
```

## 约定

- `claude/settings.json` 是可移植配置 overlay：安装时递归合并到 `~/.claude/settings.json`。
- overlay 中的字段以仓库值为准；本机独有字段保留；数组整体替换，不进行拼接。
- 从 overlay 删除字段只表示停止管理，不会从本机 `settings.json` 删除已有字段。
- macOS/Linux 上，`codex/config.toml.tmpl` 作为可移植配置 overlay：安装时覆盖模板中的键，并追加本机缺少的键/表；本机独有键、表和注释保留。
- Codex 的数组值与 Claude 的数组一样整体替换，不进行拼接；从模板删除字段只表示停止管理，不会从本机 `config.toml` 删除已有字段。
- macOS/Linux 上，其他受管文件使用符号链接。已有目标默认不覆盖；使用 `--force` 时先备份再覆盖。Claude 备份写入 `~/.claude/.agent-kit-backups/<run-id>/`，Codex 备份写入 `~/.codex/.agent-kit-backups/<run-id>/`，并保留各自配置目录下的相对路径；不在用户 home 根目录创建备份目录。
- 编辑全局指令时修改 `codex/AGENTS.md`；`claude/CLAUDE.md` 只作为指向它的链接。
- skill 的调用策略两边分别声明：Claude 用 `SKILL.md` frontmatter 的 `disable-model-invocation: true`，Codex 用同一 skill 目录下 `agents/openai.yaml` 的 `policy.allow_implicit_invocation: false`；新增或修改时两处保持一致。`agents/openai.yaml` 的 `interface` 是 Codex 界面的显示名和简介，Claude 不读取。
- `--force` 不是合并 settings/config 的前提，只会在合并前额外创建备份。
- `claude/plugins/<plugin-name>/files/` 映射到该插件的用户配置目录。
- 插件本体、Marketplace、缓存和注册表不纳入仓库。
- Codex 的机器专属配置（信任目录、模型目录绝对路径、带本机路径的 MCP、插件/Marketplace 状态等）不会从本机回写模板；模板只保留跨机器的偏好。
- 凭证、会话记录、数据库、`settings.local.json` 和机器专属路径不入库。
- 全局指令禁止把 hash、checksum、fingerprint、重复审计和假想边界检查当作默认防御手段；只有功能本身、用户明确要求或项目明确要求时才加入。安全、迁移、验证与审阅要求优先。

`claude/settings.json` 和 `codex/config.toml.tmpl` 只放需要跨机器统一的字段，不直接将完整的本机配置复制回仓库。使用 `./install.sh --status` 检查两个 overlay 是否已生效。
