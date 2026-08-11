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

`install.sh` 在插件安装前或安装后执行都可以。安装前执行时，只是提前建立配置链接；安装后执行时，会接管内容相同的本机配置。

## 新增插件

1. 创建 `claude/plugins/<plugin-name>/README.md`，记录需要手动执行的 Claude Code 命令。
2. 如果有可移植配置，按它在 `~/.claude/plugins/<plugin-name>/` 下的相对路径放入 `files/`。
3. 运行 `./install.sh`。目标是同内容的普通文件时会自动接管为链接；内容不同时只报警不覆盖，先 `diff` 并手工合并后再重试。
4. 运行 `./install.sh --status` 确认受管文件已指向仓库。

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
