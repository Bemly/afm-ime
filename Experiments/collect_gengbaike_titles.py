#!/usr/bin/env python3
"""收集 B 站 UID 1544008396（梗百科）全部投稿视频标题。
接口: x/space/wbi/arc/search（wbi 签名 + buvid cookie + dm 风控参数）。
输出: gengbaike-videos.json / .csv / 梗百科视频标题全集.md（同目录）。
可重复运行: python3 Experiments/collect_gengbaike_titles.py
"""
import urllib.request, urllib.parse, json, time, hashlib, csv, os, sys

MID = 1544008396
PS = 50
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
TAB = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,
       14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,
       56,59,6,63,57,62,11,36,20,34,44,52]
COOKIES = {}


def get(url, retries=6, voucher=None):
    """请求单页；-352 带 v_voucher 挑战重试；412 走长指数退避。"""
    backoff = [5, 10, 20, 30, 45, 60]
    last = None
    for i in range(retries):
        try:
            h = {"User-Agent": UA,
                 "Referer": f"https://space.bilibili.com/{MID}/video",
                 "Accept": "application/json, text/plain, */*",
                 "Accept-Language": "zh-CN,zh;q=0.9",
                 "Origin": "https://space.bilibili.com"}
            ck = dict(COOKIES)
            if voucher:
                ck["v_voucher"] = voucher
            if ck:
                h["Cookie"] = "; ".join(f"{k}={v}" for k, v in ck.items())
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=20) as r:
                    data = json.load(r)
            except urllib.error.HTTPError as he:
                body = he.read().decode("utf-8", "ignore")
                try:
                    data = json.loads(body)
                except Exception:
                    print(f"  HTTP {he.code}, backoff {backoff[i]}s", flush=True)
                    time.sleep(backoff[i]); last = he; continue
            if data.get("code") in (-352, -412):
                vv = data.get("data", {}).get("v_voucher")
                if vv:
                    voucher = vv
                print(f"  code {data.get('code')} {data.get('message')}, backoff {backoff[i]}s", flush=True)
                time.sleep(backoff[i]); continue
            return data
        except Exception as e:  # noqa
            last = e
            time.sleep(backoff[i])
    raise last


def wbi_mixin():
    import uuid
    spi = get("https://api.bilibili.com/x/frontend/finger/spi")
    COOKIES["buvid3"] = spi["data"]["b_3"]
    COOKIES["buvid4"] = spi["data"]["b_4"]
    COOKIES["b_nut"] = str(int(time.time()))
    COOKIES["buvid_fp"] = uuid.uuid4().hex
    # 访问空间主页，补齐站点下发的 cookie
    try:
        req = urllib.request.Request(f"https://space.bilibili.com/{MID}/video",
                                     headers={"User-Agent": UA})
        urllib.request.urlopen(req, timeout=20).read(200)
    except Exception:
        pass
    time.sleep(1.5)
    nav = get("https://api.bilibili.com/x/web-interface/nav")
    w = nav["data"]["wbi_img"]
    raw = (w["img_url"].rsplit("/", 1)[-1].split(".")[0]
           + w["sub_url"].rsplit("/", 1)[-1].split(".")[0])
    return "".join(raw[i] for i in TAB)[:32]


def sign(params, mixin):
    p = dict(params)
    p["wts"] = int(time.time())
    q = urllib.parse.urlencode(sorted(p.items()))
    p["w_rid"] = hashlib.md5((q + mixin).encode()).hexdigest()
    return urllib.parse.urlencode(sorted(p.items()))


def main():
    out_dir = os.path.dirname(os.path.abspath(__file__))
    mixin = wbi_mixin()
    base_params = {
        "mid": MID, "order": "pubdate", "platform": "web",
        "web_location": 1550101, "order_avoided": "true",
        "dm_img_list": "[]",
        "dm_img_str": "V2ViR0wgMS4wIChPcGVuR0wgRVMgMi4wIENocm9taXVtKQ",
        "dm_cover_img_str": ("QU5HTEUgKEludGVsLCBNZXRhbCBSZW5kZXJpbmcgTExDICgweDAwMDA4MTA4"
                             "KSBDaHJvbWl1bQ"),
        "dm_img_inter": '{"src":[],"dst":[],"obj":[]}',
    }

    cache_path = os.path.join(out_dir, ".gengbaike_cache.json")
    page_cache = {}
    if os.path.exists(cache_path):
        page_cache = json.load(open(cache_path, encoding="utf-8"))
        print(f"resume from cache: {len(page_cache)} pages")

    def fetch_page(pn):
        if str(pn) in page_cache:
            return page_cache[str(pn)]
        r = get("https://api.bilibili.com/x/space/wbi/arc/search?"
                + sign({**base_params, "ps": PS, "pn": pn}, mixin))
        if r.get("code") != 0:
            raise RuntimeError(f"page {pn}: {r}")
        batch = r["data"]["list"]["vlist"]
        page_cache[str(pn)] = batch
        json.dump(page_cache, open(cache_path, "w", encoding="utf-8"), ensure_ascii=False)
        return batch

    first_batch = fetch_page(1)
    # 总数以第 1 页为准（单独再请求一次 page 信息成本高，这里用固定已知值兜底校验）
    probe = get("https://api.bilibili.com/x/space/wbi/arc/search?"
                + sign({**base_params, "ps": 1, "pn": 1}, mixin))
    total = probe["data"]["page"]["count"]
    pages = (total + PS - 1) // PS
    print(f"total={total} pages={pages}")

    videos = list(first_batch)
    for pn in range(2, pages + 1):
        batch = fetch_page(pn)
        videos.extend(batch)
        print(f"page {pn}/{pages} +{len(batch)} (cum {len(videos)})", flush=True)
        time.sleep(2.0)

    # 去重（bvid）并按发布时间倒序（接口本身倒序，这里兜底）
    seen, uniq = set(), []
    for v in videos:
        if v["bvid"] not in seen:
            seen.add(v["bvid"]); uniq.append(v)
    uniq.sort(key=lambda v: v["created"], reverse=True)
    print("unique:", len(uniq), "expected:", total)

    records = [{
        "idx": i + 1,
        "bvid": v["bvid"], "aid": v.get("aid"),
        "title": v["title"],
        "created_ts": v["created"],
        "date": time.strftime("%Y-%m-%d", time.localtime(v["created"])),
        "length": v.get("length"),
        "play": v.get("play"), "video_review": v.get("video_review"),
        "typeid": v.get("typeid"), "typename": v.get("typename"),
        "is_union_video": v.get("is_union_video"),
        "url": f"https://www.bilibili.com/video/{v['bvid']}",
    } for i, v in enumerate(uniq)]

    with open(os.path.join(out_dir, "gengbaike-videos.json"), "w", encoding="utf-8") as f:
        json.dump({"mid": MID, "name": "梗百科", "collected_at": time.strftime("%Y-%m-%d %H:%M:%S"),
                   "total": len(records), "videos": records}, f, ensure_ascii=False, indent=1)

    with open(os.path.join(out_dir, "gengbaike-videos.csv"), "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(records[0].keys()))
        w.writeheader(); w.writerows(records)

    with open(os.path.join(out_dir, "梗百科视频标题全集.md"), "w", encoding="utf-8") as f:
        f.write("# 梗百科（UID 1544008396）全部投稿视频标题\n\n")
        f.write(f"- 收集时间：{time.strftime('%Y-%m-%d %H:%M')}　共 {len(records)} 个视频（接口 count={total}）\n")
        f.write("- 排序：按发布时间倒序；字段：序号 | 日期 | 时长 | 标题 | BV\n\n")
        f.write("| # | 日期 | 时长 | 标题 | BV |\n|---|---|---|---|---|\n")
        for r in records:
            t = r["title"].replace("|", "丨")
            f.write(f"| {r['idx']} | {r['date']} | {r['length']} | {t} | {r['bvid']} |\n")
    if os.path.exists(cache_path):
        os.remove(cache_path)
    print("written: gengbaike-videos.json/.csv, 梗百科视频标题全集.md")


if __name__ == "__main__":
    main()
