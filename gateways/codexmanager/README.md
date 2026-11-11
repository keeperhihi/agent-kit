# CodexManager 适配

将 Codex 接入已安装并启动的 CodexManager。默认网关地址为
`http://localhost:48760/v1`，由本目录的 `codex.toml` 维护。
此适配不安装或启动 CodexManager 软件。

本适配用于 API 网关转发。仅使用 CodexManager 管理或切换账号、保留官方直连时，
使用普通的 `./install.sh` 维护偏好、指令和技能，沿用原有的提供方与登录文件。

## 安装

先退出 Codex，再提供 CodexManager 的网关 API key：

```sh
./install.sh codex --gateway codexmanager --cm-key '你的网关 key'
```

也可以在当前进程环境中提供 `CODEXMANAGER_API_KEY`，然后运行：

```sh
./install.sh codex --gateway codexmanager
```

不要把密钥写入仓库。`--cm-key` 优先于环境变量；两者都未提供时，只复用已有
`cm` 提供方在同一网关地址下、使用文件认证的 API key。不会将其他提供方的密钥
或 ChatGPT 登录令牌当作网关 key。没有可用 key 时，在修改客户端文件前停止。

Windows 使用：

```powershell
.\install.ps1 -Gateway codexmanager -CmKey '你的网关 key'
```

也可使用同名环境变量。此模式会安装资源链接，Windows 需要创建符号链接的权限。

## 接管范围

- 合并共用偏好，并直接链接仓库指令、`skills/` 和 `vendor/skills/`。
- 在 Codex 中选择 `model_provider = "cm"`，配置本目录定义的提供方。
- 使用 `cli_auth_credentials_store = "file"`，将网关 key 写入 `auth.json` 的 API-key 登录。
- 如果配置文件选择了 profile，同时调整该 profile 的提供方，让认证使用顶层文件存储设置。
- 清除顶层和所选 profile 中已有的 `model_catalog_json`、`openai_base_url`，避免继续使用其他网关的模型目录或入口；回滚时恢复原值。

安装器替换 `model_providers.cm` 表，其他提供方保留。模型名称、上下文窗口、推理强度、
服务等级和 MCP 的显式配置保留。在 CodexManager 中准备好需要使用的账号和模型；
移除其他管理器的模型目录后，目录提供的默认窗口也会改变，应在新会话中确认实际模型和窗口。
相关字段的含义见 [Codex 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)。

指定 `codex` 只处理 Codex。省略客户端时也会安装 Claude 的共用偏好和原生资源，
Claude 的登录和 API 接入方式保持原状；只指定 `claude` 时会提示 CodexManager 需要 Codex。

## 回滚和切换

```sh
./install.sh -r codex --gateway codexmanager
```

Windows 对应 `install.ps1 -Restore -Gateway codexmanager`。回滚不需要提供 key。

接入字段的原值由共用配置记录保存；首次接管前的 `auth.json` 内容和文件权限保存在
`~/.codex/.agent-kit/gateways/codexmanager.json`，在 macOS/Linux 上该记录和新认证文件均以 `600` 权限写入。
重装或轮换 key 会保留第一次的登录备份。

回滚恢复仍由安装器管理的配置与资源。认证文件仍是安装器写入的内容时，恢复原登录；
如果之后另行登录过，则保留新的登录。完成后清理本适配的登录备份。

切换到默认模式或其他网关前，先按上述命令回滚。安装和回滚期间保持 Codex 退出，
由同一个管理器维护它的接入配置。
