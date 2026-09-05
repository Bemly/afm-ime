#!/usr/bin/env python3
# CLDR 官方中文 emoji 注解 → vendor/emoji/emoji-zh.txt(词\t拼音\t权重)
# 供 dictcompiler --apostrophe 收录;首次需网络下载 CLDR JSON(缓存复用,之后离线可用)
# 运行: <venv with pypinyin>/python scripts/build_emoji.py   (build_dict.sh 自动调用)
import json
import os
import sys
import urllib.request

CACHE = "vendor/emoji/cldr-zh-annotations.json"
OUT = "vendor/emoji/emoji-zh.txt"
URL = ("https://raw.githubusercontent.com/unicode-org/cldr-json/main/"
       "cldr-json/cldr-annotations-full/annotations/zh/annotations.json")
WEIGHT = 2000        # emoji 权重: 低于高频词但高于长尾,保证在热门键的 32 条截断线内可见
MAX_KEYS = 4         # 每个 emoji 最多的拼音键数(名称 + 前 3 个关键词)


def is_emoji(cp: str) -> bool:
    # emoji 主区 + 杂项符号/装饰(含 ⌘⌥⇧ 等,CLDR 一并给了中文名) + 箭头补充区
    return any(ord(c) >= 0x1F000 for c in cp) \
        or any(0x2300 <= ord(c) <= 0x27BF for c in cp) \
        or any(0x2B00 <= ord(c) <= 0x2BFF for c in cp)


def is_cjk(s: str) -> bool:
    return any(0x4E00 <= ord(c) <= 0x9FFF for c in s) and len(s) <= 8


def key_of(text: str) -> str:
    from pypinyin import lazy_pinyin
    return "'".join(lazy_pinyin(text.strip()))


def main() -> None:
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    if not os.path.exists(CACHE):
        print("下载 CLDR 中文注解(缓存到 %s)…" % CACHE)
        urllib.request.urlretrieve(URL, CACHE)
    with open(CACHE, encoding="utf-8") as f:
        data = json.load(f)
    annos = data["annotations"]["annotations"]

    from pypinyin import lazy_pinyin  # noqa: F401  (确认依赖在位)
    lines, seen = [], set()
    for cp, entry in sorted(annos.items()):
        if not is_emoji(cp):
            continue
        keys: list[str] = []
        tts = entry.get("tts") or []
        defaults = entry.get("default") or []
        for kw in ([tts[0]] if tts else []) + defaults[:3]:
            kw = kw.split(":")[-1].strip()  # 「旗: 中国」→ 中国
            if not is_cjk(kw):
                continue
            k = key_of(kw)
            if k and k not in keys:
                keys.append(k)
            if len(keys) >= MAX_KEYS:
                break
        for k in keys:
            dedup = k + "\x01" + cp
            if dedup in seen:
                continue
            seen.add(dedup)
            lines.append(f"{cp}\t{k}\t{WEIGHT}")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"emoji 词库生成完成: {len(lines)} 条 → {OUT}")


if __name__ == "__main__":
    sys.exit(main())
