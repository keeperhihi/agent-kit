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

## 显示配置

`files/config.json` 由 `install.sh` 链接为：

```text
~/.claude/plugins/claude-hud/config.json
```

这不是在安装插件本体，而是在恢复插件安装后会读取的用户配置。`install.sh` 可以在插件安装之前执行，先建立配置链接；也可以在安装之后执行，接管内容相同的已有配置。两种顺序都可以。

当前显式启用：

- Agents
- Todos
- Session Name
- Reasoning Effort（`display.showEffortLevel`）
- 周用量始终显示（`display.sevenDayThreshold: 0`）；默认值 80 表示只有 7 天用量 ≥80% 才显示 Weekly 段
