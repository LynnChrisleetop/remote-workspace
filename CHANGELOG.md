# Changelog

## 0.1.0 — 2026-10-28

首个版本。

- `install-remote.sh`：一条命令在远端完成全流程（Node 24 → `@deepseek-ai/dsh` →
  启动脚本 → 工作区预注册 → 起 `dsh web` → 打印带 token 的 URL）。
  自包含，支持 `curl | bash`。
- `connect/connect.sh`、`connect/connect.ps1`、`connect/connect.cmd`：
  本机一键连接（建隧道 + 取最新 token + 开浏览器），支持 macOS / Linux / Windows。
- `scripts/start-web.sh`：远端启动/复用 `dsh web`，幂等，端口在监听时直接返回已有 URL。
- `docs/architecture.md`：为什么把 DSH 装在远端、远端目录布局、方案对比、安全边界。
- `docs/troubleshooting.md`：`import.meta.main` 静默失败、沙箱后端不可用、
  token 失效、工作区选择器、跨源跳转等实际踩过的坑。
- `extras/websearch.py` + `extras/SKILL.md`：内置 `web_search` 在第三方网关下不可用时的
  多源替代（Europe PMC / OpenAlex / bioRxiv / 玻尔，前三者免费）。
