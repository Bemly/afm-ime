# AFM拼音 (afm-ime)

macOS 27 液态玻璃(Liquid Glass)风格的中文拼音输入法,调用端侧 Apple Foundation Models(fm)system 大模型增强候选预测。参考 UI:macOS 26 风格候选窗(拼音条 + 候选词网格 + 首选高亮 pill)。

## 环境事实(2026-09-03 已验证)

- macOS 27.0 (Build 26A5425a) arm64;Swift 6.4(~~仅 CommandLineTools~~ **2026-09-06 用户自行安装了 Xcode 27 beta 6 到 /Applications/Xcode-beta.app,并为 Metal Toolchain 组件补了 838.9MB 下载**(`DEVELOPER_DIR=<Xcode> xcodebuild -downloadComponent metalToolchain`);Swift 构建仍走 SPM/CLT 兼容路径,**未动 xcode-select**,需要 Xcode 工具链的步骤(如 metal/metallib)用 `DEVELOPER_DIR` 环境变量按次指定,scripts/package.sh 自动探测)
- SDK: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`,其中:
  - `InputMethodKit.framework`(IMKServer / IMKInputController / IMKCandidates)✅
  - `FoundationModels.framework` swiftmodule ✅(进程内可 import)
  - `AppKit/Headers/NSGlassEffectView.h` ✅(真·液态玻璃 API,Swift 可直接用)
- `/usr/bin/fm` = Apple Foundation Models CLI;`fm available` → system 端侧模型可用;`fm respond` 支持 `--schema`、`--stream`、`--instructions`
- 词库:rime-ice(雾凇拼音)https://github.com/iDvel/rime-ice — 8105 单字 + 41448 词组 + base/ext,当前维护最活跃的开源 rime 词库
- 本机目前没有已安装的第三方输入法

## 架构

```
AFM拼音.app (安装到 ~/Library/Input Methods/)
├── 引擎层(纯 Swift,SPM,无第三方依赖)
│   ├── 词库编译器: rime-ice + 外部词库(萌娘/zhwiki/mcwiki/BA/THUOCL/ali-words/梗合集) → 二进制 dict.bin(698.6 万条/249MB,含简拼派生键,mmap 加载 <1ms,scripts/build_dict.sh 一键全量重编)
│   ├── 拼音切分: 逆序 DP 枚举 ≤12 路音节切分,尾音节允许不完整;模糊音 zh/z ch/c sh/s + 前后鼻音已实现(查询期变体展开,精确优先;v→ü 未实现)
│   └── 候选生成: 多路切分 + mmap 二分前缀查表 + 词格 DP 整句组词(单主路径 composeSentence)+ 用户词频乘法加成,按词频权重打分合并(见决策记录)
├── FM 层(端侧大模型,当前仅进程内单通道)
│   ├── 进程内 import FoundationModels(SystemLanguageModel),每次新建无状态 session
│   ├── (fm CLI 子进程回退通道仅做过延迟基准、尚未接线;不可用时直接静默降级纯词典)
│   ├── 用途①: 结合上文对词典候选异步重排序(到达后无感刷新候选窗)
│   ├── 用途②: 长句拼音直接让模型预测整句/短语(词典切不出时兜底,光标处先显示占位)
│   └── 用途③: ⌃F 内联翻译(组词中候选译文,见候选窗交互定稿)+ 设置中心翻译页(kb34)的译文生成(中↔英方向自动);FMReranker 位于 IMECore(kb34 从 AFMInput 移入并 public 化,设置中心 helper 进程复用同款端侧通道)
└── UI 层
    ├── NSPanel + NSGlassEffectView 真·液态玻璃(圆角/透明/高光/亮暗自适应,macOS 27 开交互式玻璃;<26 退化普通视图)
    ├── 行内 markedText 下划线显示拼音(候选条内不再放拼音框) + 候选词网格、首选高亮 pill、序号、翻页、✦ 标 FM 候选
    ├── 伴随面板: ⌃V 剪贴板历史 / ⌃F 翻译(同款液态玻璃;候选条在→浮其下方,放不下→上方;不在→光标所在屏幕右上角)
    └── 跟随光标定位(client caret rect,缺失时回退屏幕底部居中),点选上屏,数字键 1-9 选词
```

**AFM拼音.app(设置中心,2026-09-06;同日合并进引擎 bundle 为单一 App)**:设置中心是嵌在引擎 bundle **Contents/PlugIns/AFMSettings.app** 的独立进程 helper(id moe.bemly.AFMSettings)——引擎 LSUIElement 不能弹窗,helper 承载窗口;嵌套 bundle 不进 Launchpad/Spotlight 索引,顶层只有「AFM拼音」一个条目。五区:①安装:一键安装并启用/更新(运行于安装位置时无新包可换,提示重打包;部署铁律同款 rm+cp 换盘+killall+确认死透+open)/卸载/一键注销/直达输入源设置;②词库:dict.bin 存储序分页浏览 + 拼音前缀搜索(DictStore.records(from:limit:));③用户词:词/拼音键/次数/档内分/词频乘数,右键删除、清空;④翻译(kb34):端侧 FM 中↔英互译,TextEditor 输入 ⏎ 提交、方向自动(含中文→英)、结果可选中/复制;⑤设置:模糊拼音/全角标点/FM 增强/词频学习四门控 + 候选条字号(13-22)+ 快捷键卡(kb35:剪贴板/内联翻译/设置中心三槽,录制 ⌃+字母/数字/符号——NSEvent 本地监控吞键、冲突检查、Esc 取消、onDisappear 撤监控;keyCode+显示字符双键落盘 AFMHotkey*/*Display,IME 只读键码、object 判 nil 区分「未设置」与键码 0(A),现读现判即时生效;修饰键固定 ⌃)——写 IME 域 defaults(`UserDefaults(suiteName: moe.bemly.inputmethod.AfmIME)` = IME 进程的 .standard 域),IME 现读现判即时生效。**入口**:⌃S 快捷键(kb34,中英模式都拦;**⌃F 维持组词中内联翻译不动**——中间态曾把 ⌃F 改为开设置,用户否决,定稿 ⌃F=内联翻译/⌃S=设置)/输入法菜单「设置…」(InputController.menu→doCommandBySelector,AFM拼音激活时菜单栏可见)/未安装态直接打开 bundle 自动拉起(isBundleInstalled 守卫)。**定位父引擎**:helper bundle 上三级(PlugIns→Contents→引擎.app);**图标**:AppIcon.icns 管线(sips 转 PNG 必须显式 -s format png,否则输出仍是 TIFF 内容 iconutil 拒收),引擎/helper 双包 CFBundleIconFile。**幽灵副本事故(23:03,kb32→kb33)**:幽灵副本退出前的延迟窗口里用同一连接名初始化了完整引擎(IMKServer/剪贴板/ShiftTap 全启动),劫持了客户端 IMK 连接,退出后连接断掉——窗口期(22:50-23:06)开着的应用全部打不了字,只有重启后活跃打字的应用自动重连;修法=自愈逻辑前移到 IMKServer 初始化之前同步 lsregister+立即 exit(0),不碰任何引擎设施;**余波恢复**:受影响应用退出重开一次即重建连接,系统级 killall Finder / killall Dock 即刷,顽固时注销重登。**液态玻璃规范**:@main WindowGroup + NavigationSplitView(系统玻璃 chrome 自动生效),高频动作 .toolbar、搜索 .searchable,内容区仅 .glassEffect 卡片不铺不透明材质;视图宏安全(@State/@StateObject 禁用,ObservableObject 家族,CLT 回退可编译;main.swift 文件名不能承载 @main,入口文件为 AFMApp.swift)

**FM 延迟策略**:词典候选先秒出保证跟手,FM 重排/整句预测异步到达后原地刷新(不阻塞打字)。

## 里程碑

1. **M1 词库管线** — shallow clone rime-ice;Swift 工具把 cn_dicts 的 dict.yaml 编译成拼音倒排的 `dict.bin` 进 bundle
2. **M2 输入法骨架** — IMKServer + InputController;打包 .app(ad-hoc 签名)装到 `~/Library/Input Methods`,先能打出汉字
3. **M3 液态玻璃 UI** — NSGlassEffectView 候选窗,对齐参考图样式
4. **M4 FM 接入** — 进程内 FoundationModels(fm CLI 回退通道预留、尚未接线);候选重排 + 整句预测
5. **M5 收尾** — package/install/uninstall 脚本 + SwiftUI 安装器 GUI;debug 标志文件 + /tmp 日志体系;首次注销重登收录

## 构建 / 安装(macOS 27 基线,Xcode 构建)

```sh
scripts/package.sh   # 构建主路径: xcodebuild -scheme afm-ime-Package(Xcode 工具链,macOS 27 SDK)
                     #   + Metal/DropletLens.metal → default.metallib(xcrun metal -fcikernel 不需要,layerEffect 无需该标记)
                     # Xcode 缺失时自动回退 swift build -c release(CLT,SDK 同为 27;水滴无折射)
scripts/build_dict.sh   # 词库源变更后全量重编 Data/dict.bin(rime-ice+外部词库,~22s)
# 产物: build/AFM拼音.app = 输入法引擎 + 内嵌设置中心(Contents/PlugIns/AFMSettings.app,单一 App 条目)
# 安装: 把 bundle 拷到 ~/Library/Input Methods/AFM拼音.app(未安装态直接打开 bundle 会自动拉起设置中心),
#       或 GUI 里点「安装并启用」;日常更新 = 重新 package.sh + rm/cp 换盘 + killall + open(部署铁律)
```

- **平台基线 macOS 27**(Package.swift `platforms: [.macOS("27.0")]`,字符串版本——`.v27` 常量在 tools 6.2 manifest 尚不存在);`swiftLanguageModes: [.v5]` 保持既有并发语义;所有 pre-27 `#available` 分支已删(FoundationModels/玻璃/layerEffect/onGeometryChange 等,27 基线恒可用)
- Xcode 26+ 的 Metal 工具链是独立组件:`DEVELOPER_DIR=<Xcode> xcodebuild -downloadComponent metalToolchain`(838.9MB)
- Xcode 可直接打开 Package.swift 包构建调试(File → Open);命令行主路径是 xcodebuild,产物在 `.build/xcode/Build/Products/Release/`

## FM 延迟基准(2026-09-03 实测,本机)

| 场景 | CLI 子进程 | 进程内 FoundationModels |
|---|---|---|
| 进程/会话开销 | 暖场 ~50ms | session 创建 1ms |
| 冷启动首请求 | 首次 ~2s(模型加载) | 962ms |
| 候选重排(典型 IME 调用) | 暖场 **0.31s** | 暖场 **0.32-0.36s** |
| 整句预测(≤10字) | **0.33-0.44s** | 首 token 0.33s / 总 0.37s |
| 生成速度 | ~11字/s | ~11字/s |

- 关键发现:端侧模型有 prompt 缓存(instructions + 模板命中 cachedToken 239/270),复用 session 暖场后延迟稳定在 ~0.3s
- 进程内 FoundationModels 对 ad-hoc 签名二进制直接可用(availability: available,无需 entitlement)
- session 复用会携带 transcript 上下文(整句测试中受上文影响);**最终实现选择每次新建无状态 session**(创建仅 1ms,零 transcript 膨胀,语境改为每次 prompt 显式带光标前上文)
- **结论**:FM 做不了逐键级(<100ms)的跟手响应,词典引擎负责跟手;FM 异步增强(0.3s 到达)完全可用

## 词库数据(vendor/,已 clone/下载)

### rime-ice 主库(vendor/rime-ice/cn_dicts,sparse clone)

| 文件 | 词条数 | 拼音标注 |
|---|---|---|
| tencent.dict.yaml | 980,992 | ❌ 单列,编译期自动注音 |
| base.dict.yaml | 558,056 | ✅ `词\t拼音\t权重` |
| ext.dict.yaml | 339,210 | ✅ |
| 41448.dict.yaml | 46,055 | ✅ |
| 8105.dict.yaml | 8,828(单字字表+字频) | ✅ 多音字多行 |
| others.dict.yaml | 942 | — |

- 版本 2026-08(最新);格式 `词\t拼音\t权重`,`---` 后为正文,`#` 注释
- 注音规则:rime 惯例 `nve/lve` 表示 üe;自动注音时多音字取字频比 >5% 的读音(rime 同款策略)
- proto/bench_fm.swift:FM 进程内基准源码,可重复运行

### 外部词库(2026-09-05 接入,全走 scripts/build_dict.sh)

| 源 | vendor/ 文件 | 收录 | 格式 / 处理 |
|---|---|---|---|
| 萌娘百科(mw2fcitx 官方月更 release 20260812) | moegirl/moegirl.dict.yaml | 129,095 | 无声调 rime yaml(词\t拼音),权重缺省→100;moetype 是其下游整理版,未用 |
| 中文维基(fcitx5-pinyin-zhwiki 0.3.0 zhwiki-20260416) | zhwiki/zhwiki.dict.yaml | 1,673,005 | 无声调 rime yaml,167 万行 → 编译器流式逐行解析防内存爆炸 |
| Minecraft Wiki | fcitx5-pinyin-minecraft/mc-cn.raw | 11,014 | 官方脚本抓 zh.minecraft.wiki API 生成(venv: pypinyin+opencc);release 的 .dict 是 libime 二进制不可用 |
| 蔚蓝档案 | BlueArchive-PinyinDictionary/ALL IN ONE/rime.txt | 301 | 撇号拼音 `qing'hui'shi`+权重;各子文件编码不一(有 UTF-16),只取 UTF-8 的 ALL IN ONE 合并版 |
| THUOCL 清华开放中文词库 | THUOCL/data/THUOCL_*.txt(11 个) | 93,647 | 词频 TSV `词 \t 频次`,自动注音;权重=clamp(频次,1..100_000) |
| ali-words 黑话 | ali-words/src/words.ts | 668 | TS 源码正则提取引号内 CJK 词,自动注音,权重 100 |
| 梗合集(自维护) | Experiments/梗合集-关键词拆散.md | 3,300 | markdown 表第一列:顿号拆分、去两端 ⚡/emoji 装饰、仅收纯 CJK ≥2 字,自动注音,权重 100 |
| 空耳词库(自维护) | Experiments/空耳词库.txt | 15 | 手工标注拼音(词\tq'y\t权重),apostropheTxt 模式;拉丁混排词(如 saki酱)给全拼键位 sa'ki'jiang |
| 热词与符号(自维护) | Experiments/热词与符号词库.txt | 22 | 手工标注:热词短语(爪巴/你牛大了/nya…)+ 苹果标志(U+F8FF,ping'guo/lin'qin/dianji 三键)+ ☻丨⌘⌥⇧⌃⇪↩⌫⎋ |
| emoji(CLRD 中文注解) | vendor/emoji/emoji-zh.txt(scripts/build_emoji.py 生成) | ~6千 | unicode-org/cldr-json zh 注解(tts 名称+关键词)pypinyin 自动注音,权重 2000;JSON 落 vendor 缓存,离线可重编;"apple" 不可键入(切分器只收合法音节串),苹果标志用 pingguo/linqin |
| 化学式/希腊字母(自维护) | Experiments/化学式词库/*.txt | 1363 | 用户从微软拼音包转换,格式即 词\tq'y\t权重;元素符号键(ac/ag)靠缩写直查命中;注意键入 syllables 表会进切分器(ac 成为合法"音节") |

- **权重校准基准**:rime-ice base P50=480 / P90=15,680 / P99=20.3 万;外部词库一律压在 100 档(与 tencent 同级)或 clamp 10 万以内,保证不压常用词(dictbench 实测:taikula 中 泰裤辣 排在 太酷啦/太苦啦 之后 ✅)
- 全量重编 21-22s / 峰值内存 ~1.7GB;dict.bin 349.7 万条 / 145MB;热循环查询平均 0.14-0.61ms
- **mc 词库坑**:官方 fetch.py 的 `get_all_titles_in_variant` 对每个带汉字页面单独发一次 variant API 请求(3 万页=3 万请求,数小时)——用 `get_all_titles` 整表翻页(~60 请求),繁→简由 convert.py 里 opencc t2s 兜底;`opencc` 要装官方 C++ 绑定版,`opencc-python-reimplemented` 有 .json 后缀双拼 bug
- DictBench 固化了各源回归查询(kulipa/xiajiehejin/fumo/weilandangan/qinghuishi/zifuchuan/huashetianzu/funeng/zundujiadu/taikula/caijiuduolian/hongwen/malou),重编词库后跑一遍即验收

## 决策记录

- **每次功能改动必须 git 提交**(用户规矩,2026-09-05):按仓库既有风格 feat:/fix:/docs:/refactor:/chore: + 中文详述,相关改动分批提交,不让工作区积压多个功能
- ~~不装 Xcode(CLT 可编译全部所需);若撞到必须 Xcode 的坑,暂停向用户提出选项~~(**2026-09-06 修订**:水滴折射需要 Metal shader,运行时编译路线全断(见「工具链探明」),用户决定自行安装 Xcode 27 beta——Swift 主链路保持 SPM,仅 Metal 编译步骤用 DEVELOPER_DIR 指向 Xcode,package.sh 自动探测/优雅降级)
- rime-ice 词库下载已获用户同意(用户指定必须用 rime 词库)
- FM 不可用/无权限/被安全层拦截时静默返回 nil → 直接纯词典模式,不阻塞输入;fm CLI 子进程回退通道预留但当前未接线
- 进程内 FoundationModels 需 Apple Intelligence 已开启(本机 `fm available` 已确认)
- **按词输入、纯查表为主 + 单路径词格 DP 组句(2026-09-05 91e7e1b 起修订)**:CandidateEngine 主体仍是多路切分 + 前缀查表 + 权重合并;主切分路径纯全拼且词库无整句短语时,`composeSentence` 在音节序列上做词格 DP/Viterbi 用词典词覆盖全部音节出整句候选(跨词上下文纠偏仍交给 FM 用途②);不做多路径全词图
- ~~模糊音尚未实现~~(已过时):模糊拼音已于 2026-09-05 实现,见下「模糊拼音」条目;v→ü 仍是唯一未做项
- FM session 每次新建、不带 transcript;上文由 InputController 取光标前 ≤60 字随请求显式传入
- **外部词库接入(2026-09-05,用户指定 6 源 + 自维护梗合集)**:DictCompiler 新增 5 种输入模式(--rime 无声调 yaml / --apostrophe 撇号拼音 txt / --freq 词频 TSV / --wordlist 源码提取 / --md-keywords markdown 首列),全在 scripts/build_dict.sh 固化;纯拉丁词与含 XX 占位符词条不收(拼音不可键入);同 key 候选超 exactCap=32 时低权重词会被截断,长尾仍由 FM 整句兜底
- **模糊拼音(2026-09-05)**:选**查询期变体展开**而非 rime 式编译期 derive——不动 dict.bin(省 ~15% 体积),规则改起来不用重编词库。CandidateEngine.candidates() 为前 3 条切分路径生成模糊变体键一并查询:zh↔z ch↔c sh↔s + an↔ang en↔eng in↔ing(按后缀匹配,ian↔iang uan↔uang 自然覆盖);每键变体含原键封顶 8(笛卡尔积截断),模糊命中 ×0.5 保证精确拼音候选优先;模糊查询用小 extCap/scanBudget(48/2 万)控耗时,热循环实测零退化(0.15ms)。自动纠错(移位容错,与「李娜/去哪」类词有冲突需调)未做
- **简拼与混输(2026-09-05,用户实测驱动三轮迭代)**:① 编译期给每条记录派生**首字母缩写键**(rime abbrev 等价,只进 merged 不进 syllables 表防污染切分器),引擎对整串字母直查缩写键(awsl→阿伟死了/啊我死了,nh→女孩,n→你);② 切分器允许**非音节单字母作缩写音节出现在任意位置**(优先级:缩写少>尾部完整>音节数少),引擎把缩写字母展开成同首字母真音节查询(n+hao→ni/na/ne…+hao 混输,nhao→你好)——展开仅限前 2 条短路径(≤4 段且 ≤2 缩写);③ **渐进前缀兜底**:纯全拼路径完整键无精确命中时,取覆盖前几个音节的词(收集 4 级,nishiyizhimaoniang→你是X);**覆盖分档排序(2026-09-05 修 meibengzhu)**:候选带 coversInput 位——全键精确/延伸/模糊/缩写/组句=全覆盖档,渐进前缀词=部分档,排序先档后分(档内按分数,用户词频乘法只在档内生效)。纯乘法层级因子 0.1^层 不够:词典权重横跨 7 个数量级(ext 梗词 没绷住=100 vs 高频单字 没=756 万),没 756万×0.01=7.5万 曾把 没绷住 压到第 16 位;分档后全键词永远 #1、单字只在无全覆盖候选时(如只打一个音节)靠前;dict.bin 350万→698万条/249MB(简派生翻倍),热循环 0.20ms
- **分段转换 + 整句预编辑(2026-09-05,修 Electron 删词不可靠)**:渐进前缀词选中时**不真正上屏**——词进 committedBuffer、剩余拼音留 raw,整句(已转换段+剩余拼音)以 setMarkedText 保持下划线预编辑态;最终上屏(空格满键/回车/标点/失焦)才 insertText(缓冲+文本) 一次写入。退格撤销=纯内存回退缓冲与 raw(不动应用文本)——**不能走 IMK 替换删除**:Chromium 系对 insertText 的 replacementRange 支持残缺,删词静默失败。commitComposition/clearComposition 同步清 committedBuffer/undoStack
- **Shift 组词中行为(用户纠偏)**:轻点 Shift 时组词中上屏**拼音原文**(↩ 行为),不是第一候选——shiftTappedToggle 必须直接 flush(raw),不能走 commitComposition(它上屏 candidates.first,等于空格行为)
- **中英模式与全角标点(2026-09-05,踩坑链完整版)**:① IMK **默认只投递 keyDown**,flagsChanged 必须覆写 `recognizedEvents(_:)` 返回 `[.keyDown, .flagsChanged]` 才会送达(AppKit 应用可达,fcitx5-macos 同款);② **Electron/Chromium 系应用(VSCode/Chrome/ZCode)根本不向输入法转发修饰键事件**,IMK 路线在这些应用里是死路(recognizedEvents 声明也无效,实测 0 事件);③ **方向键 keyDown 自带 function|numericPad 修饰位(0xA00000)**,mods 判定前必须剔除,否则 ←/→/↑/↓ 全被当"带修饰键"放行(dac0262 的 ↑↓ 修复因此从未真正生效);④ Shift 中英切换最终方案 = **ShiftModeMonitor(CGMEventTap .cgSessionEventTap + listen-only)全局监听**,IME 进程创建 tap 实测无需 TCC 授权(输入法属受信输入子系统);若创建失败在 activateServer 重试。切模式时组词先上屏拼音原文;模式写 UserDefaults(key AFMEnglishMode)跨重启。英文模式 handle 全直通;中文模式标点映射全角(，。；：？！（）【】「」《》、·～,`$`→￥、`_`→——、`^`→……),引号 `'`→''、`"`→"" 成对交替,`-`/`=`/空格/数字保持半角;**部分客户端 shift+标点的 charactersIgnoringModifiers 不带上档效果**(shift+1 给 '1'),handle 里用 shiftedSymbols 表还原(shift+数字因此不触发选词);候选条尾部 ▾/▴ 鼠标点击展开/收起网格(onToggleExpand 回调;◂/▸ 翻页已废弃,见「候选窗交互定稿」)。注意:合成按键(CUAGEventPostToPid)不经过系统事件流,session tap 看不到,只能真机键盘验证
- **用户词频(2026-09-05)**:IMECore/UserFreq,UserDefaults 字典 [word: count](key AFMUserFreq)持久化,容量 5000 按次数淘汰,保存防抖 2s;**按词记录不按键**(nhao 选的 你好 对 nihao 同样生效);加成 = min(1 + 0.5·log10(1+count), 3.0) 乘在最终排序前(10 次 ×1.5 / 100 次 ×2 / 1000 次 ×2.5,封顶防霸榜);>50 字整句不计数;词典权重本身不动,空表零开销(热循环 0.22ms 不变)
- **候选窗交互定稿(2026-09-06 kb13 定稿,kb14-25 五轮返工踩坑链见下条)**:① **候选条恒显前 8 个(无滑动窗口)**:←→ 在 0-7 内移动;→ 越过第 8 个**直接展开网格**(横向滑动窗口已废弃);数字键 1-8 = 全局位次;=/- 翻页(条内 ±8,越界自动展/收网格);② **↓ 展开 8 列滚动网格**(SwiftUI Grid 列对齐 + ScrollView,可见 4 行):滚轮/滚动条直接滚,↑↓←→ 移动选中,滚动**边缘跟随**(选中越出可视行才滚一行:↓ 贴底只出新行/↑ 贴顶只出旧行,滚轮自由滚动由公式自校正);移回首行(前 8 个)或顶行按 ↑ 自动收起回条;**展开态回车=空格=上屏选中,未展开回车仍上屏拼音原文**;网格编号仅水滴所在行显示行内 1-8,数字键按该行选词;候选查询上限 100(maxCandidates);③ **⌃F 内联翻译**:组词中把当前高亮候选的译文单行显示在候选框(spinner→译文),空格上屏译文,⌃F/Esc/←→/继续打字退出;**独立翻译框组件(TranslatePanelController)暂不启用**——代码保留不接线,⌃F 非组词时放行原生;④ **CLT 坑:本 SDK 的 @State 已是宏,CLT 环境找不到 SwiftUIMacros 插件,编译直接失败**——候选窗视图禁用 @State/@StateObject 等宏包装器,窗口状态全放 InputController 以 props 传入(@FocusState/@Published/@ObservedObject 可用);⑤ 窗口状态在 InputController(gridExpanded/selectedIndex),水滴几何+网格滚动位置在 CandidateDropletModel 单例(@Published 非宏,视图直写局部刷新);⑥ **选中态 = 可拖拽的透明液态玻璃水滴**(2026-09-06 kb7 起多轮迭代,学自 Kyant0/AndroidLiquidGlass LiquidBottomTabs,vendor/AndroidLiquidGlass 有源码):水滴透明质感 = **双层内容 trick**——幽灵行快照(强调色:数字 cyan/词加粗,与正常行逐像素同布局)经 **Metal 折射 lens** 处理后叠在玻璃胶囊上,水滴划过哪里哪里的内容被放大折射;折射数学 1:1 移植其 AGSL:胶囊 `sdRoundedRect` SDF + `circleMap(1−√(1−x²))` 边缘折射(SDF 梯度方向,amount 传负=向内拉)+ 七采样色散,参数 `lens(10px*press, −14px*press)`(静止不折射)。**shader 交付路径(kb9 定稿)**:`Metal/DropletLens.metal`(SwiftUI layerEffect,`#include <SwiftUI/SwiftUI_Metal.h>`,签名 `afmLensMask(position, SwiftUI::Layer, rect, refr, layerSize)`,**SwiftUI::Layer 无 extent()**,图层尺寸自己传参)→ package.sh 用 `DEVELOPER_DIR=<Xcode> xcrun -sdk macosx metal -c + metallib` 编成 `default.metallib` 进 bundle → 运行时 `ShaderLibrary.afmLensMask(...)` + `.layerEffect(shader, maxSampleOffset)`;无 Xcode 构建时 metallib 缺失 → 水滴退化为纯玻璃(优雅降级)。此前两条死路(实测):老 CIKL `CIKernel(source:)` 可用但 deprecated;现代 MSL CI kernel 需要 `-fcikernel` + metallib Data,运行时编译器给不了且 MTLLibrary 无序列化 API。**拖拽交互(kb11 修)**:DragGesture(minimumDistance 4,不与点选冲突),按住即抓起(水滴跳到按压处候选,fraction(at:) 映射),连续 dragFraction 按相邻候选实际 frame 线性插值(**候选宽度不一,不能用等宽公式**,frames 由 onGeometryChange 回写);拖拽钳制在条内前 8 个;松手 onDrop 吸附上屏(轻点=位移 0 的拖拽)。**拖拽累加映射大坑(kb11 修)**:手势回调的 dx = location−startLocation 是**累计位移**,若当增量逐事件加到 base,fraction 按事件数二次方暴涨(60 事件/s 下几百 ms 钳死窗口尾)=「按住还没出第一个词水滴飞到最后一个候选」;修法 = 每事件 `drag(toX: v.location.x)` 用同一映射重定位,**永不累加**。**液态动画(kb12)**:按压鼓起/松开回弹走 `Animation.timingCurve(0.3,0.2,0.2,1.4)`(=cubic-bezier 过冲,用户指定),挂在 press 变化上——抓取瞬间的位置跳变与鼓起同事务一并游动;条态选中跳格同款游动;网格态用无过冲短滑。**水滴胀出条外**:面板 = 容器(透明,边距 10×12) ├ NSGlassEffectView(玻璃条) ├ 水滴覆盖宿主(PassthroughHostingView hitTest 全 nil);**坐标基准坑**:coordinateSpace("candBar") 挂在带 padding 的条根上(挂行上差出 padding);网格态水滴作选中指示——**直取 frames[selectedIndex]**,无折射层,幽灵字用网格样式(gridCell: true)重绘
- **网格滚动/水滴踩坑链(2026-09-06 kb14→kb25 五轮实测,每轮都靠 debug 日志钉死)**:① **interpolatedFrame 的 minX 排序是条态单行逻辑**——单行里 x 序=下标序;二维网格按 minX 排序后 `keys.last` 落在**末列格**(99 候选时=下标 95,倒数第二行最后一列),`f ≥ lastKey` 的选中全部吸到末列 =「到不了最后一行/锁死倒数第二行末列/水滴叠在别的候选上撞在一起」;网格态必须**直取 frames[selectedIndex]**,拖拽插值仅条态用;② **ScrollPosition 必须 @Published**——普通属性变更不触发 objectWillChange,scrollTo 指令躺平,直到下次无关重渲染才被捎带执行 =「跟随永远慢一拍、再按一下动两排」;③ **ScrollViewReader.scrollTo 对 Grid 内容是空操作**(onChange 有触发、日志正常、就是不滚;id 挂 GridRow 上解析不到 frame)——改 `ScrollPosition.scrollTo(point:)` 按行距偏移驱动(行距=格高 28 钉死+间距 1=29,视口高=可见行×行距−1,三者闭合);④ **CJK 行高偏大,格高必须钉死**(min=max=28):idealHeight 不钉死实际行距≈29>估算,滚到底够不着末行+视口底部裁半行形似候选重叠;`网格实测行距` 日志现场校验;⑤ **FrameReporter 死循环**:onGeometryChange 在重渲染时重发相同 frame → 写 @Published → 重渲染 → 再上报(钳回日志同值每秒几十次暴露);frame 写入必须去重(值相同直接 return);⑥ 网格态水滴位置动画用**无过冲短滑**(easeOut 0.18)——过冲贝塞尔会冲出滚动视口;⑦ 跟随指令丢失的自愈兜底:发指令后 0.35s 内(gridFollowUntil)recompute 发现选中格仍在视口外 → 补发无动画滚动
- **FM 预测放第 2 位(2026-09-06)**:重排/整句 ✦ 候选插到 index 1(无词典候选时才为第 1),不顶掉词典首选——FM 到达瞬间若换掉 #1,按惯性空格会把「突然换掉的词」打出去;用户按数字 2 或 → 主动选 ✦
- **用户词库(2026-09-06 kb26,修六连败:mebengz 没绷住/woc 我草/zhedm 真的吗/buyaobuy 不要不要/gongn 功能/zhendchoux 真的抽象)**:旧词频乘法加成封顶 ×3 压不过词典权重(不要不一精确 ×1.0 稳赢打折的不要不要),故加**用户词库层**——上屏时记录词条拼音键(UserDefaults AFMUserPinyin,word→key),后续同键输入以**最高优先档**(排序 tier: 用户 2 > 全键 1 > 渐进 0)直出,userScore = 20k+15k·log10(1+count) 随使用次数单调增长(「打得越多权重越高」,次数只决定用户词内部次序);三层匹配 = 整串前缀二分 + 简拼索引 + **逐音节宽松兜底**(查询每个音节只需为对应词条音节的前缀——中间音节没打全 mebengz 的 me⊂mei、缩写音节 zhedm 的 d⊂de/m⊂ma 都能命中;候选池是用户自己的词,放宽无副作用;仅快路径无命中时扫描);模糊变体键不放行(精确输入才召回);upsert 规则:用户档同文不被词典候选覆盖;FM 整句无真实拼音,提交时用原始键入当键(下次原样输入可复现);佐证脚本 proto/userdict_check.swift(swift build --target IMECore + swiftc 链接 IMECore.o,六 case 前后对照)。kb27 增补:①**学习键校验**——逐音节 ≥2 字母(a/o/e 除外)才收,挡词典简拼派生键(提交「来」经 "l" 简拼候选 pinyin 字段是 "l")与半截尾音节(「好下=hao x」),init 迁移清洗存量脏键;②**单字不吃词频乘数**(限 ≥2 字词)——了/的/是这类高频虚词不被提交次数更多的来/一顶掉;③**词组学习**——分段组句时 committedKeys 轨迹在最终上屏整词组入词库(真的+抽象 → 真的抽象 = zhen de chou xiang),修词典外短语冷启动(zhendchoux 从此逐音节宽松直达),退格/清组词平行回退
- **组词中 Shift+字母 = 大写英文字尾(2026-09-08 kb35)**:字母入缓冲时 shift 按住 → 大写进 raw;**首个大写字母起整段冻结为字面英文**——pinyinPart(首个大写前的拼音段)/literalTail(大写起含)/firstChoiceText(首选+字尾,无候选时 raw 原文)三计算属性;词典查询/FM(重排、整句判定与入参)/用户词学习 fallback 键全走 pinyinPart,**字尾不进切分器**(大写非合法音节,整串查询会拖累渐进兜底);提交=词+字尾一次上屏(commitCandidate 开头字尾分支直接 flush 并跳过渐进分段;标点/失焦 commitComposition/面板插入统一 firstChoiceText;⌃F 译文空格=译文+字尾);纯字尾(如 GDP)无候选,空格/回车上屏原文;**ShiftTap 无需改动**——.keyDown 带 shift 置 shiftUsed,按住打大写不会误触中英轻点切换;CapsLock 行为不变(chars 自带大写,lowercased 后仍按小写入缓冲)
- **系统设置嵌入输入法设置——死路盖章(2026-09-06,实现→真机证伪→回滚,勿再走)**:键盘设置 appex(KeyboardSettings,`com.apple.Keyboard-Settings.extension`,扩展点 com.apple.Settings.extension.ui)对第三方输入法详情页**没有任何可编程表面**——隐私警示文案下就是空白。静态拆包:选项区机器(instantiatePrefPaneObject/loadOptionsForInputSourceID:/InputSourceOptionsView,链接公开 PreferencePanes.framework)只服务苹果自家 IME(二进制特判 com.apple.inputmethod.SCIM/TCIM/TYIM),SCIM 的面板在其引擎 appex Resources、苹果第三方模板 PluginIM 在 app 顶层 Resources,**均为苹果签名**;IMK 文档化入口只有 IMKStateSetting.showPreferences(输入法菜单项→独立窗口)。动态实证(`log stream --level debug` 抓用户点击三个条目的现场):KeyboardSettings 对第三方 bundle **只做 CoreUI 图标资源查询**(NSBundle "not yet loaded"),从不查找/加载 Preferences.prefPane——app Resources 与 PlugIns 双约定位置零提及、无 dlopen、无 AMFI 拒载、无崩溃,即"根本不看"而非"签名被拦";连苹果自己的老 Keyboard.prefPane 走新 Plugin Installer 桥都 `missing identifier or name` 失败(残骸)。hook 三路全封:①进程注入(平台二进制+硬化运行时+library validation+SIP 密封,DYLD 变量被剥,且无挂点);②ExtensionKit Settings 扩展点(pluginkit 注册表无第三方通道,且渲染在侧栏不在输入源详情页);③prefPane 桥(见上,残骸)。曾完整实现过一版(UserPrefs 四门控 AFMFuzzyPinyin/AFMFullWidthPunct/AFMFMEnhance/AFMUserFreqEnabled + AFMPrefsPane + package.sh `swiftc -emit-library -Xlinker -bundle` 编 pane + proto/prefs_probe 离线加载验证全过,defaults 写删实测门控生效)因无表面可渲染整体回滚(git 历史 96e01c0/6051a0b)。**附带收获**:①系统框架二进制在 dyld 共享缓存里,strings 全空,别浪费时间;②排查系统设置必须 `/usr/bin/log stream --level debug` 抓现场(裸 `log` 是 zsh 内建,报 "too many arguments");③键入 UserDefaults 的门控读必须查询入口快照一次(逐候选读实测热循环 0.20→0.37ms);④dictbench 裸 CLI 的 UserDefaults.standard 是自己进程域,测门控要 `defaults write dictbench ...`
- **GUI 控制中心 AFM拼音.app(2026-09-06)**:AFMInstaller 升级为完整控制中心(安装+词库+用户词+设置),target afm-app(Sources/AFMApp)。要点:①**设置写入用 UserDefaults(suiteName: IME 域)**,与 IME 进程的 .standard 同域,cfprefsd 跨进程失效保证即时生效——键名与 IMECore/UserPrefs.swift 逐字一致;②**候选字号只动条态**——网格态行距 28/29 是滚动闭合的几何契约,字号牵一发动全身;③(同日合并后作废)曾把引擎产物改名 build/AFMInput.app、GUI 占用 build/AFM拼音.app 内嵌引擎——后按用户要求合并为单一 bundle,见架构段「设置中心」条;④App 内「更新输入法」严格复刻部署铁律(rm+cp→killall→pgrep 确认死透→open);⑤View 里禁 @State/@StateObject(宏),确认框状态放 @Published 进 model
- **部署铁律(2026-09-06)**:**日常重装禁止跑 scripts/install.sh**——它的 enable 流程先 disableAll 再 enable,而 TISEnableInputSource 对本包返回 noErr 但**活视图静默不收**,等效每次部署都把输入源摘掉(「改几次代码输入法就消失」的根因);日常部署只做 cp 换盘 + killall + open(首次收录后注册永久有效)。**cp 换盘必须先 rm -rf 旧 bundle 再 cp**(裸 `cp -R` 会把新旧文件混进 bundle);**每次部署换新二进制后 TIS 会多记一个重复实例**(同 id 多条、enabled 列表不动、功能正常,系统设置输入法列表可见),注销重登收敛。TIS 实时视图坏掉的症状:`TISSelectInputSource` 返回 -50(对未启用源 select 本身就是 paramErr,API 没坏);恢复法:打开 系统设置→键盘→输入法→编辑 面板触发同步,defaults 里的启用条目会被拉回活视图。注意 defaults 的 AppleEnabledInputSources 有条目 ≠ 活视图已启用(后者要登录扫描才重建);反复 register/enable 会产生灰色重复实例,注销重登收敛
- **用户规矩(2026-09-06 新增)**:① 真机 UI 操作(拖水滴、点系统设置、切输入源等)**直接叫用户执行**,不要自己驱动 UI;② 每次行为改动必须带 debug 门控日志(写 /tmp/afm-ime.log,用户会看日志配合复现)
- **伴随面板(2026-09-05,⌃V 剪贴板 / ⌃F 翻译;同日三修——免激活/并存/直录)**:CompanionPanels.swift 单文件;① **定位**=候选条 frame(候选窗 onFrameChange 回调回写 latestCandidateFrame)下方 8px,剪贴板贴候选条**左缘**、翻译贴**右缘**(并存重叠时翻译挪剪贴板右侧,再放不下→剪贴板下方),下方放不下→上方,再不行钳回屏内;无候选条→光标所在屏幕右上角(visibleFrame 排除菜单栏/Dock);**两面板可并存,不互斥**;② **焦点模型是关键坑(三修核心)**:剪贴板面板**免激活**——NonKeyPanel(canBecomeKey=false) 纯展示+点击,进程保持 .prohibited 不抢焦点,客户端组词/候选条/打字原样存活。此前两面板都临时切 `.accessory`+activate,客户端失焦触发 deactivateServer→commitComposition 把首选强制上屏(=「⌃V/⌃F 中断预测」根因,日志实锤 ⌃F 开面板瞬间 raw='awsl' 被上屏成'安慰失恋');免激活面板没有 resignKey 时机,点外部收起改用全局鼠标监听(NSEvent addGlobalMonitorForEvents,走已授权的输入监控 TCC,只观察不消费);键盘选词(1-9/↑↓/⏎/Esc)路由进 InputController.handle(剪贴板可见且非组词中),组词中按键归组词、面板用点击;③ **翻译面板必须抢键盘**(要打字):打开前 suspendCompositionForPanel 挂起组词——状态留内存不上屏,deactivateServer 据此跳过提交,关闭还焦点后 activateServer 原样恢复预编辑态+候选条(挂起时掐 fmGeneration 防在途 FM 回写重开候选窗);④ **面板激活后自有 app 的事件仍回流 IMK handle(实测)**——handle 顶部 anyKeyWindow 全放行翻译框才能收到原始按键,此前字母被拼音引擎吞掉(raw='aws'、候选窗盖在翻译框上)=「翻译框无法输入」根因;放行必须置于 lastActive 赋值**之前**,防自有 controller 劫持"插入到光标"的目标;翻译框字母直录,中文 ⌘V 粘贴;⑤ **插入时序**:客户端持焦点(剪贴板路径)立即 flush(首选)+insertText;翻译面板持键则先 close 还焦点 → 0.15s 后插入;组词中先按空格语义上屏首选再插入;⑥ 剪贴板 ClipboardMonitor 常驻轮询 NSPasteboard changeCount(1s),只收文本(2 万字截断/50 条/去重置顶),落盘 Application Support/AFM拼音/clipboard-history.json;⑦ 翻译用 FMReranker.translate(方向自动:含中文→英,否则→中);⑧ 快捷键拦截规则:⌃V/⌃F/⌃S 中英模式都拦(kb34 定稿:⌃F=组词内联翻译、⌃S=设置中心,均在 IMK handle 顶部 englishMode 放行之前判定;kb35 起键码可自定义,设置中心快捷键卡写 AFMHotkey* 键码、缺省 V/F/S),option/command/shift 组合不拦,自己的面板持键时 handle 全放行;⌘V 原生粘贴不受影响;已知取舍:终端里 ⌃V(quoted-insert)/⌃F(forward-char)/⌃S(XOFF 流控)被输入法接管

## 安装要点(M2 实测踩坑)

- **(早期结论,已被文末「M2 收官结论」推翻,保留作排坑记录)** 只把 bundle 丢进用户级 ~/Library/Input Methods 而不做递交注册时,TIS 日常扫描不枚举它(重启/杀缓存均无效,TISCreateInputSourceList 331 个源中无第三方);**但这不意味着必须装系统级**——先由安装包自身二进制递交 TISRegisterInputSource、再注销重登,用户级目录即可收录(本机 ad-hoc 包已实测长期可用)。系统级 `/Library/Input Methods/` 仍保留为 `scripts/install.sh --system` 选项(需一次 sudo),squirrel/fcitx5-macos 默认走该路径
- Info.plist **必须有 ComponentInputModeDict**(tsInputModeListKey 每个输入模式含 TISInputSourceID/TISIntendedLanguage/tsInputModeCharacterRepertoireKey/tsInputModeScriptKey 等)——这是 TIS 枚举输入法的依据,缺了系统完全不认识(参考 vendor/squirrel/resources/Info.plist)
- LSUIElement=true + LSBackgroundOnly=false(squirrel 同款);`open` 对已运行进程是空操作,重装后要先 killall 再 open
- Swift 侧 IMK 注意:handleEvent→handle、updateCandidates 需经 NSSelectorFromString、server 是方法调用 server()
- proto/tis_probe.swift 是 TIS 枚举查询样例(注意其内过滤的是早期 id com.afm.AFMInput;现行 build/tis3_probe 过滤 moe.bemly,其源码待补回 proto/)

## TIS 注册完整结论(M2 踩坑 2026-09-04,综合 VietTelex macOS 26.5 实测 + 本机 macOS 27 实验)

**macOS 26/27 对第三方输入法注册是"静默拒绝"模式**——所有条件不满足时 `TISRegisterInputSource` 仍返回 noErr,但源永不枚举、无任何日志。已验证/已确认的事实:

1. **Bundle id 必须含 `inputmethod` 段且段后必须有名字**(早期实验 id 如 com.afm.inputmethod.afmpinyin;当前定稿 moe.bemly.inputmethod.AfmIME);mode id = bundle id + 后缀(当前为 .afmpinyin.hans)。不含该段、或以该段结尾都不会被收录。
2. **坏 id 会被毒化**:以无效状态装过一次的 id 永久失效(即使修好其他一切),必须换新 id。
3. **controller 类名**:`@objc(InputController)` 显式命名与 plist 不一致 → IMK 实例化失败 → 永不注册。推荐:不写显式 @objc,plist 写 `模块名.类名`(如 `afm_input.InputController`),otool -ov 应显示 `_TtC9afm_input14InputController`。
4. **TISRegisterInputSource 只产生瞬态注册**:仅在(部分)进程视图中短暂可见,cfprefsd 同步后即被冲掉。用 `--setup`(单进程 register+enable+select 连做)可在窗口期内完成三步,但 select 对 IME 返回 -50,且状态随时丢失。**持久注册只有一条路:登录扫描(logout/login)**;注意收官流程里的"递交 register"价值不在瞬态可见,而在给登录扫描留下待复核记录(见文末流程,与本条不矛盾)。
5. **公证(notarization)是「只放目录、纯靠登录扫描自动收录」的门槛**(VietTelex 对照实验:不手动递交时,公证过的输入法首次注销登录即注册,未公证的从不注册)。**但 ad-hoc 并非死路**:先用自身二进制递交 TISRegisterInputSource(记录进 TIS 缓存)再注销重登,登录扫描复核的是已递交记录——本机 ad-hoc 用户级包据此收录并长期可用(2026-09-04 实测)。对外分发给其他机器(无手动递交环节)仍必须 Developer ID 签名 + 公证。
6. **InputMethodConnectionName 必须是 `<bundle-id>_Connection`**,否则沙箱客户端(WhatsApp/MAS 应用)连不上 NSConnection。
7. 反模式:killall cfprefsd(冲掉瞬态注册+丢偏好写入)、defaults write com.apple.HIToolbox(绕不过 TIS 校验)、killall TextInputMenuAgent(无用)。
8. 本机 `security find-identity` = 0 个证书;公证需 Apple Developer Program(付费)。

**结论(两条路径)**:① **本机开发/自用**——ad-hoc 签名即可:装 ~/Library/Input Methods → 自身二进制递交 register → defaults 写 base+mode 启用条目 → logout/login 一次 → 永久生效(已验证);② **对外分发**——必须 Apple Developer 账号 → Developer ID 签名 + notarytool 公证 + stapler staple,否则别人机器上没有手动递交环节、登录扫描不会收录。

## 代码签名与 TCC(2026-09-05,Shift tap 依赖)

- **ad-hoc 签名的 designated requirement = cdhash,每次构建都变** → TCC「输入监控」授权随构建失效 → CGEventTap **静默失明**(tapCreate 照样返回成功,但零事件投递、无任何报错——最阴的坑,探针+HID 级合成事件注入可确诊)
- 修法:**自签证书 `AFM-IME-Dev`**(CN=AFM-IME-Dev,keyUsage=digitalSignature + extendedKeyUsage=codeSigning,openssl 生成,证书/私钥 PEM 分开导入 login keychain,`-T /usr/bin/codesign` 白名单)→ DR 变为 `identifier + certificate leaf`,**授权一次跨构建有效**
- 坑①: macOS `security` 不认 OpenSSL 3 默认 PKCS12 加密(MAC verification failed)→ 改 PEM 分开导入;坑②: CN 含中文在 keychain 里乱码导致 codesign 匹配失败(unknown exception)→ 证书名用纯 ASCII;坑③: codesign 首次用钥私钥会弹钥匙串授权框,需输开机密码点允许
- package.sh 自动检测证书,缺失回退 ad-hoc;证书重建(换机/丢 keychain)会变 DR,需重新授权输入监控
- 授权入口: 系统设置 → 隐私与安全性 → 输入监控 → 添加 AFM拼音
- **陈旧 TCC 记录陷阱(2026-09-05 实测,最后一块拼图)**:签名变更后,输入监控面板里旧授权条目**依然显示"已开启"但内部 csreq 指向死掉的旧 cdhash**,校验永远静默失败;在面板里开关勾选**不会刷新 csreq**。唯一解法:`tccutil reset ListenEvent moe.bemly.inputmethod.AfmIME` 清掉记录 → 重启输入法(tap 必须在授权之后创建,授权前创建的 tap 永远失明)→ 系统重新弹「想要监听键盘输入」框 → 点允许 → csreq 以当前证书签名记录。之后跨构建永久有效(真机验证 2026-09-05)
- 排障口诀(Shift tap 失效时按序查): ①日志有无 `ShiftTap: shift 按下`(区分"事件没到"还是"判定没切") ②`codesign -dr` 看 DR 是否证书绑定 ③输入监控面板有条目≠授权有效,csreq 才是真身 ④tccutil reset + 重启 + 重新弹框授权

## 启用状态管理(M2 实测补充)

- 添加选择器里的**灰色条目 = 已启用所以不可再选**(简体拼音也显示灰色),不是异常;重复灰条来自重复 register/enable——因此 IMEInstaller.register 先查重、enable 先 disableAll 收敛,最终启用列表固定为 base+mode 两条(见下节)
- `TISEnableInputSource` 对 ad-hoc 包返回 noErr 但不写 `AppleEnabledInputSources`(静默无效);**可靠做法是 defaults 直写启用列表**(export→python 过滤→import,VietTelex 修复法),写完 TIS 已启用视图立即可见,无需注销
- 干净状态下 `TISSelectInputSource` 成功(此前 -50 是脏状态所致);选中状态写在 `AppleSelectedInputSources`
- scripts/uninstall.sh:进程+bundle+defaults 全清;TIS 注册表条目注销重登后由登录扫描清除

## 显示名与启用结构(M2.5 补充)

- 输入源显示名机制:TIS 在 bundle 的 `InfoPlist.strings`(或 xcstrings)里**用「输入源 ID」作 key** 查显示名(squirrel 的 InfoPlist.xcstrings 有 `im.rime.inputmethod.Squirrel.Hans` 等键);缺失时 mode 源的 localizedName 退化为裸 id
- 启用列表(`AppleEnabledInputSources`)标准结构 = **base+mode 双条目**(SCIM 同款):`InputSourceKind="Keyboard Input Method"`(base,编辑器渲染标题)+ `InputSourceKind="Input Mode"`(mode,可切换源);只写 mode → 设置里只剩小字描述无标题
- 输入菜单对已删除 bundle 有陈旧缓存,底层状态修正后 `killall TextInputMenuAgent` 可刷新(注册问题除外,那个要重登)

## M2 收官结论(2026-09-04,打字链路实测可用)

- **重装/重启输入法标准顺序**(2026-09-05 踩坑:launchd 会在 killall 后、open 前复活进程,复活窗口拿到的可能是旧 bundle,且日志截断会与存活进程的句柄错位):**先换盘(cp)→ killall → `pgrep -x AFMInput` 确认死透(残留就 pkill -9)→ open**;启动后 grep 日志必须看到 `输入法启动 build=` 与 `ShiftTap: 监听已启动` 两行才算部署完成;调试日志文件清理用 mv 移走而不是 `: >` 截断
- **包名定稿:`moe.bemly.inputmethod.AfmIME`**(mode:`moe.bemly.inputmethod.AfmIME.afmpinyin.hans`;代码常量见 IMECore/Installer.swift,Info.plist 与 InfoPlist.strings 必须与之逐字一致)。规矩:id 必须含 `inputmethod` 段**且段后必须有名字**——以 `inputmethod` 结尾(如 moe.bemly.inputmethod)时添加选择器根本不显示它
- **全新 id 首次安装流程**(缺一不可):
  1. bundle 装入 `~/Library/Input Methods/` + defaults 写 base+mode 启用条目
  2. 用安装包自身二进制递交 `TISRegisterInputSource`(记录持久化到 TIS 缓存)
  3. **注销重登**(登录扫描复核记录 → 注册 → 按启用条目自动启用)
  4. 重登后跑启用+选中(安装器「重登后:完成启用」按钮或 post-login-check.sh)
- **递交注册后、重登前,绝对不要 kill 任何输入法组件**(TextInputMenuAgent/imklaunchagent/cfprefsd 都会冲掉待处理的注册记录——实测踩坑)
- 首次收录后永久有效,之后装卸无需注销
- 安装器 GUI(Sources/AFMInstaller):安装并启用 → 一键注销 → (重登)完成启用 → 打开输入源设置深链 `?InputSources` / 卸载
