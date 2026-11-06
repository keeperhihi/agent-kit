# claude-hud

Claude Code 的状态栏插件。插件本体由 Claude Code 插件管理器安装和更新，本仓库只保存安装配方与显示配置。

## 首次安装

在 Claude Code 中依次执行：

```text
/plugin marketplace add jarrodwatts/claude-hud
/plugin install claude-hud
```

查看安装摘要：

- 显示 `Plugin is now active.` 时直接继续；
- 只有显示 `Run /reload-plugins to activate.` 时才执行 `/reload-plugins`。

然后执行：

```text
/claude-hud:setup
```

`/claude-hud:setup` 会检测当前机器的 Node/Bun 和插件路径，并将 `statusLine` 写入本机 `~/.claude/settings.json`。

`statusLine.command` 可能包含 Node/Bun 的绝对路径，所以它属于每台机器各自生成的配置；不要因此将完整的 `~/.claude/settings.json` 直接覆盖进仓库。

`install.sh --target claude` 会备份并完整替换 `settings.json`。每次重新安装 Claude 配置后，都需要再次运行 `/claude-hud:setup` 恢复状态栏。

## 显示配置

`files/config.json` 由 `install.sh` 链接为：

```text
~/.claude/plugins/claude-hud/config.json
```

`install.sh --target claude` 安装的是插件读取的显示配置。插件安装前执行会提前建立链接，已有同名配置时则先备份再替换。插件本体仍通过上面的命令安装。

当前显式启用：

- Agents
- Todos
- Session Name
- Reasoning Effort（`display.showEffortLevel`）
- 周用量始终显示（`display.sevenDayThreshold: 0`）；默认值 80 表示只有 7 天用量 ≥80% 才显示 Weekly 段
