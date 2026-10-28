# extras/websearch — 联网搜索的替代实现

> 这一块**不是**「远程工作区」主线的一部分。它解决的问题是另一件事：
> 在某些模型网关（比如只走第三方兼容网关）下，DSH 内置的 `web_search` 工具
> 会因为拿不到 DeepSeek 官方 API key 而直接报错，且网关本身不执行 Anthropic
> 的服务端搜索工具。于是这里提供一个独立脚本顶上。

## 为什么需要它

DSH 内置 `web_search` 的调用链是：`dsh-web-search-deepseek` → Anthropic Messages
协议（`/v1/messages`）+ 服务端搜索工具。因此它要求：

1. 有 `DEEPSEEK_API_KEY`（或账号登录），并且
2. 后端**真的会执行** web search 工具

第三方兼容网关通常只满足协议、不执行服务端工具。实测（2026-10）把同一台机器的
模型换成某网关后，请求带 `tools:[{type:"web_search_20250305"}]` 会返回 200，
但模型自己回答「我没有搜索工具」——搜索没有发生。

## 用法

```bash
python3 websearch.py "查询词"                 # 默认：epmc + openalex + biorxiv
python3 websearch.py "查询词" -s bohrium -n 10   # 只走玻尔网页搜索（需 AccessKey）
python3 websearch.py "查询词" -s epmc            # 只搜生医文献
python3 websearch.py "查询词" -s all             # 所有可用源
```

| 源 | 需要密钥 | 说明 |
|---|---|---|
| `epmc` | 否 | Europe PMC，生医文献，带 PMID/DOI/摘要 |
| `openalex` | 否 | OpenAlex，多学科期刊/会议/预印本 |
| `biorxiv` | 否 | bioRxiv/medRxiv 预印本（经 Europe PMC `SRC:PPR` 过滤） |
| `bohrium` | 是 | 玻尔开放平台网页搜索，质量接近 Google，**按次消耗额度** |
| `bing` | 否 | 抓取结果页。**在共享代理出口下常返回无关结果**，仅尽力而为 |
| `wiki` | 否 | Wikipedia API，常被限流 |
| `arxiv` | 否 | arXiv API，共享 IP 下常 429 |

## 配置玻尔 AccessKey（可选）

1. 登录 <https://open.bohrium.com>，在开放平台创建 **AccessKey**
   （注意：模型网关的 key 与开放平台 AccessKey 是**两套凭据**，不能混用）
2. 写入文件，或设环境变量：

```bash
mkdir -p ~/.config/dsh-remote-workspace
printf '%s\n' 'YOUR_ACCESS_KEY' > ~/.config/dsh-remote-workspace/bohrium_access_key
chmod 600 ~/.config/dsh-remote-workspace/bohrium_access_key

# 或者
export BOHRIUM_ACCESS_KEY='YOUR_ACCESS_KEY'
```

3. 验证：

```bash
python3 websearch.py "enzyme design" -s bohrium -n 3
```

看到 `[bohrium]` 开头的结果即成功。

## 接进 DSH 作为技能

把这个目录拷到 DSH 的技能目录，agent 就会在需要联网时优先用脚本而不是内置工具：

```bash
mkdir -p ~/.agents/skills/websearch
cp SKILL.md ~/.agents/skills/websearch/SKILL.md
```

记得把 `SKILL.md` 里的脚本路径改成你实际放置的位置。
