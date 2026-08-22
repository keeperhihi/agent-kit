# agent-kit

Claude Code 与 Codex 的全局指令、skills 和插件配置。

## 安装

```bash
git clone <repo-url>
cd <repo-directory>
./install.sh                    # 安装到 Claude Code
./install.sh --target both      # 同时安装到 Codex
./install.sh --status           # 检查安装状态
```

其他选项见 `./install.sh --help`。Claude Code 插件的首次安装命令见 `claude/plugins/<plugin-name>/README.md`。

Claude Code 的 `settings.json` 合并需要 `jq`。

## 目录

```text
skills/                         自定义 skills
vendor/skills/                  第三方 skills
vendor/skill-lock.json          第三方 skill 的来源与版本
claude/
  CLAUDE.md                     Claude Code 全局指令
  settings.json                 可移植设置
  agents/                       自定义 subagents
  commands/                     自定义 slash commands
  plugins/                      插件安装说明与可移植配置
codex/
  AGENTS.md                     与 claude/CLAUDE.md 共用内容
  config.toml.tmpl              Codex 可移植配置 overlay
install.sh
```

## 约定

- `claude/settings.json` 是可移植配置 overlay：安装时递归合并到 `~/.claude/settings.json`。
- overlay 中的字段以仓库值为准；本机独有字段保留；数组整体替换，不进行拼接。
- 从 overlay 删除字段只表示停止管理，不会从本机 `settings.json` 删除已有字段。
- `codex/config.toml.tmpl` 也作为可移植配置 overlay：安装时覆盖模板中的键，并追加本机缺少的键/表；本机独有键、表和注释保留。
- Codex 的数组值与 Claude 的数组一样整体替换，不进行拼接；从模板删除字段只表示停止管理，不会从本机 `config.toml` 删除已有字段。
- 其他受管文件使用符号链接。已有目标默认不覆盖；使用 `--force` 时先备份再覆盖。
- `--force` 不是合并 settings/config 的前提，只会在合并前额外创建备份。
- `claude/plugins/<plugin-name>/files/` 映射到该插件的用户配置目录。
- 插件本体、Marketplace、缓存和注册表不纳入仓库。
- Codex 的机器专属配置（信任目录、模型目录绝对路径、带本机路径的 MCP、插件/Marketplace 状态等）不会从本机回写模板；模板只保留跨机器的偏好。
- 凭证、会话记录、数据库、`settings.local.json` 和机器专属路径不入库。
- 全局指令禁止把 hash、checksum、fingerprint、重复审计和假想边界检查当作默认防御手段；只有功能本身、用户明确要求或项目明确要求时才加入。安全、迁移、验证与审阅要求优先。

`claude/settings.json` 和 `codex/config.toml.tmpl` 只放需要跨机器统一的字段，不直接将完整的本机配置复制回仓库。使用 `./install.sh --status` 检查两个 overlay 是否已生效。
