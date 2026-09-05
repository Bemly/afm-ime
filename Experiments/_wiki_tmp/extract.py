# -*- coding: utf-8 -*-
"""从「中国大陆网络用语列表」wikitext 提取所有加粗词条(渲染后即 <b>)。
判据: 只取星号列表行行首到首个全角解释冒号「:」之间的「词条名区」;
冒号之后是描述区(逐字拆解/拼音注释/GTA 字母都在那里, 天然排除)。
名区内再剔除「紧邻多字主词的逐字拆解短片段」。
"""
import re, sys, subprocess, os

RAW = os.path.join(os.path.dirname(__file__), "raw.wiki")
t = open(RAW, encoding="utf-8").read()
lines = t.splitlines()

# ---- 清洗单个加粗片段内部的 wikitext ----
def clean(s: str) -> str:
    s = re.sub(r"<ref\b.*?</ref>", "", s, flags=re.S)
    s = re.sub(r"<ref[^>]*/>", "", s)
    s = re.sub(r"<[^>]+>", "", s)
    for _ in range(6):  # 去嵌套模板 {{...}}
        n = re.sub(r"\{\{[^{}]*\}\}", "", s)
        if n == s: break
        s = n
    def wl(m):
        inner = m.group(1)
        return inner.split("|")[-1] if "|" in inner else inner
    for _ in range(6):  # [[a|b]]->b, [[a]]->a
        n = re.sub(r"\[\[([^\[\]]*)\]\]", wl, s)
        if n == s: break
        s = n
    s = s.replace("-{", "").replace("}-", "")          # 语言转换标记
    s = re.sub(r"\[https?://[^\s\]]+\s*([^\]]*)\]", r"\1", s)
    s = re.sub(r"https?://\S+", "", s)
    return s.strip()

def name_zone(ln: str):
    """列表标记后的词条名区: 到首个全角冒号, 并在 <ref/{{Cite 前截断。"""
    m = re.match(r"^\s*[\*#:;]+\s?(.*)$", ln)
    if not m: return None
    body = m.group(1)
    cut = len(body)
    for sep in ["："]:
        i = body.find(sep)
        if i != -1: cut = min(cut, i)
    for marker in ["<ref", "{{Cite", "{{cite", "{{cite web", "{{footnote"]:
        j = body.find(marker)
        if j != -1: cut = min(cut, j)
    return body[:cut]

BOLD = re.compile(r"'''(.+?)'''")
dropped = []
raw_terms = []   # (片段原文, 清洗后)
for ln in lines:
    zone = name_zone(ln)
    if zone is None or "'''" not in zone: continue
    frags = [clean(f) for f in BOLD.findall(zone)]
    frags = [f for f in frags if f]
    if not frags: continue
    # 逐字拆解过滤: 短片段(<=2 纯汉字/字母)顺序拼接若==前一个 >=3 主词则丢
    main = None
    for f in frags:
        han = re.sub(r"[^\u4e00-\u9fffA-Za-z]", "", f)
        if main and len(han) <= 2 and han in main:
            # 仅当它是主词的"逐字/逐段"覆盖才丢(累积式, 用后即减)
            dropped.append((main, f))
            continue
        raw_terms.append(f)
        if len(han) >= 3 and main is None:
            main = han

# ---- 拆并列 ----
# 紧邻成对引号 “A”“B” -> A、B(并列); 内嵌引号(引号前有字)仅去引号不拆
def norm_quotes(s):
    s = re.sub(r'[”’"\']\s*[“‘"\']', '、', s)   # 紧邻引号对 => 分隔
    return s.replace('“','').replace('”','').replace('‘','').replace('’','').replace('"','').replace("'","")
PAREN = re.compile(r"[（(]([^（）()]*)[）)]")
SPLIT = re.compile(r"[／/、，,；;]")
DROP = {"《王者荣耀》相关", "爱国"}          # 分节小标题 / 括号残片(火线入党(爱国)非简称), 非用语
ADD  = ["西大","软蛆","索狗","任豚","X黑",            # 描述区并列加粗(已核对原文)
        "小伙伴","兔友","黑厂",                        # 语源/同类行内加粗
        "1912年入宫","49年入国军",                     # 火线入党条目"如…等"并列梗
        "最好先定一个能达到的小目标。比如我先挣它一个亿"]  # 小目标条目完整加粗原句
terms = []
seen = set()
def add(w):
    w = norm_quotes(w)
    w = w.strip(" 　·:：，,。、（）()*?？!！ ")   # 注: 保留 ~～(～爷 是后缀)
    if not w or w in DROP: return
    key = w.lower() if re.fullmatch(r"[A-Za-z0-9 .'-]+", w) else w  # 英文大小写归一
    if key in seen: return
    seen.add(key); terms.append(w)
def emit(frag):
    frag = norm_quotes(frag)   # 先归一紧邻引号对为顿号, 再拆分
    # 抽括号: 主名 + 括号内简称(去"简称/又称"等引导与引号)
    m = PAREN.search(frag)
    head = PAREN.sub("", frag)
    alias = []
    if m:
        inner = re.sub(r"^(简称|简写|缩写|又称|也叫|也作|即)", "", m.group(1))
        inner = inner.strip(' “”"\'')
        if inner: alias = [inner]
    for x in [head]+alias:
        for p in SPLIT.split(x): add(p)
for f in raw_terms:
    emit(f)
for a in ADD: add(a)

# ---- opencc 繁->简 (用项目 venv 的 C++ 版) ----
OPENCC = "vendor/fcitx5-pinyin-minecraft/.venv/bin/python"
def t2s(words):
    code = "import opencc,sys;c=opencc.OpenCC('t2s');print('\\n'.join(c.convert(l) for l in sys.stdin.read().split('\\n')))"
    p = subprocess.run([OPENCC, "-c", code], input="\n".join(words),
                       capture_output=True, text=True, cwd="/Users/bemly/Projects/afm-ime")
    return p.stdout.split("\n")

terms_simp = []
ss = set()
for w in t2s(terms):
    w = w.strip()
    if w and w not in ss:
        ss.add(w); terms_simp.append(w)

print("=== 名区片段数:", len(raw_terms), " 拆分去重后(简):", len(terms_simp))
print("=== 被判逐字拆解丢弃:", len(dropped))
for m,f in dropped: print("   drop", repr(m), "->", repr(f))
print("=== 结果 ===")
for i,w in enumerate(terms_simp): print(i, w)

# ---- 写 markdown(只含字词, 按页面出现顺序) ----
out = os.path.join(os.path.dirname(__file__), "..", "中国大陆网络用语-加粗词.md")
out = os.path.normpath(out)
with open(out, "w", encoding="utf-8") as fp:
    fp.write("# 中国大陆网络用语列表 · 加粗词条全集\n\n")
    fp.write("> 来源: 中文维基百科「中国大陆网络用语列表」页面中所有加粗(`<b>`/`'''…'''`)词条\n")
    fp.write("> 已剔除逐字拆解、拼音注释、引用标题等非词条加粗; 繁体经 OpenCC 转简体; 并列别名已拆分去重\n\n")
    for w in terms_simp:
        fp.write(f"- {w}\n")
print("\n写出:", out, len(terms_simp), "条")
