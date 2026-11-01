# dsh-remote-workspace

**把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）装到你的远程开发机上**，
让工作区、项目文件和整个对话历史都沉淀在那台机器里。之后换任何一台电脑 —— Mac、Windows、另一台笔记本 ——
只要 `ssh` 过去（或跑一个脚本），看到的就是**同一个工作区、同一份历史**。

```
你的笔记本 ──SSH 隧道──▶ 远程开发机上的 dsh web (127.0.0.1)
                          ├─ 工作区   /data/projects/xxx
                          ├─ 会话历史 $DSH_HOME/sessions
                          └─ agent 的 shell 也在这里跑
```

---

## 它解决什么问题

DSH 的「工作区」在存储里就是一个**本地绝对路径**（`$DSH_HOME/storages/workspace.json` 里的 `path`），
没有远程主机字段；会话历史也存在**运行 DSH 的那台机器**上。于是：

- 在笔记本 A 上聊的东西，换到笔记本 B 就没了；
- 想让 agent 碰开发机上的代码，只能挂载、同步或者手动 `ssh`；
- 开发机上跑着的训练、tmux 会话，agent 看不见也接不上。

把 DSH 直接跑在开发机上，这三个问题一起消失：**工作区就是真实的远端路径**，文件工具（read/write/
grep/glob）零同步开销，agent 的 shell 与你的 tmux、conda 环境、GPU 在同一台机器上。

> DSH 刻意只监听 `127.0.0.1` 并拒绝 `--host 0.0.0.0`（那等于把远程代码执行能力挂到公网）。
> 所以本方案**不需要在远端开放任何端口**，访问一律走 SSH 隧道。

---

## 快速开始

### 1. 在远端装好（在你自己电脑上跑，一条命令）

```bash
git clone https://github.com/LynnChrisleetop/remote-workspace.git
cd dsh-remote-workspace
./install-remote.sh --host my-devbox
```

`my-devbox` 是 `~/.ssh/config` 里的别名，也可以直接写 IP：

```bash
./install-remote.sh --host 203.0.113.10 --port 2222 --user root --workspace /data/projects
```

它会：检查 SSH → 需要时装 Node 24（到私有目录）→ 装 `@deepseek-ai/dsh` → 写启动脚本 →
预注册工作区 → 起 `dsh web` → 打印带 token 的 URL。

不想 clone 也可以：

```bash
curl -fsSL https://raw.githubusercontent.com/LynnChrisleetop/remote-workspace/main/install-remote.sh \
  | bash -s -- --host my-devbox
```

**Windows**：用 Git Bash 或 WSL 跑上面这条（Windows 自带 PowerShell 里没有 bash）。
装了 Git 的话，`"C:\Program Files\Git\bin\bash.exe" -c "..."` 也能直接用。

### 2. 从本机打开

安装脚本最后会打印一条命令，照做即可：

```bash
ssh -N -L 8787:127.0.0.1:8787 my-devbox &
open "http://127.0.0.1:8787/?token=..."      # macOS（Linux 用 xdg-open）
```

或者用仓库里的连接脚本，它会自己建隧道、取最新 token、开浏览器：

```bash
./connect/connect.sh --host my-devbox
```

**Windows**：

```powershell
.\connect\connect.cmd -RemoteHost my-devbox
```

---

## 装完之后，远端有什么

默认前缀 `$HOME/.dsh-remote-workspace`（`--prefix` 可改，建议放大盘）：

| 路径 | 内容 |
|---|---|
| `node/` | 私有 Node ≥ 24（仅当系统 node 太旧时才装） |
| `dsh/` | `@deepseek-ai/dsh` 的安装前缀，可执行文件 `bin/dsh` |
| `dsh-home/` | `DSH_HOME`：会话历史、工作区表、凭据、profile |
| `dsh-remote.env` | 上面这些路径的配置 |
| `start-web.sh` | 启动/复用 `dsh web`，打印带 token 的地址 |

**不写系统目录、不改 PATH、不覆盖你已有的 dsh。** 删掉前缀目录即完全回滚
（但会话历史也在里面）。

---

## 日常使用

**换电脑**：新机器只要 `ssh` 能到开发机，跑一次 `connect/connect.sh --host ...`（或
`connect.cmd`）就接上了。工作区和历史都在远端，不会重建。

**端口被占**：`--web-port` / `--local-port` 换一个。

**服务重启后 token 变了**：重新跑一次 `connect`，它每次都会取最新 URL，不要复用旧链接。

**机器重启**：`start-web.sh` 不会开机自启（容器里通常也没 systemd），需要时跑一次即可；
端口已在监听时它会复用，不会重复启动。会话记录不丢。

---

## 和其他做法比

| 方案 | 工作区位置 | 历史位置 | 换机共享 | 适用 |
|---|---|---|---|---|
| **本仓库** | 远端真实路径 | 远端 | ✅ | 有常年开着的开发机，想要上下文沉淀 |
| SSHFS / rclone 挂载 | 本地盘符 | 本地 | ❌ | 只想在本地编辑器里改远端小文件 |
| 本地镜像插件（SFTP 同步） | 本地镜像目录 | 本地 | ❌ | 一个界面管多台机器，远端不装东西 |

三者可以并存。本仓库针对的是「**以开发机为主场**」这一种。

---

## 安全

- 只监听 loopback，靠 SSH 认证；**不要**为了省事改成 `0.0.0.0`。
- 带 token 的 URL 是**一次性登录凭据**（换取 30 天签名 cookie），别外发、别贴聊天记录。
- `DSH_HOME` 存会话历史和凭据，建议 `chmod 700`。
- agent 以你的 SSH 用户身份执行命令 —— 远端是 root 的话它就是 root。**只在自己的机器上这么干。**

---

## extras：联网搜索

内置 `web_search` 依赖 DeepSeek 官方接口；如果模型接的是第三方兼容网关，它通常会失败
（网关只做协议兼容、不执行 Anthropic 的服务端搜索工具）。`extras/` 里有一个多源搜索脚本顶上：

```bash
python3 extras/websearch.py "enzyme design"            # Europe PMC + OpenAlex + bioRxiv（免费）
python3 extras/websearch.py "..." -s bohrium           # 可选：玻尔开放平台网页搜索
```

详见 [extras/README.md](extras/README.md)。这块**不属于**主线，不用它也不影响远程工作区。

---

## 要求

- **远端**：Linux（x86_64 / arm64）或 macOS；`bash`、`curl`、`tar`、`xz`。
  Node 由脚本负责（系统已有 ≥ 24 就直接用）。
- **本机**：`ssh` 能免密到远端；连接脚本额外需要 `bash`（Windows 用 Git Bash）或 PowerShell。

已在 Ubuntu 22.04（容器化开发机，Node 20 起始）上完整验证：安装、启动、隧道访问、
工作区预注册、跨机复用。

---

## 排错

装不上、界面打不开、`dsh` 静默无输出、沙箱报错、工作区选择器翻不到目录 …… 都在
[docs/troubleshooting.md](docs/troubleshooting.md) 里，按症状分类。

想看设计取舍（为什么是这个架构、为什么不挂载）看 [docs/architecture.md](docs/architecture.md)。

---

## 许可证

[MIT](LICENSE)
