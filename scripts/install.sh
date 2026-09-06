#!/bin/bash
# 安装 AFM拼音 并通过输入法二进制自身注册(Squirrel/KeyTao 同款流程)
# 默认用户级 ~/Library/Input Methods(无需 sudo);--system 装系统级(需 sudo)
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d "build/AFM拼音.app" ] || { echo "先运行 scripts/package.sh"; exit 1; }

if [ "${1:-}" = "--system" ]; then
    APP="/Library/Input Methods/AFM拼音.app"
    sudo rm -rf "$APP"
    sudo cp -R "build/AFM拼音.app" "$APP"
    sudo chown -R root:wheel "$APP"
else
    APP="$HOME/Library/Input Methods/AFM拼音.app"
    rm -rf "$APP"
    cp -R "build/AFM拼音.app" "$APP"
fi

xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
# 注意: 不做任何重签——package.sh 已用 AFM-IME-Dev 证书签名(重签 ad-hoc 会变 DR,
# TCC「输入监控」授权随 cdhash 失效,Shift tap 静默失明,见 AGENTS.md 代码签名一节)

"$APP/Contents/MacOS/AFMInput" --quit 2>/dev/null || true
"$APP/Contents/MacOS/AFMInput" --register-input-source
"$APP/Contents/MacOS/AFMInput" --enable-input-source
"$APP/Contents/MacOS/AFMInput" --select-input-source
echo "== 安装完成: $APP =="
