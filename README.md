# AFM拼音 (afm-ime)

macOS 液态玻璃(Liquid Glass)风格中文拼音输入法,端侧 Apple Foundation Models 大模型增强候选预测。**纯 Swift、无第三方依赖;macOS 27+,Xcode 构建(水滴折射需要其 Metal 工具链,无 Xcode 亦可构建、仅水滴无折射)**。

![平台](https://img.shields.io/badge/macOS-27%20(Apple%20Intelligence)-blue) ![构建](https://img.shields.io/badge/Swift-6.4%20·%20Xcode-orange)

## 功能

- **词典引擎**:多源词库 **698.6 万条**(含简拼派生键,原始词条 ~350 万),编译为二进制 `dict.bin`,mmap 零拷贝加载(<1ms),热循环查询 ~0.2ms
  - rime-ice 雾凇拼音(tencent 98w + base 55w + ext 34w + 8105 单字)
  - 萌娘百科(mw2fcitx 月更)12.9w / 中文维基 167w / Minecraft Wiki 1.1w / 蔚蓝档案 / THUOCL 9.4w / ali-words 黑话 / 自维护梗合集 3300 词(无拼音源编译期自动注音)/ CLDR emoji / 化学式·希腊字母
- **用户词频自适应**:选用过的词按次数加权(封顶 ×3),越打越顺,跨重启记忆
- **伴随面板**:
  - *剪贴板历史* `⌃V`:复制过的文本自动收录(50 条/跨重启),点击或数字键插回光标
  - *翻译* `⌃F`:端侧 FM 中↔英互译(方向自动),结果可复制/插入到光标
  - 均为液态玻璃:候选条在时浮其下方(没空间在上方),不在时显示在光标所在屏幕右上角
- **液态玻璃候选窗**:NSPanel + NSGlassEffectView(macOS 26+ 真·Liquid Glass),跟随光标,暗色/亮色自适应
- **FM 增强(端侧,隐私安全)**:
  - *候选重排*:打字停顿 ~0.4s 后,端侧模型根据上文把最合适的候选置顶(标 Apple 标志)
  - *整句预测*:长拼音词典覆盖不住时,光标处显示"整句预测中"占位,模型输出整句后原位替换
- **拼音切分与模糊音**:音节树 + 最多 12 路切分枚举,尾部不完整音节实时匹配;模糊拼音 zh/z、ch/c、sh/s、an/ang、en/eng、in/ing(含 ian↔iang、uan↔uang)双向模糊,精确拼音候选永远优先;简拼(nh→女孩)与全拼混输(n+hao→你好);词格 DP 整句组词(长句直出整句候选)

## 构建 / 安装

```sh
scripts/build_dict.sh       # 词库源变更后全量重编 Data/dict.bin(rime-ice+外部词库+梗合集)
scripts/package.sh          # xcodebuild(Xcode 工具链,macOS 27 SDK)+ Metal shader → default.metallib
                            # 无 Xcode 时自动回退 swift build(CLT),水滴退化为无折射
open build/AFM拼音安装器.app # GUI:一键 安装→启用→选中
```

首次安装需要**注销并重新登录一次**(TIS 登录扫描收录,详见 AGENTS.md);之后装卸永久生效。

命令行方式:`scripts/install.sh`(用户级,免 sudo)/ `scripts/install.sh --system`(系统级,需 sudo)。

## 使用

- `Ctrl+Space` 或菜单栏切换到 AFM拼音;**轻点 `Shift` 中英切换**(系统级监听、全部应用生效,跨重启记忆;英文模式无候选框、标点半角直通)
- 中文模式:打拼音 → 数字 `1-8` 选词 / `空格` 上屏高亮候选 / `回车` 上屏拼音原文;选中候选为透明液态玻璃水滴,**按住可左右拖动,松手吸附最近候选直接上屏**
- `←→` 移动高亮(队列式滑动窗口,到边缘自动滑入下一个),`↓` 展开候选网格(8 列 × 上下滚动,`↑`/移回首行收起),`=`/`-` 翻页,候选条 `▾`/`▴` 点击展开收起,`Esc` 取消组词
- `⌃F` 内联翻译:把当前高亮候选的译文直接显示在候选框,`空格` 上屏译文(独立翻译框暂未启用)
- `⌃V` 剪贴板历史(免激活,不打断组词,点击/数字键插入光标处),与候选窗可同时使用;面板浮在候选条下方或屏幕右上角
- `⌃;` 打开系统「显示表情与符号」;emoji 直接拼音打(如 `xiaolian`→😀、`weixiao`,词库来自 CLDR 中文注解)
- 中文标点自动全角：，。；：？！（）【】「」《》、·～,以及 `Shift+-`→——、`Shift+6`→……、`Shift+4`→￥;引号 `'`→‘’、`Shift+'`→“”,均成对交替(`-`/`=`/空格/数字保持半角)
- FM 整句:长拼音停顿后出现 ✦ 整句候选,空格直接上屏

## Debug

```sh
scripts/debug.sh        # 重启输入法,实时跟踪 /tmp/afm-ime.log
scripts/debug.sh --stop # 关闭 debug(标志文件 /tmp/afm-ime-debug)
```

## 结构

```
Sources/
├── IMECore/        # 词库(DictStore mmap)、拼音切分、候选引擎、TIS 安装器、debug 日志
├── AFMInput/       # 输入法主体(IMKServer/InputController/液态玻璃候选窗/⌃V 剪贴板·⌃F 翻译伴随面板/FM 重排)+ 安装 CLI
├── AFMInstaller/   # 安装器 GUI(安装→一键注销→重登完成启用)
├── DictCompiler/   # 多源词库 → dict.bin 编译器(rime yaml/撇号拼音/词频 TSV/源码提取/markdown)
└── DictBench/      # 词库加载/查询基准(含各外部词库源回归查询)
vendor/             # 词库源:rime-ice + 萌娘百科/zhwiki/minecraft/蔚蓝档案/THUOCL/ali-words
Experiments/        # FM 框架测绘、梗合集词库等实验材料
scripts/build_dict.sh  # 全量词库编译入口
Data/dict.bin       # 编译产物(git 忽略,build_dict.sh 重新生成)
```

## 性能(本机 macOS 27 / M 系列)

| 场景 | 耗时 |
|---|---|
| 词库加载(mmap) | 0.2–1ms |
| 单次候选查询 | 0.1–4ms |
| FM 重排(暖) | ~350ms(异步,不阻塞打字) |
| FM 整句(暖) | ~350ms(占位等待) |
