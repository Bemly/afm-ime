# -*- coding: utf-8 -*-
"""
以用户手工编辑过的《梗合集-关键词拼音全集.md》为唯一输入（保留其增删改与顺序），
把较长的关键句用 rime-ice 词库做“最长非重叠覆盖”拆散为更小的候选词，输出两列：
  | 关键词 | 拆成关键词的关键句 |
- 每个原始关键词保留为一条主行（第二列空）；
- 从长句拆出的子词紧跟该句之后，第二列标注来源父句；同一关键词全局只出现一次，
  若它同时被多个长句拆出，来源句用 ； 合并；
- ≤5 个汉字的短梗名整体保留不拆；子词必须是 rime 词库中 2-6 字、不以功能字首尾的真词。
本脚本不联网、不改原 md。
"""
import os, re, csv, json

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_MD = os.path.join(HERE, "梗合集-关键词拼音全集.md")
WORDFILE = os.path.join(HERE, ".jieba_userdict.txt")
OUT_MD = os.path.join(HERE, "梗合集-关键词拆散.md")
OUT_CSV = os.path.join(HERE, "梗合集-关键词拆散.csv")

# ---------- 1. 读取用户 md 的关键词列（第 4 列），保留顺序 ----------
roots = []
with open(SRC_MD, encoding="utf-8") as f:
    for ln in f:
        if not ln.startswith("|"):
            continue
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        if len(cells) != 5:
            continue
        if cells[0] in ("#", "---:") or set("".join(cells)) <= set("-: "):
            continue
        kw = cells[3].replace("丨", "|").strip()
        if kw:
            roots.append(kw)
print("原始关键词行:", len(roots))

# ---------- 2. rime 词库 + 拆散规则 ----------
words = set()
with open(WORDFILE, encoding="utf-8") as f:
    for line in f:
        words.add(line.split(" ")[0])
han = re.compile(r"[\u4e00-\u9fff]")
def is_han(c): return bool(han.match(c))
FUNC = set("的了着是被把给让不没你我他她它您这那哪咋啥个吗呢啊吧呀哦嘛呗哈嗯几有也都就还又却向从到为")
STOP = set("""不是 这样 那样 这么 那么 怎么 怎样 什么 这个 那个 这些 那些 里面 外面 还是 就是 可是 但是
可以 应该 没有 一个 几个 有点 一些 真的 我的 你的 他的 我们 你们 他们 她们 它们 自己 会不会
能不能 是不是 有没有 怎么样 一下子 来着 而已 罢了 真是 简直""".split())
MINL, MAXL = 2, 6
def _clean(t): return t not in STOP and t[0] not in FUNC and t[-1] not in FUNC
# 片段：连续汉字块 / 英文数字块（内部允许空格·连字符·点·&）/ 其余
TOK_RE = re.compile(r"[一-鿿]+|[A-Za-z0-9]+(?:[ .\-'&]+[A-Za-z0-9]+)*")
def _keep_latin(t):
    t = t.strip()
    if len(t) < 2: return False
    if re.fullmatch(r"\d+", t): return False          # 纯数字（年份/编号）不入词
    if re.fullmatch(r"[Xx]{2,}", t): return False      # XX/XXX 占位符
    return True
def subtokens(s):
    if sum(1 for c in s if is_han(c)) <= 5:
        return []
    res = []
    for m in TOK_RE.finditer(s):
        seg = m.group(0)
        if is_han(seg[0]):           # 汉字块：最长非重叠覆盖
            i, n = 0, len(seg)
            while i < n:
                pick = None
                for L in range(min(MAXL, n - i), MINL - 1, -1):
                    cand = seg[i:i+L]
                    if cand in words and _clean(cand): pick = cand; break
                if pick: res.append(pick); i += len(pick)
                else: i += 1
        else:                        # 英文数字块整体
            if _keep_latin(seg): res.append(seg.strip())
    out, seen = [], set()
    for t in res:
        if t not in seen: seen.add(t); out.append(t)
    return out

# ---------- 3. 聚合：根行 + 子词紧跟父句，同词只一次 ----------
order, idx = [], {}
def push(kw, src=None):
    if kw in idx:
        if src and src != kw: idx[kw]["srcs"].add(src)
    else:
        rec = {"kw": kw, "srcs": set()}
        if src and src != kw: rec["srcs"].add(src)
        idx[kw] = rec; order.append(rec)

n_sub = 0
for s in roots:
    push(s)
    for w in subtokens(s):
        if w != s:
            if w not in idx: n_sub += 1
            push(w, s)
print("新增拆分子词条:", n_sub, " 去重后总关键词条:", len(order))
multi = sum(1 for r in order if len(r["srcs"]) > 1)
print("被多个父句拆出的词:", multi)

def cell(s): return s.replace("|", "丨").replace("\n", " ")

# ---------- 4. 输出 ----------
with open(OUT_MD, "w", encoding="utf-8") as f:
    f.write("# 梗百科 × 梗指南 · 关键词拆散草稿（词库预备，尚未成词库）\n\n")
    f.write(f"- 原始关键句 {len(roots)} 条；经 rime-ice 词库最长匹配补拆子词 {n_sub} 条；去重后共 **{len(order)}** 个关键词\n")
    f.write("- 列含义：`关键词`为可入词库的词/短语；`拆成关键词的关键句`标注该词是从哪条长句拆出（空=它本身就是原始关键句/短梗名）\n")
    f.write("- 规则：≤5 汉字的短梗名整体不拆；子词须为词库内 2–6 字、不以的/了/是/不/你等功能字首尾的真词；英文数字整体保留。可直接人工增删\n\n")
    f.write("| 关键词 | 拆成关键词的关键句 |\n|---|---|\n")
    for r in order:
        src = "；".join(sorted(r["srcs"]))
        f.write(f"| {cell(r['kw'])} | {cell(src)} |\n")

with open(OUT_CSV, "w", encoding="utf-8-sig", newline="") as f:
    w = csv.writer(f); w.writerow(["关键词", "拆成关键词的关键句", "来源句数量"])
    for r in order:
        w.writerow([r["kw"], "；".join(sorted(r["srcs"])), len(r["srcs"])])

print("写出:", OUT_MD, os.path.getsize(OUT_MD), "bytes")
print("写出:", OUT_CSV)
