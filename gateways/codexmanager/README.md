# CodexManager

把 Codex 接到本机已经运行的 CodexManager 网关，地址默认是 `http://localhost:48760/v1`，在本目录的
`codex.toml` 里。CodexManager 本身需要另外安装和启动。只用它管理账号、请求仍直连官方的话，不需要这个选项，
直接 `./install.sh` 就行。

## 安装

先退出 Codex，再运行：

```sh
./install.sh codex --gateway codexmanager --cm-key '你的网关 key'
```

Windows 上以管理员身份运行（加 `-Copy` 时不需要）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Gateway codexmanager -CmKey '你的网关 key'
```

key 也可以放在环境变量 `CODEXMANAGER_API_KEY` 里。两者都不给时，沿用上次写入的网关 key；没有可用的 key
就直接报错，不改任何文件。

和默认安装一样装上偏好、指令和 skills，另外：

- `config.toml` 选用 `cm` 提供方、改用文件保存登录，并去掉其他网关的入口和模型目录
  （`openai_base_url`、`model_catalog_json`）。模型、上下文窗口、MCP 等其他设置不变。
- `auth.json` 换成用网关 key 登录。第一次替换前的登录备份在 `~/.codex/.agent-kit/gateways/codexmanager.json`。

## 换成别的方式或回滚

直接用新的方式重装，比如 `./install.sh codex` 或 `./install.sh codex --gateway magpie`；回滚用 `./install.sh -r`。
两种情况都会撤掉上面这些配置，并换回接入前的登录；如果之后你自己重新登录过，就保留新的登录。
