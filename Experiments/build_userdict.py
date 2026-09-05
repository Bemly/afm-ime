# -*- coding: utf-8 -*-
"""从 rime-ice 词库生成 jieba 自定义词典（缓存，只需跑一次）。"""
import re, math, os
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = [
    f"{ROOT}/vendor/rime-ice/cn_dicts/base.dict.yaml",
    f"{ROOT}/vendor/rime-ice/cn_dicts/ext.dict.yaml",
    f"{ROOT}/vendor/rime-ice/cn_dicts/41448.dict.yaml",
    f"{ROOT}/vendor/rime-ice/cn_dicts/8105.dict.yaml",
]
OUT = f"{HERE}/.jieba_userdict.txt"
han = re.compile(r"^[\u4e00-\u9fffA-Za-z0-9]{2,8}$")
words = {}
n = 0
for fp in SRC:
    if not os.path.exists(fp):
        continue
    with open(fp, encoding="utf-8") as f:
        for line in f:
            if line.startswith(("#", "-", " ", "\t")) or "\t" not in line:
                continue
            parts = line.rstrip("\n").split("\t")
            w = parts[0]
            if not han.match(w):
                continue
            freq = 500
            if len(parts) >= 3:
                try:
                    freq = max(50, int(math.sqrt(int(parts[2]))))
                except Exception:
                    pass
            # 保留较高词频，使 rime 词优先成词
            words[w] = max(words.get(w, 0), freq)
            n += 1
with open(OUT, "w", encoding="utf-8") as f:
    for w, fr in sorted(words.items()):
        f.write(f"{w} {fr}\n")
print("源词条行:", n, "去重后入典:", len(words), "->", OUT)
