#!/usr/bin/env python3
"""多源搜索工具（网页 + 学术文献），替代 DSH 内置 web_search。

用法示例:
    python3 websearch.py "CRISPR base editing"                 # 默认: Europe PMC + Bing
    python3 websearch.py "protein design" -s epmc -n 10        # 只搜生医文献
    python3 websearch.py "新酶设计" -s bing                     # 只搜通用网页
    python3 websearch.py "enzyme" -s all -n 12                 # 全部源（若配了玻尔 key 会花额度）
    python3 websearch.py "..." -s arxiv,biorxiv                # 指定多个源

可用源:
    epmc      Europe PMC  生医文献全文索引（免费、无需密钥、支持 PMID/DOI/摘要）
    openalex  OpenAlex    多学科文献（含期刊/会议/预印本元数据，免费）
    arxiv     arXiv       预印本（免费）
    biorxiv   bioRxiv/medRxiv 预印本，经 Europe PMC 的 SRC:PPR 过滤（免费）
    bing      Bing 网页搜索（抓取；本网络出口下常被污染/返回无关结果，仅尽力而为）
    wiki      Wikipedia 百科（本网络下常 503，尽力而为）
    bohrium   玻尔开放平台网页搜索（需要 AccessKey，消耗玻尔额度）

玻尔 AccessKey 存放位置（可选，唯一需要你配置的东西）:
    ~/.config/dsh-remote-workspace/bohrium_access_key   （一行 key）
    或环境变量 BOHRIUM_ACCESS_KEY / BOHRIUM_ACCESS_KEY_FILE。
    没有 key 时 bohrium 源自动跳过，其余免费源照常工作。
"""
import argparse
import base64
import html as htmlmod
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed

DEFAULT_BOHRIUM_KEY_FILE = os.path.expanduser("~/.config/dsh-remote-workspace/bohrium_access_key")
BOHRIUM_KEY_FILE = os.environ.get("BOHRIUM_ACCESS_KEY_FILE", DEFAULT_BOHRIUM_KEY_FILE)
BOHRIUM_URL = "https://open.bohrium.com/openapi/v2/search/web"
EPMC_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
ARXIV_URL = "https://export.arxiv.org/api/query"
BING_URL = "https://www.bing.com/search"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

FREE_DEFAULT = ["epmc", "openalex", "biorxiv"]
ALL_SOURCES = ["epmc", "openalex", "biorxiv", "wiki", "bing", "arxiv", "bohrium"]


# ---------------------------------------------------------------- 基础工具

def http_get(url, headers=None, timeout=25):
    """GET 并解码；遇到 429/503 自动退避重试（共享代理出口易被限流）。"""
    last = None
    for attempt in range(3):
        req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
                return resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code in (429, 503) and attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            raise
        except urllib.error.URLError as exc:
            last = exc
            if attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            raise
    raise last


def clean(text, limit=0):
    text = re.sub(r"<[^>]+>", "", text or "")
    text = htmlmod.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit] if limit else text


def bohrium_key():
    """优先读环境变量 BOHRIUM_ACCESS_KEY，其次读 key 文件。"""
    env_key = (os.environ.get("BOHRIUM_ACCESS_KEY") or "").strip()
    if env_key:
        return env_key
    if not os.path.exists(BOHRIUM_KEY_FILE):
        return None
    try:
        key = open(BOHRIUM_KEY_FILE, encoding="utf-8").read().strip()
    except OSError:
        return None
    return key or None


# ---------------------------------------------------------------- 各搜索源

def search_bohrium(query, count):
    """玻尔开放平台网页搜索。无 AccessKey 时抛异常由调用方跳过。"""
    key = bohrium_key()
    if not key:
        raise RuntimeError("未配置 .bohrium_access_key")
    url = "%s?%s" % (BOHRIUM_URL, urllib.parse.urlencode({"q": query, "count": count}))
    data = json.loads(http_get(url, {"Authorization": "Bearer " + key}))
    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    raw = []
    for field in ("organic_results", "results", "items", "list", "documents", "webPages"):
        if isinstance(payload.get(field), list):
            raw = payload[field]
            break
    out = []
    for it in raw:
        if not isinstance(it, dict):
            continue
        link = (it.get("link") or it.get("url") or it.get("href")
                or it.get("displayed_link") or "")
        out.append({
            "source": "bohrium",
            "title": clean(it.get("title") or it.get("name") or ""),
            "url": link,
            "snippet": clean(it.get("snippet") or it.get("content")
                             or it.get("summary") or it.get("description") or "", 320),
            "meta": it.get("domain") or "",
        })
    return out[:count]


def search_epmc(query, count, preprints=False):
    """Europe PMC：生医文献（含摘要）。preprints=True 时只要 bioRxiv/medRxiv 预印本。"""
    q = query
    if preprints:
        q = "(%s) AND SRC:PPR" % query
    url = "%s?%s" % (EPMC_URL, urllib.parse.urlencode({
        "query": q, "format": "json", "pageSize": count, "resultType": "core"}))
    data = json.loads(http_get(url))
    out = []
    for it in data.get("resultList", {}).get("result", []):
        pmid = it.get("pmid") or ""
        doi = it.get("doi") or ""
        if pmid:
            link = "https://pubmed.ncbi.nlm.nih.gov/%s/" % pmid
        elif doi:
            link = "https://doi.org/%s" % doi
        else:
            link = it.get("fullTextUrlList", {}).get("fullTextUrl", [{}])[0].get("url", "")
        bits = [b for b in (it.get("journalTitle"), it.get("pubYear"),
                            ("PMID " + pmid) if pmid else ("DOI " + doi) if doi else "")
                if b]
        out.append({
            "source": "biorxiv" if preprints else "epmc",
            "title": clean(it.get("title", "")),
            "url": link,
            "snippet": clean(it.get("abstractText", ""), 320),
            "meta": " · ".join(str(b) for b in bits),
        })
    return out[:count]


def search_arxiv(query, count):
    """arXiv 预印本（物理/CS/量化生物等）。arXiv 常限流，带退避重试。"""
    url = "%s?%s" % (ARXIV_URL, urllib.parse.urlencode({
        "search_query": "all:" + query, "max_results": count, "sortBy": "relevance"}))
    headers = {"User-Agent": "dsh-websearch/1.0 (academic literature lookup)"}
    last = None
    for attempt in range(3):
        try:
            xml = http_get(url, headers)
            break
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code in (429, 503) and attempt < 2:
                time.sleep(3 * (attempt + 1))
                continue
            raise
    else:  # pragma: no cover
        raise last
    ns = {"a": "http://www.w3.org/2005/Atom"}
    out = []
    for entry in ET.fromstring(xml).findall("a:entry", ns):
        title = clean((entry.findtext("a:title", "", ns) or ""))
        summary = clean((entry.findtext("a:summary", "", ns) or ""), 320)
        link = (entry.findtext("a:id", "", ns) or "").strip()
        published = (entry.findtext("a:published", "", ns) or "")[:10]
        authors = [a.findtext("a:name", "", ns) for a in entry.findall("a:author", ns)][:3]
        meta = " · ".join(x for x in (", ".join(a for a in authors if a), published) if x)
        out.append({"source": "arxiv", "title": title, "url": link,
                    "snippet": summary, "meta": meta})
    return out[:count]


def search_biorxiv(query, count):
    """bioRxiv/medRxiv 预印本，走 Europe PMC 的 SRC:PPR 过滤（官方 API 不支持关键词检索）。"""
    return search_epmc(query, count, preprints=True)


def reconstruct_abstract(inverted):
    """OpenAlex 用倒排索引存摘要，这里还原成正常文本。"""
    if not isinstance(inverted, dict):
        return ""
    pos = {}
    for word, idxs in inverted.items():
        for i in idxs or []:
            pos[i] = word
    return " ".join(pos[i] for i in sorted(pos))


def search_openalex(query, count):
    """OpenAlex：覆盖期刊/会议/预印本（含 arXiv、bioRxiv、PubMed 元数据），免费无密钥。"""
    url = "https://api.openalex.org/works?" + urllib.parse.urlencode({
        "search": query, "per-page": count, "mailto": "dsh-agent@example.com"})
    data = json.loads(http_get(url))
    out = []
    for w in data.get("results", [])[:count]:
        venue = ((w.get("primary_location") or {}).get("source") or {}).get("display_name") or ""
        year = w.get("publication_year") or ""
        doi = w.get("doi") or ""
        url_ = doi or ((w.get("primary_location") or {}).get("landing_page_url")) or w.get("id") or ""
        authors = [a.get("author", {}).get("display_name") for a in
                   (w.get("authorships") or [])[:3]]
        meta = " · ".join(str(x) for x in (
            venue, year, ", ".join(a for a in authors if a),
            ("DOI " + doi.replace("https://doi.org/", "")) if doi else "") if x)
        out.append({
            "source": "openalex",
            "title": clean(w.get("title") or ""),
            "url": url_,
            "snippet": clean(reconstruct_abstract(w.get("abstract_inverted_index")), 320),
            "meta": meta,
        })
    return out


def decode_bing_link(href):
    if "bing.com/ck/a" not in href:
        return href
    qs = urllib.parse.parse_qs(urllib.parse.urlparse(href).query)
    u = (qs.get("u") or [""])[0]
    if u.startswith("a1"):
        b64 = u[2:]
        b64 += "=" * (-len(b64) % 4)
        try:
            return base64.urlsafe_b64decode(b64).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            return href
    return href


def search_bing(query, count):
    """Bing 网页搜索（抓取结果页，免费）。按查询语言自动选区域，避免中文区污染英文查询。"""
    ascii_letters = sum(1 for ch in query if ord(ch) < 128)
    english = ascii_letters / max(1, len(query)) > 0.7
    params = {"q": query, "count": count}
    if english:
        params.update({"setlang": "en-US", "mkt": "en-US", "cc": "US"})
    else:
        params.update({"setlang": "zh-Hans", "mkt": "zh-CN"})
    url = "%s?%s" % (BING_URL, urllib.parse.urlencode(params))
    page = http_get(url)
    out = []
    for chunk in page.split('class="b_algo"')[1:]:
        chunk = chunk[:4000]
        m = re.search(r'<h2[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', chunk, re.S)
        if not m:
            continue
        href = decode_bing_link(htmlmod.unescape(m.group(1)))
        if not href.startswith("http"):
            continue
        mp = re.search(r"<p[^>]*>(.*?)</p>", chunk, re.S)
        out.append({
            "source": "bing",
            "title": clean(m.group(2)),
            "url": href,
            "snippet": clean(mp.group(1), 300) if mp else "",
            "meta": "",
        })
        if len(out) >= count:
            break
    return out


def search_wiki(query, count):
    """Wikipedia API：概念/背景查询，稳定无需密钥。"""
    chinese = sum(1 for ch in query if ord(ch) > 127) > len(query) / 3
    lang = "zh" if chinese else "en"
    url = "https://%s.wikipedia.org/w/api.php?%s" % (lang, urllib.parse.urlencode({
        "action": "query", "list": "search", "srsearch": query,
        "format": "json", "srlimit": count}))
    data = json.loads(http_get(url))
    out = []
    for it in data.get("query", {}).get("search", [])[:count]:
        title = it.get("title", "")
        out.append({
            "source": "wiki",
            "title": title,
            "url": "https://%s.wikipedia.org/wiki/%s" % (lang, urllib.parse.quote(title.replace(" ", "_"))),
            "snippet": clean(it.get("snippet", ""), 300),
            "meta": "%s.wikipedia.org" % lang,
        })
    return out


DISPATCH = {
    "epmc": lambda q, n: search_epmc(q, n, preprints=False),
    "openalex": search_openalex,
    "biorxiv": lambda q, n: search_biorxiv(q, n),
    "arxiv": search_arxiv,
    "bing": search_bing,
    "wiki": search_wiki,
    "bohrium": search_bohrium,
}


# ---------------------------------------------------------------- 汇总输出

def run_sources(query, sources, count):
    results, errors = {}, {}
    with ThreadPoolExecutor(max_workers=min(5, len(sources) or 1)) as pool:
        futures = {pool.submit(DISPATCH[s], query, count): s for s in sources}
        for fut in as_completed(futures):
            src = futures[fut]
            try:
                results[src] = fut.result()
            except Exception as exc:  # noqa: BLE001
                errors[src] = str(exc)[:200]
    return results, errors


def dedup(results):
    """按 URL 归一化去重，保留先出现的（源顺序即优先级）。"""
    seen, merged = set(), []
    for src in results:
        for item in results[src]:
            key = re.sub(r"^https?://(www\.)?", "", item["url"]).rstrip("/").lower()
            if not key or key in seen:
                continue
            seen.add(key)
            merged.append(item)
    return merged


def main():
    ap = argparse.ArgumentParser(description="多源搜索：文献 + 网页")
    ap.add_argument("query", help="查询词")
    ap.add_argument("-s", "--source", default="",
                    help="源: epmc/arxiv/biorxiv/bing/bohrium，逗号分隔，或 all（默认 epmc,bing）")
    ap.add_argument("-n", "--count", type=int, default=8, help="每个源返回条数，默认 8")
    args = ap.parse_args()

    if not args.source:
        sources = list(FREE_DEFAULT)
        if bohrium_key():
            sources.append("bohrium")          # 有 key 才自动带上（会花额度）
    elif args.source.strip().lower() == "all":
        sources = list(ALL_SOURCES)
    else:
        sources = [s.strip().lower() for s in args.source.split(",") if s.strip()]

    unknown = [s for s in sources if s not in DISPATCH]
    if unknown:
        print("未知的源: %s（可用: %s）" % (", ".join(unknown), ", ".join(DISPATCH)),
              file=sys.stderr)
        return 2

    results, errors = run_sources(args.query, sources, args.count)

    total = sum(len(v) for v in results.values())
    summary = "  ".join("%s:%d" % (s, len(results.get(s, []))) for s in sources)
    print("## 搜索: %s" % args.query)
    print("*来源 %s，命中 %d 条*\n" % (summary, total))
    for s, msg in errors.items():
        print("*[%s 失败: %s]*\n" % (s, msg))

    merged = dedup(results)
    if not merged:
        print("没有结果。")
        return 1

    for i, it in enumerate(merged[: args.count * max(1, len(sources))], 1):
        tag = it["source"]
        print("%d. **[%s] %s**" % (i, tag, it["title"] or "(无标题)"))
        if it["url"]:
            print("   %s" % it["url"])
        if it["meta"]:
            print("   %s" % it["meta"])
        if it["snippet"]:
            print("   %s" % it["snippet"])
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
