#!/bin/bash
# 注销重登后运行:检查登录扫描是否注册了 AFM拼音,已注册则自动启用+选中
APP="$HOME/Library/Input Methods/AFM拼音.app"
PROBE="$(dirname "$0")/../build/tis3_probe"

echo "=== TIS 注册状态 ==="
RESULT=$("$PROBE" 2>/dev/null | grep "afm" || true)
echo "${RESULT:-未注册}"

if echo "$RESULT" | grep -q "hans"; then
  echo "=== 已注册!启用+选中 ==="
  "$APP/Contents/MacOS/AFMInput" --enable-input-source
  "$APP/Contents/MacOS/AFMInput" --select-input-source
  open "$APP"
  echo "完成:现在可以打开 文本编辑/备忘录,切到 AFM拼音 打字测试"
else
  echo "=== 登录扫描未注册(ad-hoc 未过公证门槛) ==="
  echo "下一步需要 Apple Developer 公证,或改用 Demo harness 演示"
fi
