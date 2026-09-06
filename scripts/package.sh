#!/bin/zsh
# 打包: 输入法引擎 build/AFMInput.app(部署到 ~/Library/Input Methods/AFM拼音.app)
#      + GUI 控制中心 build/AFM拼音.app(安装器+词库+用户词+设置,内嵌引擎)
set -euo pipefail
cd "$(dirname "$0")/.."

# 签名: 优先自签证书 AFM-IME-Dev(DR=证书绑定,TCC「输入监控」授权跨构建有效,Shift tap 依赖);
# 证书缺失回退 ad-hoc(DR=cdhash,每次构建变化,授权会失效)。证书生成方法见 AGENTS.md
SIGN_ID="AFM-IME-Dev"
security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID" || SIGN_ID="-"

# 构建: xcodebuild(Xcode 工具链 + macOS 27 SDK,平台基线 platforms: [.macOS("27.0")])。
# Xcode 缺失/构建失败时回退 swift build(CLT,SDK 同为 27)。
XDEV="${DEVELOPER_DIR:-}"
if [ -z "$XDEV" ]; then
  for c in /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer; do
    [ -d "$c" ] && XDEV="$c" && break
  done
fi
BINDIR=""
if [ -n "$XDEV" ] && [ -d "$XDEV" ]; then
  if DEVELOPER_DIR="$XDEV" xcodebuild -scheme afm-ime-Package -configuration Release \
       -destination 'platform=macOS' -derivedDataPath .build/xcode build >/dev/null; then
    BINDIR=".build/xcode/Build/Products/Release"
    echo "构建完成: xcodebuild (macOS 27 SDK, DEVELOPER_DIR=$XDEV)"
  else
    echo "!! xcodebuild 构建失败,回退 swift build(CLT)"
  fi
else
  echo "!! 未找到 Xcode(DEVELOPER_DIR 未设且 /Applications 无 Xcode*.app),回退 swift build(CLT)"
fi
if [ -z "$BINDIR" ]; then
  swift build -c release
  BINDIR=".build/release"
fi

# Metal shader → default.metallib(候选条水滴折射 layerEffect)。
# 需要 Xcode 的 Metal Toolchain(Xcode 26+ 组件缺失时: DEVELOPER_DIR=<Xcode> xcodebuild -downloadComponent metalToolchain);
# 缺失/编译失败则打包照常,水滴退化为纯玻璃无折射。
XDEV="${DEVELOPER_DIR:-}"
if [ -z "$XDEV" ]; then
  for c in /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer; do
    [ -d "$c" ] && XDEV="$c" && break
  done
fi
METALLIB=""
if [ -n "$XDEV" ] && [ -d "$XDEV" ]; then
  if DEVELOPER_DIR="$XDEV" xcrun -sdk macosx metal -c Metal/DropletLens.metal -o build/DropletLens.air \
     && DEVELOPER_DIR="$XDEV" xcrun -sdk macosx metallib build/DropletLens.air -o build/default.metallib; then
    METALLIB="build/default.metallib"
    echo "Metal shader 编译完成: default.metallib (DEVELOPER_DIR=$XDEV)"
  else
    echo "!! Metal shader 编译失败——水滴将无折射。需要 Xcode + Metal Toolchain 组件"
  fi
else
  echo "!! 未找到 Xcode(DEVELOPER_DIR 未设且 /Applications 无 Xcode*.app)——跳过 Metal shader,水滴将无折射"
fi

# 输入法引擎 bundle: build/AFMInput.app(部署到 ~/Library/Input Methods/AFM拼音.app,文件名无关紧要,
# TIS 按 bundle id 识别;GUI app 叫 AFM拼音.app,避免 build 目录同名冲突)
APP="build/AFMInput.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/afm-input" "$APP/Contents/MacOS/AFMInput"
cp Data/dict.bin "$APP/Contents/Resources/dict.bin"
[ -n "$METALLIB" ] && cp "$METALLIB" "$APP/Contents/Resources/default.metallib"
[ -f Data/icon.tiff ] && cp Data/icon.tiff "$APP/Contents/Resources/icon.tiff"
[ -f Data/appicon.tiff ] && cp Data/appicon.tiff "$APP/Contents/Resources/appicon.tiff"

# 输入源显示名:TIS 用「输入源 ID」在 InfoPlist.strings 里查显示名(参考 squirrel InfoPlist.xcstrings)
for lproj in zh-Hans en; do
  mkdir -p "$APP/Contents/Resources/$lproj.lproj"
  cat > "$APP/Contents/Resources/$lproj.lproj/InfoPlist.strings" <<'STRINGS'
"moe.bemly.inputmethod.AfmIME" = "AFM拼音";
"moe.bemly.inputmethod.AfmIME.afmpinyin.hans" = "AFM拼音";
"CFBundleDisplayName" = "AFM拼音";
"CFBundleName" = "AFM拼音";
STRINGS
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
	<key>CFBundleExecutable</key><string>AFMInput</string>
	<key>CFBundleIdentifier</key><string>moe.bemly.inputmethod.AfmIME</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>AFM拼音</string>
	<key>CFBundleDisplayName</key><string>AFM拼音</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>2026.09.06</string>
	<key>CFBundleVersion</key><string>20260906</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>LSBackgroundOnly</key><false/>
	<key>LSUIElement</key><true/>
	<key>InputMethodConnectionName</key><string>moe.bemly.inputmethod.AfmIME_Connection</string>
	<key>InputMethodServerControllerClass</key><string>afm_input.InputController</string>
	<key>TISIntendedLanguage</key><string>zh-Hans</string>
	<key>TICapsLockLanguageSwitchCapable</key><true/>
	<key>tsInputMethodCharacterRepertoireKey</key>
	<array><string>Hans</string><string>Latn</string></array>
	<key>tsInputMethodIconFileKey</key><string>icon.tiff</string>
	<key>ComponentInputModeDict</key>
	<dict>
		<key>tsInputModeListKey</key>
		<dict>
			<key>moe.bemly.inputmethod.AfmIME.afmpinyin.hans</key>
			<dict>
				<key>TISInputSourceID</key><string>moe.bemly.inputmethod.AfmIME.afmpinyin.hans</string>
				<key>TISIntendedLanguage</key><string>zh-Hans</string>
				<key>tsInputModeMenuIconFileKey</key><string>icon.tiff</string>
				<key>tsInputModeAlternateMenuIconFileKey</key><string>icon.tiff</string>
				<key>tsInputModePaletteIconFileKey</key><string>icon.tiff</string>
				<key>tsInputModeCharacterRepertoireKey</key>
				<array><string>Hans</string><string>Latn</string></array>
				<key>tsInputModeDefaultStateKey</key><true/>
				<key>tsInputModeIsVisibleKey</key><true/>
				<key>tsInputModeKeyEquivalentModifiersKey</key><integer>4608</integer>
				<key>tsInputModePrimaryInScriptKey</key><true/>
				<key>tsInputModeScriptKey</key><string>smUnicodeScript</string>
			</dict>
		</dict>
		<key>tsVisibleInputModeOrderedArrayKey</key>
		<array><string>moe.bemly.inputmethod.AfmIME.afmpinyin.hans</string></array>
	</dict>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_ID" "$APP"
echo "打包完成: $APP (签名: $SIGN_ID)"

# GUI 控制中心 App: build/AFM拼音.app(内嵌输入法引擎;安装器 + 词库浏览 + 用户词权重 + 设置,液态玻璃)
GUI="build/AFM拼音.app"
rm -rf "$GUI"
mkdir -p "$GUI/Contents/MacOS" "$GUI/Contents/Resources"
cp "$BINDIR/afm-app" "$GUI/Contents/MacOS/AFMApp"
cp -R "$APP" "$GUI/Contents/Resources/AFM拼音.app"
[ -f Data/appicon.tiff ] && cp Data/appicon.tiff "$GUI/Contents/Resources/appicon.tiff"
cat > "$GUI/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
	<key>CFBundleExecutable</key><string>AFMApp</string>
	<key>CFBundleIdentifier</key><string>moe.bemly.AFMApp</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>AFM拼音</string>
	<key>CFBundleDisplayName</key><string>AFM拼音</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>2026.09.06</string>
	<key>CFBundleVersion</key><string>20260906</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict>
</plist>
PLIST
codesign --force --sign "$SIGN_ID" "$GUI"
echo "打包完成: $GUI (签名: $SIGN_ID)"
