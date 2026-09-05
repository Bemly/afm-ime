#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
合并 梗百科(969) + 梗指南(1272) 共 2241 条投稿标题：
  1) 剥离栏目标签【梗百科】【梗指南】(含年度/专业/编号变体) 与【补档】；
  2) 剥离问句外壳（是什么梗/是啥梗/什么梗/啥梗/是什么意思/啥意思/是咋回事/怎么回事/是啥 等），
     只保留被解释的关键词或关键句子（多梗合集类整句保留）；
  3) 为清洗后的关键词/关键句注完整拼音（带声调 + 无声调两版，英文/数字原样保留，词组级多音字）。
只读取本地两份 json，不发起网络请求。拼音由 pypinyin 自动生成，生僻/网络多音字可能需人工校对。
"""
import json, csv, os, re, datetime
from pypinyin import lazy_pinyin, Style

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = [
    ("梗百科", os.path.join(HERE, "gengbaike-videos.json")),
    ("梗指南", os.path.join(HERE, "genzhinan-videos.json")),
]

# 只剥离“栏目自身”标签；内容性【】（如游戏名）保留
TAG_RE = re.compile(r"[【\[]\s*(?:年度|专业)?梗(?:指南|百科)\s*\d*\s*[】\]]|【\s*补档\s*】|\[\s*补档\s*\]")
# 问句外壳：长串在前，命中即截断其后全部引导语
SHELLS = ["是什么梗", "是啥梗", "什么梗", "是怎么回事", "怎么回事",
          "是什么意思", "是啥意思", "啥意思", "是咋回事", "咋回事",
          "啥梗", "是啥"]
SHELL_RE = re.compile("(" + "|".join(map(re.escape, SHELLS)) + ")")
EDGE = set(" ？?，,。.！!、：:；;～~·-—_…“”\"'’‘|｜/\\#")  # 不含括号，避免“（上）”被剥残

def normalize_spacing(t: str) -> str:
    """合并原标题逐字排版空格（段 子→段子、A I→AI、5 2 0→520），
    但保留多字母英文词间空格（Chill Guy、DLSS 5 ON）。"""
    cjk = "一-鿿"
    prev = None
    while prev != t:
        prev = t
        t = re.sub(rf"([{cjk}])[ \t]+(?=[A-Za-z0-9{cjk}])", r"\1", t)   # 汉字后
        t = re.sub(rf"(?<=[A-Za-z0-9{cjk}])[ \t]+([{cjk}])", r"\1", t)  # 汉字前
        t = re.sub(r"(?<![A-Za-z0-9])([A-Za-z0-9]) (?=[A-Za-z0-9](?![A-Za-z0-9]))", r"\1", t)  # 孤立字符间
        t = re.sub(r"(?<=(?<![A-Za-z0-9])[A-Za-z0-9]) (?=[A-Za-z0-9])(?![A-Za-z0-9])", "", t)
    return t

def clean(title: str) -> str:
    t = TAG_RE.sub("", title)
    m = SHELL_RE.search(t)
    if m:
        t = t[:m.start()]
    t = t.strip()
    # 反复剥掉边缘标点/空白
    while t and t[0] in EDGE: t = t[1:]
    while t and t[-1] in EDGE: t = t[:-1]
    return normalize_spacing(t.strip())

def _segments(s: str):
    """把字符串切成 汉字块 / 非汉字块 / 空格。"""
    segs, hz, oth = [], [], []
    def flush(kind):
        nonlocal hz, oth
        if kind == "hz" and hz: segs.append(("hz", "".join(hz))); hz = []
        if kind == "oth" and oth: segs.append(("oth", "".join(oth))); oth = []
    for ch in s:
        if "一" <= ch <= "鿿":
            flush("oth"); hz.append(ch)
        elif ch.isspace():
            flush("hz"); flush("oth"); segs.append(("sp", " "))
        else:
            flush("hz"); oth.append(ch)
    flush("hz"); flush("oth")
    return segs

def pinyin(s: str, style) -> str:
    toks = []
    for kind, val in _segments(s):
        if kind == "sp":
            toks.append(" ")
        elif kind == "hz":
            toks.append(" ".join(lazy_pinyin(val, style=style, errors="ignore")))
        else:
            toks.append(val)  # 英文/数字/符号原样保留
    return " ".join(" ".join(toks).split())

def main():
    items = []
    for source, fp in SOURCES:
        data = json.load(open(fp, encoding="utf-8"))
        for v in data["videos"]:
            kw = clean(v["title"])
            items.append({
                "source": source,
                "date": v["date"], "created_ts": v["created_ts"],
                "orig_title": v["title"], "keyword": kw,
                "bvid": v["bvid"], "url": v["url"],
                "length": v.get("length", ""),
            })
    # 全局按投稿时间倒序（两个号混排成一条热梗时间线）
    items.sort(key=lambda x: (-x["created_ts"], x["source"], x["bvid"]))

    empty = [x for x in items if not x["keyword"]]
    assert not empty, f"存在清洗后为空的标题: {empty[:5]}"

    for i, x in enumerate(items, 1):
        x["idx"] = i
        x["pinyin"] = pinyin(x["keyword"], Style.TONE)       # 带声调
        x["pinyin_plain"] = pinyin(x["keyword"], Style.NORMAL)  # 无声调

    tz = datetime.timezone(datetime.timedelta(hours=8))
    collected = datetime.datetime.now(tz).strftime("%Y-%m-%d %H:%M:%S %z")
    n_baike = sum(1 for x in items if x["source"] == "梗百科")
    n_zn = sum(1 for x in items if x["source"] == "梗指南")

    # JSON
    jpath = os.path.join(HERE, "梗合集-关键词拼音.json")
    json.dump({"collected_at": collected,
               "total": len(items), "by_source": {"梗百科": n_baike, "梗指南": n_zn},
               "note": "拼音由 pypinyin 词组级自动生成，生僻/网络多音字可能需人工校对",
               "items": items}, open(jpath, "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)

    # CSV
    cpath = os.path.join(HERE, "梗合集-关键词拼音.csv")
    cols = ["idx", "source", "date", "keyword", "pinyin", "pinyin_plain",
            "length", "bvid", "orig_title", "url"]
    with open(cpath, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols); w.writeheader()
        for x in items: w.writerow({k: x[k] for k in cols})

    # Markdown
    mpath = os.path.join(HERE, "梗合集-关键词拼音全集.md")
    with open(mpath, "w", encoding="utf-8") as f:
        f.write("# 梗百科 × 梗指南 · 关键词/关键句 + 完整拼音全集\n\n")
        f.write(f"- 合计 **{len(items)}** 条（梗百科 {n_baike} + 梗指南 {n_zn}），按投稿时间倒序混排\n")
        f.write("- 已剥离栏目标签与“是什么梗/是啥梗/啥梗/是什么意思/是咋回事/是啥”等问句外壳，只保留关键词或关键句\n")
        f.write("- 拼音为完整注音（带声调），英文/数字原样保留；由 pypinyin 词组级自动生成，个别网络多音字请以实际为准\n")
        f.write(f"- 生成时间：{collected}（UTC+8）\n\n")
        f.write("| # | 来源 | 日期 | 关键词 / 关键句 | 完整拼音 |\n")
        f.write("|---:|---|---|---|---|\n")
        for x in items:
            kw = x["keyword"].replace("|", "丨").replace("\n", " ")
            py = x["pinyin"].replace("|", "丨")
            f.write(f"| {x['idx']} | {x['source']} | {x['date']} | {kw} | {py} |\n")

    # 统计清洗后关键词重复（两号撞车）
    from collections import Counter
    c = Counter(x["keyword"] for x in items)
    dups = [(k, n) for k, n in c.most_common() if n > 1]
    print("total:", len(items), "baike:", n_baike, "zhinan:", n_zn)
    print("unique keywords:", len(c), "重复关键词条数:", len(dups), "重复多占:", sum(n - 1 for _, n in dups))
    print("dup sample:", dups[:10])
    for p in (jpath, cpath, mpath):
        print(" ", p, os.path.getsize(p), "bytes")

if __name__ == "__main__":
    main()
