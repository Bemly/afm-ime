#!/bin/zsh
# 全量词库编译: rime-ice 主库 + 外部词库 → Data/dict.bin
# 外部词库(均在 vendor/,格式细节见 AGENTS.md「词库数据」):
#   萌娘百科  vendor/moegirl/moegirl.dict.yaml          (mw2fcitx 官方月更 release)
#   zhwiki    vendor/zhwiki/zhwiki.dict.yaml            (fcitx5-pinyin-zhwiki release)
#   Minecraft vendor/fcitx5-pinyin-minecraft/mc-cn.raw  (官方脚本抓 wiki API 生成,见下方首次逻辑)
#   蔚蓝档案  vendor/BlueArchive-PinyinDictionary/ALL IN ONE/rime.txt
#   THUOCL    vendor/THUOCL/data/THUOCL_*.txt
#   ali-words vendor/ali-words/src/words.ts
#   梗合集    Experiments/梗合集-关键词拆散.md (markdown 表第一列,自维护)
#   空耳词库  Experiments/空耳词库.txt (手工标注拼音,自维护)
# 用法: scripts/build_dict.sh   (之后 scripts/package.sh 会把 dict.bin 打进 bundle)
set -euo pipefail
cd "$(dirname "$0")/.."

# minecraft 文本词库: 首次(或源更新后删除 mc-cn.raw)用官方脚本生成,需要网络 + venv
MCDIR=vendor/fcitx5-pinyin-minecraft
MCDICT="$MCDIR/mc-cn.raw"
MC_ARGS=()
if [ ! -f "$MCDICT" ]; then
  echo "== 生成 minecraft 文本词库(首次,抓 zh.minecraft.wiki API) =="
  if (
    cd "$MCDIR" &&
    [ -x .venv/bin/python ] || python3 -m venv .venv &&
    ./.venv/bin/pip install -q pypinyin opencc retry &&
    ./.venv/bin/python fetch.py get_all_titles "https://zh.minecraft.wiki/api.php" mc-titles.txt &&
    ./.venv/bin/python collate_moegirl.py mc-titles.txt mc-results.txt &&
    ./.venv/bin/python convert.py mc-results.txt > mc-cn.raw
  ); then
    echo "mc-cn.raw 生成完成: $(wc -l < "$MCDICT") 行"
  else
    echo "!! minecraft 词库生成失败(网络?),本次编译不含 mc 词库"
  fi
fi
[ -f "$MCDICT" ] && MC_ARGS=(--apostrophe "$MCDICT")

# THUOCL 全部词频表(diming 为空文件会被自动跳过)
FREQ_ARGS=()
for f in vendor/THUOCL/data/THUOCL_*.txt; do
  [ -s "$f" ] && FREQ_ARGS+=(--freq "$f")
done

# 梗合集关键词(markdown 表第一列,自维护文件,不在时跳过)
MD_ARGS=()
[ -f "Experiments/梗合集-关键词拆散.md" ] && MD_ARGS=(--md-keywords "Experiments/梗合集-关键词拆散.md")

# 空耳词库(手工标注拼音,不在时跳过)
EAR_ARGS=()
[ -f "Experiments/空耳词库.txt" ] && EAR_ARGS=(--apostrophe "Experiments/空耳词库.txt")

# 热词与符号(手工标注拼音,不在时跳过)
RECI_ARGS=()
[ -f "Experiments/热词与符号词库.txt" ] && RECI_ARGS=(--apostrophe "Experiments/热词与符号词库.txt")

# 化学式/希腊字母(用户自维护,词\tq'y\t权重;元素符号单双字母键靠缩写直查命中)
CHEM_ARGS=()
[ -f "Experiments/化学式词库/化学式词库.txt" ] && CHEM_ARGS+=(--apostrophe "Experiments/化学式词库/化学式词库.txt")
[ -f "Experiments/化学式词库/希腊字母词库.txt" ] && CHEM_ARGS+=(--apostrophe "Experiments/化学式词库/希腊字母词库.txt")

# 网络用语全集(维基百科加粗词条 markdown 无序列表)
SLANG_ARGS=()
[ -f "Experiments/中国大陆网络用语-加粗词.md" ] && SLANG_ARGS+=(--md-list "Experiments/中国大陆网络用语-加粗词.md")

# emoji 词库: CLDR 官方中文注解 → 拼音(缓存复用,首次需网络;生成失败仅告警不中断)
if [ -x "$MCDIR/.venv/bin/python" ]; then
  "$MCDIR/.venv/bin/python" scripts/build_emoji.py \
    || echo "!! emoji 词库生成失败,本次编译不含 emoji"
fi
EMOJI_ARGS=()
[ -f vendor/emoji/emoji-zh.txt ] && EMOJI_ARGS=(--apostrophe vendor/emoji/emoji-zh.txt)

swift build -c release
.build/release/dictcompiler \
  --cn-dicts vendor/rime-ice/cn_dicts \
  --rime vendor/moegirl/moegirl.dict.yaml \
  --rime vendor/zhwiki/zhwiki.dict.yaml \
  --apostrophe "vendor/BlueArchive-PinyinDictionary/ALL IN ONE/rime.txt" \
  "${MC_ARGS[@]}" \
  "${FREQ_ARGS[@]}" \
  --wordlist vendor/ali-words/src/words.ts \
  "${MD_ARGS[@]}" \
  "${EAR_ARGS[@]}" \
  "${RECI_ARGS[@]}" \
  "${CHEM_ARGS[@]}" \
  "${SLANG_ARGS[@]}" \
  "${EMOJI_ARGS[@]}" \
  --out Data/dict.bin
