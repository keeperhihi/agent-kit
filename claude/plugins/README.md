# Claude Code plugins

插件本体、Marketplace、版本与缓存由 Claude Code 的插件管理器负责；本目录只保存：

- 每个插件的安装/初始化配方；
- 需要跨机器保持一致的可移植配置文件。

## 目录约定

```text
claude/plugins/<plugin-name>/
  README.md       安装、初始化与特殊说明
  files/          映射到 ~/.claude/plugins/<plugin-name>/ 的受管文件树
```

例如：

```text
claude/plugins/claude-hud/files/config.json
  → ~/.claude/plugins/claude-hud/config.json
```

`install.sh` 会自动发现所有 `<plugin-name>/files/` 目录，递归将其中文件链接到对应插件目录。`--status` 和 `--uninstall` 使用同一套发现规则，所以新增插件时无需修改脚本。

`files/` 是“需要镜像到用户配置目录的文件”边界，不是插件安装包：

- `/plugin install` 安装和注册插件本体；
- 插件自己的 setup/configure 命令处理需要探测本机环境的配置；
- `files/` 保存已确认需要跨机器保持一致的用户配置。

`install.sh --target claude` 在插件安装前或安装后执行都可以。安装前执行时，会提前建立配置链接；已有同名本机配置时，先备份再替换。

## 新增插件

1. 创建 `claude/plugins/<plugin-name>/README.md`，记录需要手动执行的 Claude Code 命令。
2. 如果有可移植配置，按它在 `~/.claude/plugins/<plugin-name>/` 下的相对路径放入 `files/`。
3. 运行 `./install.sh --target claude`，已有配置会备份后替换为仓库链接。
4. 按插件说明完成本机初始化，再运行 `./install.sh --target claude --status` 检查安装状态；初始化写入的本机设置会使 `settings.json` 与仓库不同。

## 不入库

不要将 `~/.claude/plugins/` 整体复制进来。以下都是 Claude Code 或插件生成的本机状态：

- `cache/`
- `marketplaces/`
- `installed_plugins.json`
- `known_marketplaces.json`
- `config-cache/`
- `context-cache/`
- `transcript-cache/`

`files/` 也不是缓存的逃生口：上述缓存目录以及 `cache/`、`marketplaces/`、`installed_plugins.json`、`known_marketplaces.json` 即使误放进 `files/` 也会被 `.gitignore` 和安装脚本跳过。
