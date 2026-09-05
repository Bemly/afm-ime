#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
化学式 / 希腊字母输入法词库构建
来源(均为「自定义输入编码 -> 目标串」的第三方输入法自定义短语):
  - chemical(7).dat  微软拼音 v7 全拼(主源, 最新最全, UTF-16LE 二进制 .dat)
  - 全拼chemical(5).txt  v5 明文, 提供作者人工分音节(带空格)用于校正连写切分
  - 03_..._字母-化学式.dat  字母缩写源, 仅补主源缺失的 3 个值
  - Win10微软拼音词库_希腊字母.dat  希腊字母(英文全名/中文音译拼音/大小写)
产物(与 热词与符号词库.txt 同格式: 词\t撇号分音节无声调拼音\t权重):
  - 化学式词库.txt
  - 希腊字母词库.txt
"""
import re, os, json, sys
from collections import OrderedDict, Counter

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "_src")
W7 = os.path.join(SRC, "wps_chemical7", "chemical(7)")
B1 = os.path.join(SRC, "baidu_batch1", "分享资源", "自定义的短语库", "chemical", "导入文件_微软win10")
BX = os.path.join(SRC, "baidu_batch_readme", "分享资源", "自定义的短语库", "希腊字母")

def read16(p):
    return open(p, "rb").read().decode("utf-16-le", errors="ignore")

def parse_dat(p):
    # 数据区每条记录: 编码\x00 目标串\x00 \x10\x10
    return re.findall(r"([A-Za-z][A-Za-z0-9.]*)\x00([^\x00]{1,120}?)\x00\x10\x10", read16(p))

# ---------- 合法音节表(取自项目 rime-ice, 与输入法切分器同源) ----------
SYL = set(json.load(open(os.path.join(SRC, "_syllables.json"), encoding="utf-8")))

def _dp(word, allow_letter):
    n = len(word); ways = [None]*(n+1); ways[n] = [[]]
    for i in range(n-1, -1, -1):
        acc = []
        for L in range(1, min(6, n-i)+1):
            piece = word[i:i+L]
            if ways[i+L] is None: continue
            if piece in SYL:
                for tail in ways[i+L]: acc.append([piece]+tail)
            elif allow_letter and L == 1 and piece.isalpha():  # 元素字母段
                for tail in ways[i+L]: acc.append([piece]+tail)
        seen=set(); uniq=[]
        for w in acc:
            k=tuple(w)
            if k not in seen: seen.add(k); uniq.append(w)
        ways[i] = uniq if uniq else None
    if not ways[0]: return None
    # 音节数少 > 首音节长(最大匹配)
    ways[0].sort(key=lambda w: (len(w), -len(w[0])))
    return ways[0][0]

def strict_split(word):
    """仅用合法拼音音节, 不允许元素单字母。"""
    return _dp(word, False)

def max_match(word):
    """允许吞单个 a-z 元素字母段。返回 (list, 是否含单字母段)。"""
    r = _dp(word, True)
    if r is None: return None, False
    return r, any(len(s) == 1 for s in r)

# ---------- chem5 人工分节 ----------
def chem5_spacing():
    """连写键 -> set(作者人工分节 tuple)"""
    m = {}
    p = os.path.join(W7, "全拼chemical(5).txt")
    for line in read16(p).splitlines():
        a = line.lstrip("﻿").strip().split("\t")
        if len(a) >= 3:
            joined = a[1].replace(" ", "")
            m.setdefault(joined, set()).add(tuple(a[1].split()))
    return m

def best_split(key, chem):
    """判定键类型并给出最终键序列:
       - pinyin: 纯拼音键, chem5 人工分节优先、否则严格最大匹配
       - mixed:  拼音主体+少量元素尾字母(如 weishengsu+c)
       - letter: 元素符号/字母缩写连写(bf/cc/hcl), 整体保留不分节
    """
    st = strict_split(key)
    if st is not None:
        cands = chem.get(key)
        if cands:
            def valid(t): return all(s in SYL for s in t)
            good = [t for t in cands if valid(t)]
            if good:
                good.sort(key=lambda t: (t != tuple(st), len(t)))
                return list(good[0]), "pinyin"
        return st, "pinyin"
    lo, has_letter = max_match(key)
    if lo:
        multi = sum(1 for s in lo if len(s) >= 2)
        single = sum(1 for s in lo if len(s) == 1)
        if multi >= 2 and multi >= single:   # 完整拼音为主体(>=2段)、仅尾缀少量元素字母
            return lo, "mixed"
    return [key], "letter"

# ---------- pypinyin 给纯中文(元素名)注标准拼音 ----------
from pypinyin import lazy_pinyin
def cjk_pinyin(word):
    py = [s for s in lazy_pinyin(word) if re.search(r"[a-z]", s)]
    return py

CJK = re.compile(r"^[一-鿿]+$")

def build_chem():
    chem = chem5_spacing()
    d7 = parse_dat(os.path.join(W7, "微软全拼chemical(7).dat"))
    d3 = parse_dat(os.path.join(B1, "03_微软全拼-拓展包_字母-化学式.dat"))
    v7 = set(v for _, v in d7)
    # 03 仅补主源缺失值(用其字母缩写键)
    extra = [(k, v) for k, v in d3 if v not in v7]

    rows = OrderedDict()   # (word,py)->weight ; 用 key 去重保序
    notes = Counter()
    flagged = []
    def add(word, py_list, weight=100):
        if not py_list: return
        py = "'".join(py_list)
        if not word or not py: return
        rows[(word, py)] = weight

    for key, val in d7:
        if CJK.match(val):
            # 元素中文名: ①标准拼音(pypinyin) ②元素符号原键(小写, 打符号出元素名)
            std = cjk_pinyin(val)
            if std: add(val, std)
            add(val, [key])
            notes["元素名-标准拼音"] += 1
            notes["元素名-符号键"] += 1
            continue
        split, kind = best_split(key, chem)
        if not split:
            flagged.append(("UNSPLIT", key, val)); continue
        add(val, split)
        notes[kind] += 1
        if kind == "mixed":  # 拼音夹带元素字母, 列出人工核对
            flagged.append(("MIXED", key, "'".join(split), val))
    for key, val in extra:
        add(val, [key])  # 03 独有值, 字母键
    notes["03字母源补入"] = len(extra)

    # 输出(按拼音排序)
    out = sorted(rows.items(), key=lambda kv: (kv[0][1], kv[0][0]))
    with open(os.path.join(HERE, "化学式词库.txt"), "w", encoding="utf-8") as f:
        f.write("# 化学式/元素 自定义词库(由 chemical(7) 微软全拼 v7 转换, 格式: 词\tq'y\t权重)\n")
        f.write("# 用法: 打术语全拼出化学式(如 an'gen->NH₄⁺); 打元素符号或拼音出元素名(ac/锕->锕)\n")
        for (w, py), wt in out:
            f.write(f"{w}\t{py}\t{wt}\n")
    return out, flagged, notes, extra

# ---------- 希腊字母(表驱动; 英文全名键 + 中文音译拼音键, 含大小写) ----------
# 音译优先采用原作者 dat 中的拼音键(aerfa/beita/...), 作者缺失的 theta/sigma 按通用译名补;
# 不收 x前缀/三字母英文缩写/单字母首字母(易与正常拼音冲突、易误触)。
# (英文全名, 小写, 大写, 中文音译分节拼音)
GREEK = [
    ("alpha","α","Α",["a","er","fa"]),      # 阿尔法
    ("beta","β","Β",["bei","ta"]),          # 贝塔
    ("gamma","γ","Γ",["ga","ma"]),          # 伽马
    ("delta","δ","Δ",["de","er","ta"]),     # 德尔塔
    ("epsilon","ε","Ε",["yi","pu","xi","long"]),  # 艾普西龙(从作者 yipuxilong)
    ("zeta","ζ","Ζ",["jie","ta"]),          # 泽塔(从作者 jieta)
    ("eta","η","Η",["ai","ta"]),            # 伊塔/艾塔(从作者 aita)
    ("theta","θ","Θ",["xi","ta"]),          # 西塔(作者缺, 补)
    ("iota","ι","Ι",["yue","ta"]),          # 约塔(从作者 yueta)
    ("kappa","κ","Κ",["ka","pa"]),          # 卡帕
    ("lambda","λ","Λ",["lan","bu","da"]),   # 拉姆达
    ("mu","μ","Μ",["miu"]),                 # 缪
    ("nu","ν","Ν",["niu"]),                 # 纽
    ("xi","ξ","Ξ",["ke","xi"]),             # 克西(从作者 kexi)
    ("omicron","ο","Ο",["ao","mi","ke","rong"]),  # 奥密克戎
    ("pi","π","Π",["pai"]),                 # 派
    ("rho","ρ","Ρ",["rou"]),                # 柔
    ("sigma","σ","Σ",["xi","ge","ma"]),     # 西格马(作者缺, 补)
    ("tau","τ","Τ",["tao"]),                # 陶
    ("upsilon","υ","Υ",["yu","pu","xi","long"]),  # 宇普西龙
    ("phi","φ","Φ",["fo","ai"]),            # 斐(从作者 foai)
    ("chi","χ","Χ",["kai","yi"]),           # 卡伊/希(中文译法分歧, 用卡伊避免与 ξ 的 xi 冲突)
    ("psi","ψ","Ψ",["pu","xi"]),            # 普西
    ("omega","ω","Ω",["ou","mi","ga"]),     # 欧米伽
]
def build_greek():
    rows = OrderedDict()
    def add(w, py_list):
        py = "'".join(py_list)
        if w and py: rows[(w, py)] = 100
    for name, lo, up, tr in GREEK:
        add(lo, [name]); add(up, [name])      # 英文全名键
        add(lo, tr);    add(up, tr)           # 中文音译拼音键
    out = sorted(rows.items(), key=lambda kv: (kv[0][1], kv[0][0]))
    with open(os.path.join(HERE, "希腊字母词库.txt"), "w", encoding="utf-8") as f:
        f.write("# 希腊字母词库(由微软拼音希腊字母包转换; 英文全名键 + 中文音译拼音键; 含大小写)\n")
        f.write("# 用法: alpha/a'er'fa->α(及大写Α); 不收 x前缀/三字母/单字母缩写以免误触\n")
        for (w, py), wt in out:
            f.write(f"{w}\t{py}\t{wt}\n")
    return out

if __name__ == "__main__":
    out, flagged, notes, extra = build_chem()
    print("=== 化学式词库 ===")
    print("词条行数:", len(out), " 分节来源统计:", notes)
    wc = Counter(w for (w, py), _ in out)
    print("不同目标串:", len(wc))
    print("03 补入的独有值:", extra)
    print("混合键(拼音+元素字母)核对:")
    for x in flagged: print("   ", x)
    gout = build_greek()
    print("\n=== 希腊字母词库 ===")
    print("词条行数:", len(gout), "(24 字母 × 大小写 × 英文/拼音两键)")
