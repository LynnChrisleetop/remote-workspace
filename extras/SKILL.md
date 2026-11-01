---
name: websearch
description: 联网搜索（文献+网页）。当需要查最新进展、找论文/预印本/新闻、确认事实出处，或内置 web_search 报 DEEPSEEK_API_KEY 错误时使用。默认走 Europe PMC + OpenAlex + bioRxiv 免费 API。
---

# 联网搜索（替代内置 web_search）

内置 `web_search` 依赖 DeepSeek 官方 API，在只接第三方兼容网关的环境下不可用
（网关接受 `tools` 参数但不执行 Anthropic 的服务端搜索工具）。用这个脚本代替。

## 用法

```bash
python3 __WEBSEARCH_PATH__ "查询词" [选项]
```

> `__WEBSEARCH_PATH__` 是脚本的实际路径（安装时替换成你自己的）。

| 选项 | 说明 |
|---|---|
| `-n 10` | 每个源返回条数（默认 8） |
| `-s epmc` | 只搜 Europe PMC（生医文献，含摘要/PMID） |
| `-s openalex` | 只搜 OpenAlex（多学科，含期刊/会议/预印本） |
| `-s biorxiv` | 只搜 bioRxiv/medRxiv 预印本 |
| `-s bohrium` | 玻尔网页搜索（需 AccessKey，按次消耗额度） |
| `-s epmc,openalex` | 指定多个源 |
| `-s all` | 全部可用源 |
| 不传 `-s` | 默认：`epmc + openalex + biorxiv`（全部免费） |

## 各源可靠性（在受限网络出口下实测）

| 源 | 状态 | 说明 |
|---|---|---|
| epmc | ✅ 稳定 | 生医文献首选 |
| openalex | ✅ 稳定 | 多学科，偶发限流会自动重试 |
| biorxiv | ✅ 稳定 | 预印本 |
| bohrium | ⚠️ 需 AccessKey | 通用网页，质量最好 |
| bing | ❌ 不可靠 | 共享代理出口下常返回无关结果 |
| wiki | ❌ 常 503 | 被限流 |
| arxiv | ⚠️ 常 429 | 共享 IP 被抓取方限制 |

## 拿到结果之后

脚本只给标题/链接/摘要，正文用 `web_fetch` 抓具体 URL。
若报 `cross-origin redirect ... retry against that URL directly`，
换成它给出的最终 URL 再抓一次即可（这是安全策略，不是错误配置）。

## 省额度提示

只要文献时用 `-s epmc,openalex,biorxiv`，完全不花钱；
需要通用网页结果再用 `-s bohrium`。
