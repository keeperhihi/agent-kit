# Magpie

```sh
./install.sh --gateway magpie
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Gateway magpie
```

和默认安装一样装上偏好、指令和 skills，不额外写配置。Magpie 本身需要另外安装；它写进客户端配置的接入地址
和登录，安装器不会动。

## 在 Magpie 里

- **账号和模型：** 登录账号，设置供应商和路由，启用要接入的客户端。要沿用长上下文偏好，在对应供应商的
  「高级 → 上下文窗口」选「各模型最大」。
- **指令和 skills：** 安装器已经装好。Magpie 识别到它们后会询问是否交给它管理，按需确认。之后仍在仓库里改；
  再运行一次安装，这些位置会恢复成仓库的状态。链接模式下，如果 Magpie 往 `CLAUDE.md`、`AGENTS.md` 里写了内容，
  会写进仓库的 `instructions.md`，确认后用 `git status` 看一眼。
- **MCP：** 在「资源库 → MCP 服务器」里添加，再分配给客户端。例如 OpenAI 文档 MCP：名称 `openaiDeveloperDocs`，
  URL `https://developers.openai.com/mcp`。

装完新开一个客户端会话，确认指令、skills 和请求实际走的是 Magpie。
