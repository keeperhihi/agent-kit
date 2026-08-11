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
  config.toml.tmpl              Codex 配置模板
install.sh
```

## 约定

- `settings.json` 复制到目标目录；其他受管文件使用符号链接。
- 已存文件默认不覆盖；使用 `--force` 时先备份再覆盖。
- `claude/plugins/<plugin-name>/files/` 映射到该插件的用户配置目录。
- 插件本体、Marketplace、缓存和注册表不纳入仓库。
- Codex 的机器专属配置从 `codex/config.toml.tmpl` 生成。
- 凭证、会话记录、数据库、`settings.local.json` 和机器专属路径不入库。

同步本机 Claude Code 设置前先检查差异：

```bash
diff -u claude/settings.json ~/.claude/settings.json
```

不直接将完整的本机 `settings.json` 复制回仓库。
