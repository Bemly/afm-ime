#!/bin/zsh
# 打包 .pkg 安装器:build/AFM拼音-<版本>.pkg
#   payload = AFM拼音.app → /Library/Input Methods(系统级,双击 pkg 管理员授权安装)
#   postinstall = 结束运行中的引擎 → 以控制台用户身份递交 TIS 注册(内部查重)+ 幂等启用(--ensure-enabled,
#                 已启用不触碰 TIS 活视图——enable 的 disableAll 会摘掉正在用的输入源,升级路径绝不能走)
#   首次安装需注销重登一次完成 TIS 登录扫描收录;之后更新 = 换盘 + 引擎重启,无需注销
#   签名: 优先自签证书 AFM-IME-Dev,缺失回退 ad-hoc(对外分发需 Developer ID + 公证,见 AGENTS.md)
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d "build/AFM拼音.app" ] || { echo "先运行 scripts/package.sh"; exit 1; }

VERSION=$(plutil -extract CFBundleShortVersionString raw "build/AFM拼音.app/Contents/Info.plist")
IDENT="moe.bemly.inputmethod.AfmIME.pkg"
COMPONENT="build/AFM拼音-component.pkg"
OUT="build/AFM拼音-$VERSION.pkg"

STAGE="build/pkgroot/Library/Input Methods"
rm -rf build/pkgroot build/pkgscripts
rm -f "$COMPONENT" "$OUT"
mkdir -p "$STAGE" build/pkgscripts
cp -R "build/AFM拼音.app" "$STAGE/"

cat > build/pkgscripts/postinstall <<'POST'
#!/bin/bash
# AFM拼音 安装后脚本(root 运行):TIS 操作以控制台用户身份执行(TIS 缓存/偏好都是 per-user)
set -u
APP="/Library/Input Methods/AFM拼音.app"
BIN="$APP/Contents/MacOS/AFMInput"
[ -x "$BIN" ] || { echo "!! 引擎二进制缺失: $BIN"; exit 1; }

# 结束运行中的旧引擎(launchd/imklaunchagent 需要时自动重启,拿到新 bundle)
killall AFMInput 2>/dev/null || true
killall AFMSettings 2>/dev/null || true

CONSOLE_USER=$(stat -f%Su /dev/console)
USER_UID=$(id -u "$CONSOLE_USER")
asuser() { launchctl asuser "$USER_UID" sudo -u "$CONSOLE_USER" "$@"; }

echo "== TIS 注册(内部查重,已注册自动跳过) =="
asuser "$BIN" --register-input-source || true
echo "== 启用(幂等:已启用跳过不碰活视图,未启用 defaults 直写兜底) =="
asuser "$BIN" --ensure-enabled || true

echo "AFM拼音 已安装到 /Library/Input Methods。首次安装请注销并重新登录一次完成收录;之后更新无需注销。"
exit 0
POST
chmod +x build/pkgscripts/postinstall

pkgbuild --root build/pkgroot --scripts build/pkgscripts \
    --identifier "$IDENT" --version "$VERSION" --install-location "/" \
    "$COMPONENT"

SIGN_ID="AFM-IME-Dev"
security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID" || SIGN_ID="-"
# 签名: productbuild --sign / productsign 要求「installer 签名身份」——自签应用证书(AFM-IME-Dev,
# EKU=codeSigning)会被拒(实测 2026-09-15);codesign 直接签 flat pkg 是假成功(pkgutil 仍报无签名)。
# 故 productbuild 先出未签名 product,再试 productsign,失败则保持未签名
# (本机 sudo installer 可装;对外分发需 Developer ID Installer + 公证)
productbuild --package "$COMPONENT" \
    --product "build/AFM拼音.app/Contents/Info.plist" \
    "$OUT"
if [ "$SIGN_ID" != "-" ] && productsign --sign "$SIGN_ID" "$OUT" "$OUT.signed" 2>/dev/null; then
  mv "$OUT.signed" "$OUT"
  echo "pkg 已签名: $SIGN_ID"
else
  rm -f "$OUT.signed"
  echo "!! pkg 未签名(自签证书不被 productsign 接受)——本机可用 sudo installer 安装"
fi

rm -rf build/pkgroot build/pkgscripts "$COMPONENT"
echo "打包完成: $OUT (pkg 签名: $([ "$SIGN_ID" != "-" ] && pkgutil --check-signature "$OUT" 2>/dev/null | grep -q "Status: signed" && echo "$SIGN_ID" || echo "无"))"
