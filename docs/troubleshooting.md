# 排错手册

这些都是实际踩过的坑，按「症状 → 原因 → 处理」组织。

---

## 1. `dsh` 什么都不输出，退出码还是 0

**症状**：`dsh -V`、`dsh web`、`dsh --help` 全都没有任何输出，`echo $?` 是 `0`，日志空白。

**原因**：`@deepseek-ai/dsh` 的入口 `lib/bin.js` 最后一行是

```js
if (import.meta.main) await runCli();
```

`import.meta.main` 是 Node 22.18 / 24.2 之后才有的。在更旧的 Node（比如 20）里它是
`undefined`，于是整个 CLI **静默不执行**——不打印、不报错、退出码 0。这是最难查的一类故障。

**处理**：用 Node ≥ 24 跑 dsh。

```bash
node -v            # 必须 >= v24
$PREFIX/dsh/bin/dsh -V    # 现在应该打印版本号
```

`install-remote.sh` 会主动检查这一点：系统 node 的 major 小于 24 时，它会自己装一个
Node 24 到 `$PREFIX/node`，并在安装完成后用 `dsh -V` 做一次「有输出」的验证。

---

## 2. 启动报 `does not provide an export named 'parseEnv'`

**原因**：Node 太旧（`node:util` 的 `parseEnv` 从 20.12 才有）。

**处理**：同上，升级到 Node 24。注意 npm 装包时只会给 `EBADENGINE` **警告**、照样装完，
直到启动才崩——所以必须在装之前就检查版本。

---

<a id="sandbox-backend-unavailable"></a>

## 3. `sandbox mode "workspace-write" is requested but no sandbox backend is usable on this host`

**症状**：agent 的 shell 命令报这个错；任务有时还能靠其他工具完成，但跑命令就失败。

**原因**：DSH 的 `workspace-write` 策略要把命令关进沙箱，Linux 上依赖二者之一：

- **bubblewrap**（`bwrap`）——需要 `CAP_SYS_ADMIN` 才能建命名空间
- **Landlock** —— 需要内核 ≥ 5.13

容器化的开发机通常两条都不满足。实测一台容器化开发机：

```
uname -r                 → 5.4.250-9-velinux1-amd64     # 没有 Landlock
grep CapEff /proc/self/status → 00000000a80425fb        # Docker 默认能力集，无 CAP_SYS_ADMIN
bwrap ...                 → No permissions to create new namespace
```

即：**这台机器上命令沙箱无解**，不是配置问题。

**处理**：把会话的文件策略切到 `danger-full-access`（报错最后一句也这么建议）。
在 Web 界面里找「切换权限预设（沙箱模式与审批策略）」，选无沙箱那档；
沙箱模式与审批策略是两个维度，可以「无沙箱 + 保留审批」。

---

## 4. 浏览器打不开远端界面

**症状**：直接访问 `http://<远端IP>:8787` 超时。

**原因**：`dsh web` 只监听 `127.0.0.1`，这是刻意的安全默认。

**处理**：走 SSH 隧道，不要在远端改 `0.0.0.0`。

```bash
ssh -N -L 8787:127.0.0.1:8787 <host>
# 然后开 http://127.0.0.1:8787/?token=...
```

---

## 5. 昨天还能用，今天 token 失效了

**原因**：token 是**每次 `dsh web` 启动时生成**的。远端进程重启（机器重启、进程被杀）后旧
token 作废。

**处理**：重新取一次地址，不要复用旧链接。

```bash
ssh <host> 'bash ~/.dsh-remote-workspace/start-web.sh 8787'
```

脚本会复用已在跑的实例（端口在监听就直接返回它的 URL），不会重复启动。

---

## 6. 选择工作区时只看到 `code`、`nltk_data` 之类，翻不到 `/data/...`

**原因**：Web 界面的目录选择器从**服务端 `$HOME`** 开始，而且**没有**「直接输入路径」的输入框，
只能一层层点进去。挂载点（`/data`、`/mnt/...`）不在 `$HOME` 下面时要爬很久。

**处理**：让安装脚本预注册工作区记录（`install-remote.sh` 默认就这么做），
它会直接写 `$DSH_HOME/storages/workspace.json`，打开界面左侧就有这个工作区。

想手动加也可以，改完重启 `dsh web`：

```json
{
  "unit": { "name": "workspace", "version": 2 },
  "global": {
    "initialized": true,
    "defaultWorkspaceId": "<UUID>",
    "workspaceIds": ["<UUID>"],
    "archivedSessionIds": [],
    "pinnedSessionIds": []
  },
  "tables": {
    "workspaces": {
      "<UUID>": {
        "path": "/data/gproj",
        "title": "gproj",
        "sessionIds": [],
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-01-01T00:00:00.000Z"
      }
    }
  }
}
```

⚠️ 这是按当前观测到的 schema（`version: 2`）写的，DSH 升级后字段可能变化。
安装脚本只在文件不存在或 `workspaces` 为空时才写，不会覆盖已有记录。

---

## 7. 内置 `web_search` 报 `DEEPSEEK_API_KEY` 相关错误

**症状**：

```
Error: DeepSeek search has no API key for "DEEPSEEK_API_KEY"; store it through the
credentials service (the web Models page writes it), export it in the launching
environment, or set a literal "apiKey" in the web-search-deepseek config
```

**原因**：内置搜索走 DeepSeek 官方接口。如果模型配的是第三方兼容网关，则：

- 没有 DeepSeek key → 直接报上面这个错；
- 就算配了一个网关 key，网关通常**只做协议兼容、不执行** Anthropic 的服务端搜索工具，
  实测请求 200 但模型回答「我没有搜索工具」，搜索并未发生。

**处理**：用 `extras/websearch.py` 顶上（多源、免费源可直接用），或者给一个真的
DeepSeek key。详见 [extras/README.md](../extras/README.md)。

---

## 8. `web_fetch` 报 `cross-origin redirect ... is not followed automatically`

**症状**：

```
Error: cross-origin redirect to https://www.example.com is not followed automatically;
retry against that URL directly
```

**原因**：目标站点返回了**跨源 302**（协议/域名/端口变了），抓取工具出于安全策略拒绝自动跟随。

**处理**：按提示，对**最终 URL** 再抓一次即可。常见于：

- `http://` → `https://`
- 裸域 → `www.`
- 短链 / 跟踪链接
- `doi.org/...` → 出版社站点

直接构造直链往往更省事，例如
`https://doi.org/10.1101/xxx` 换成 `https://www.biorxiv.org/content/10.1101/xxx`。

---

## 9. 装完没几天系统盘满了

**症状**：`/` 用到 90%+，各种写入报 `No space left on device`。

**原因**：npm 全局安装 + DSH profile + 会话历史默认都落在 `$HOME`，而 `$HOME` 常在系统盘。
一个 dsh 安装的依赖树轻松几百 MB。

**处理**：把前缀放到数据盘。

```bash
./install-remote.sh --host <host> --prefix /data/.dsh-remote-workspace
```

`install-remote.sh` 的 npm 缓存也放在前缀里，不会额外占用系统盘。

---

## 10. 机器重启后服务没了

**原因**：`start-web.sh` 用 tmux（没有 tmux 就 `setsid`）在后台跑，**没有**做开机自启。
容器环境里通常也没有 systemd 可以挂。

**处理**（任选）：

- 每次要用时跑一次 `start-web.sh`，它会自动复用已在跑的实例；
- 在容器/开发机自带的启动脚本里加一行 `bash $PREFIX/start-web.sh`；
- 有 systemd 的话自己写一个 user unit 也行（注意导出 `PATH` 和 `DSH_HOME`）。

**注意**：进程被杀不会丢数据，会话记录在 `$DSH_HOME` 里，重新起来还在。

---

## 11. 想确认一切正常

```bash
# 远端
ssh <host> 'ls -l ~/.dsh-remote-workspace'          # 目录在
ssh <host> '~/.dsh-remote-workspace/dsh/bin/dsh -V' # 有版本输出（关键！）
ssh <host> 'bash ~/.dsh-remote-workspace/start-web.sh 8787'  # 打印带 token 的 URL

# 本机
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/   # 401 说明隧道通
```

`401` 是**正常**的：不带 token 就该被拒。带 token 访问会 `303` 跳到应用页。
