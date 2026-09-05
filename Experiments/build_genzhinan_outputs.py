#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
合并浏览器同源拦截得到的分页备份(.zn_caps_*.json)，生成梗指南(UID 94510621)
全部投稿视频标题的 JSON / CSV / Markdown 三份交付文件。

数据来源：浏览器空间页 https://space.bilibili.com/94510621/upload/video
页面自身对 https://api.bilibili.com/x/space/wbi/arc/search 的 fetch 响应（ps=40，共 32 页）。
本脚本只做合并、校验与格式化，不发起任何网络请求，可离线重复运行。
"""
import json, csv, glob, os, datetime, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MID = 94510621
NAME = "梗指南"
TOTAL_EXPECTED = 1272
PAGES_EXPECTED = 32
GLOB_PATTERN = ".zn_caps_*.json"

def load_pages():
    pages = {}
    for fp in sorted(glob.glob(os.path.join(HERE, GLOB_PATTERN))):
        with open(fp, encoding="utf-8") as f:
            obj = json.load(f)
        for k, v in obj.items():
            if not str(k).isdigit():
                continue
            pages[int(k)] = v
    return pages

def main():
    pages = load_pages()
    missing = [p for p in range(1, PAGES_EXPECTED + 1) if p not in pages]
    if missing:
        sys.exit(f"缺页: {missing}")

    rows = []
    for p in range(1, PAGES_EXPECTED + 1):
        rows.extend(pages[p])

    seen = set(); dedup = []
    for v in rows:
        if v["bvid"] in seen:
            continue
        seen.add(v["bvid"]); dedup.append(v)
    dedup.sort(key=lambda x: (-x["created"], x["bvid"]))

    assert len(dedup) == TOTAL_EXPECTED, f"总数异常 {len(dedup)} != {TOTAL_EXPECTED}"

    tz = datetime.timezone(datetime.timedelta(hours=8))
    videos = []
    for i, v in enumerate(dedup, 1):
        dt = datetime.datetime.fromtimestamp(v["created"], tz)
        videos.append({
            "idx": i,
            "bvid": v["bvid"],
            "aid": v.get("aid"),
            "title": v["title"],
            "created_ts": v["created"],
            "date": dt.strftime("%Y-%m-%d"),
            "length": v.get("length", ""),
            "play": v.get("play"),
            "video_review": v.get("video_review"),
            "typeid": v.get("typeid"),
            "typename": v.get("typename") or "",
            "is_union_video": v.get("is_union_video", 0),
            "url": f"https://www.bilibili.com/video/{v['bvid']}",
        })

    collected_at = datetime.datetime.now(tz).strftime("%Y-%m-%d %H:%M:%S %z")
    meta = {
        "mid": MID, "name": NAME,
        "source": "https://space.bilibili.com/94510621/upload/video (wbi/arc/search, ps=40 x32 pages)",
        "collected_at": collected_at,
        "total": len(videos),
        "date_range": [videos[-1]["date"], videos[0]["date"]],
        "videos": videos,
    }

    jpath = os.path.join(HERE, "genzhinan-videos.json")
    with open(jpath, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    cpath = os.path.join(HERE, "genzhinan-videos.csv")
    cols = ["idx", "date", "bvid", "title", "length", "play", "video_review",
            "typename", "aid", "created_ts", "url"]
    with open(cpath, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols); w.writeheader()
        for v in videos:
            w.writerow({k: v[k] for k in cols})

    mpath = os.path.join(HERE, "梗指南视频标题全集.md")
    with open(mpath, "w", encoding="utf-8") as f:
        f.write(f"# 梗指南（B 站 UID {MID}）全部投稿视频标题全集\n\n")
        f.write(f"- 账号：{NAME}（https://space.bilibili.com/{MID}）\n")
        f.write(f"- 视频总数：**{len(videos)}**（投稿日期 {videos[-1]['date']} ~ {videos[0]['date']}，按投稿时间倒序）\n")
        f.write(f"- 采集时间：{collected_at}（UTC+8）\n")
        f.write(f"- 采集方式：浏览器同源读取空间页 wbi/arc/search 接口，ps=40 共 32 页；已校验 32 页齐全、bvid 零重复、时间倒序无越序\n\n")
        f.write("| # | 日期 | 时长 | 标题 | BV |\n")
        f.write("|---:|---|---|---|---|\n")
        for v in videos:
            title = v["title"].replace("|", "丨").replace("\n", " ")
            f.write(f"| {v['idx']} | {v['date']} | {v['length']} | {title} | {v['bvid']} |\n")

    print("pages:", PAGES_EXPECTED, "total:", len(videos), "unique bvid:", len(seen))
    print("date range:", videos[-1]["date"], "->", videos[0]["date"])
    for p in (jpath, cpath, mpath):
        print(" ", p, os.path.getsize(p), "bytes")

if __name__ == "__main__":
    main()
