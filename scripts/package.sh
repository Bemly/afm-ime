#!/bin/zsh
# 打包 AFM拼音.app 并安装到 ~/Library/Input Methods
set -euo pipefail
cd "$(dirname "$0")/.."

# 签名: 优先自签证书 AFM-IME-Dev(DR=证书绑定,TCC「输入监控」授权跨构建有效,Shift tap 依赖);
# 证书缺失回退 ad-hoc(DR=cdhash,每次构建变化,授权会失效)。证书生成方法见 AGENTS.md
SIGN_ID="AFM-IME-Dev"
security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID" || SIGN_ID="-"

swift build -c release

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

APP="build/AFM拼音.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/afm-input "$APP/Contents/MacOS/AFMInput"
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
	<key>CFBundleShortVersionString</key><string>2026.09.05</string>
	<key>CFBundleVersion</key><string>20260905</string>
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

# 安装器 App(内嵌 IME,一键安装+启用+直达输入源设置)
INSTALLER="build/AFM拼音安装器.app"
rm -rf "$INSTALLER"
mkdir -p "$INSTALLER/Contents/MacOS" "$INSTALLER/Contents/Resources"
cp .build/release/afm-installer "$INSTALLER/Contents/MacOS/AFMInstaller"
cp -R "$APP" "$INSTALLER/Contents/Resources/"
cp Data/appicon.tiff "$INSTALLER/Contents/Resources/appicon.tiff"
cat > "$INSTALLER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>AFMInstaller</string>
	<key>CFBundleIdentifier</key><string>com.afm.afmpinyin.installer</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>AFM拼音安装器</string>
	<key>CFBundleDisplayName</key><string>AFM拼音安装器</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>2026.09.05</string>
	<key>CFBundleVersion</key><string>20260905</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
codesign --force --sign "$SIGN_ID" "$INSTALLER"
echo "打包完成: $INSTALLER"
