#!/bin/zsh
# 打包 AFM拼音.app 并安装到 ~/Library/Input Methods
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/AFM拼音.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/afm-input "$APP/Contents/MacOS/AFMInput"
cp Data/dict.bin "$APP/Contents/Resources/dict.bin"
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
	<key>CFBundleShortVersionString</key><string>2026.09.04</string>
	<key>CFBundleVersion</key><string>20260904</string>
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

codesign --force --sign - "$APP"
echo "打包完成: $APP"

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
	<key>CFBundleShortVersionString</key><string>2026.09.04</string>
	<key>CFBundleVersion</key><string>20260904</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$INSTALLER"
echo "打包完成: $INSTALLER"
