# AFM拼音 (afm-ime)

macOS 27 液态玻璃(Liquid Glass)风格的中文拼音输入法,调用端侧 Apple Foundation Models(fm)system 大模型增强候选预测。参考 UI:macOS 26 风格候选窗(拼音条 + 候选词网格 + 首选高亮 pill)。

## 环境事实(2026-09-03 已验证)

- macOS 27.0 (Build 26A5425a) arm64;Swift 6.4(**仅 CommandLineTools,无 Xcode 且不需要装**)
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
│   ├── 词库编译器: rime-ice dict.yaml → 二进制 dict.bin(启动加载 <100ms)
│   ├── 拼音切分: 音节树 + 模糊音(zh/z、ch/c、sh/s、v→ü)
│   └── 候选生成: 词图 + Viterbi/beam search,按词频权重出 n-best
├── FM 层(端侧大模型,双通道)
│   ├── 首选: 进程内 import FoundationModels(SystemLanguageModel)
│   ├── 回退: 子进程调 /usr/bin/fm respond --schema
│   ├── 用途①: 结合上文对词典候选异步重排序(到达后无感刷新候选窗)
│   └── 用途②: 长句拼音直接让模型预测整句/短语(词典切不出时兜底)
└── UI 层
    ├── NSPanel + NSGlassEffectView 真·液态玻璃(圆角/透明/高光/亮暗自适应)
    ├── 左侧拼音显示区(下划线样式) + 候选词网格、首选高亮 pill、序号、翻页
    └── 跟随光标定位(client caret rect),点选上屏,数字键 1-9 选词
```

**FM 延迟策略**:词典候选先秒出保证跟手,FM 重排/整句预测异步到达后原地刷新(不阻塞打字)。

## 里程碑

1. **M1 词库管线** — shallow clone rime-ice;Swift 工具把 cn_dicts 的 dict.yaml 编译成拼音倒排的 `dict.bin` 进 bundle
2. **M2 输入法骨架** — IMKServer + InputController;打包 .app(ad-hoc 签名)装到 `~/Library/Input Methods`,先能打出汉字
3. **M3 液态玻璃 UI** — NSGlassEffectView 候选窗,对齐参考图样式
4. **M4 FM 接入** — 进程内 FoundationModels + fm CLI 回退;候选重排 + 整句预测
5. **M5 收尾** — 安装脚本、debug 测试窗口;用户在系统设置添加一次输入法

## 构建 / 安装(无 Xcode 流程)

```sh
swift build -c release
scripts/package.sh   # 组装 .app bundle + codesign -fs -
# 安装: 拷贝到 ~/Library/Input Methods/,launchd 按需拉起,系统设置 → 键盘 → 输入法 → + → 简体中文 → AFM拼音
```

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
- session 复用会携带 transcript 上下文(整句测试中受上文影响)——对输入法是**特性**(连续对话式预测),但需控制 transcript 增长
- **结论**:FM 做不了逐键级(<100ms)的跟手响应,词典引擎负责跟手;FM 异步增强(0.3s 到达)完全可用

## 词库数据(vendor/rime-ice/cn_dicts,已 sparse clone)

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

## 决策记录

- 不装 Xcode(CLT 可编译全部所需);若撞到必须 Xcode 的坑,暂停向用户提出选项
- rime-ice 词库下载已获用户同意(用户指定必须用 rime 词库)
- FM 不可用/无权限时自动静默回退 CLI 通道,再不行就纯词典模式,不阻塞输入
- 进程内 FoundationModels 需 Apple Intelligence 已开启(本机 `fm available` 已确认)

## 安装要点(M2 实测踩坑)

- **用户级 ~/Library/Input Methods 在 macOS 27 上 TIS 不扫描**(重启/杀缓存均无效,TISCreateInputSourceList 331 个源中无第三方)——必须装系统级 `/Library/Input Methods/`(参考 squirrel/fcitx5-macos 均如此),需要一次 sudo:`scripts/install.sh`
- Info.plist **必须有 ComponentInputModeDict**(tsInputModeListKey 每个输入模式含 TISInputSourceID/TISIntendedLanguage/tsInputModeCharacterRepertoireKey/tsInputModeScriptKey 等)——这是 TIS 枚举输入法的依据,缺了系统完全不认识(参考 vendor/squirrel/resources/Info.plist)
- LSUIElement=true + LSBackgroundOnly=false(squirrel 同款);`open` 对已运行进程是空操作,重装后要先 killall 再 open
- Swift 侧 IMK 注意:handleEvent→handle、updateCandidates 需经 NSSelectorFromString、server 是方法调用 server()
- tis_probe(proto/tis_probe.swift)可查询 TIS 是否已注册本输入法

## TIS 注册完整结论(M2 踩坑 2026-09-04,综合 VietTelex macOS 26.5 实测 + 本机 macOS 27 实验)

**macOS 26/27 对第三方输入法注册是"静默拒绝"模式**——所有条件不满足时 `TISRegisterInputSource` 仍返回 noErr,但源永不枚举、无任何日志。已验证/已确认的事实:

1. **Bundle id 必须含 `inputmethod` 段**(如 `com.afm.inputmethod.afmpinyin`);mode id = bundle id + 后缀(如 `.hans`)。不含则完全不注册。
2. **坏 id 会被毒化**:以无效状态装过一次的 id 永久失效(即使修好其他一切),必须换新 id。
3. **controller 类名**:`@objc(InputController)` 显式命名与 plist 不一致 → IMK 实例化失败 → 永不注册。推荐:不写显式 @objc,plist 写 `模块名.类名`(如 `afm_input.InputController`),otool -ov 应显示 `_TtC9afm_input14InputController`。
4. **TISRegisterInputSource 只产生瞬态注册**:仅在(部分)进程视图中短暂可见,cfprefsd 同步后即被冲掉。用 `--setup`(单进程 register+enable+select 连做)可在窗口期内完成三步,但 select 对 IME 返回 -50,且状态随时丢失。**持久注册只有一条路:登录扫描(logout/login)**。
5. **公证(notarization)是登录扫描的门槛**(VietTelex 对照实验:同一目录下公证过的第三方输入法首次注销登录即注册;未公证的从未注册过)。ad-hoc 签名 = 永不过 Gatekeeper = 登录扫描也不认。
6. **InputMethodConnectionName 必须是 `<bundle-id>_Connection`**,否则沙箱客户端(WhatsApp/MAS 应用)连不上 NSConnection。
7. 反模式:killall cfprefsd(冲掉瞬态注册+丢偏好写入)、defaults write com.apple.HIToolbox(绕不过 TIS 校验)、killall TextInputMenuAgent(无用)。
8. 本机 `security find-identity` = 0 个证书;公证需 Apple Developer Program(付费)。

**结论**:要走通"系统级可用的输入法"必须:Apple Developer 账号 → Developer ID 签名 + notarytool 公证 + stapler staple → 装 ~/Library/Input Methods → register → logout/login 一次 → 永久生效。开发期未公证的包只能靠瞬态注册做临时验证,不可靠。

## 启用状态管理(M2 实测补充)

- 添加选择器里的**灰色条目 = 已启用所以不可再选**(简体拼音也显示灰色),不是异常;出现多条是因为 base+mode+TIS select 各自写了一遍启用状态——安装脚本只写一条 mode 条目即可
- `TISEnableInputSource` 对 ad-hoc 包返回 noErr 但不写 `AppleEnabledInputSources`(静默无效);**可靠做法是 defaults 直写启用列表**(export→python 过滤→import,VietTelex 修复法),写完 TIS 已启用视图立即可见,无需注销
- 干净状态下 `TISSelectInputSource` 成功(此前 -50 是脏状态所致);选中状态写在 `AppleSelectedInputSources`
- scripts/uninstall.sh:进程+bundle+defaults 全清;TIS 注册表条目注销重登后由登录扫描清除
