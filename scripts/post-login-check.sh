#!/bin/bash
# 注销重登后运行: 检查登录扫描是否已收录 AFM拼音,已收录则启用+选中
APP="$HOME/Library/Input Methods/AFM拼音.app"
PROBE="$(dirname "$0")/../build/tis3_probe"

echo "=== TIS 注册状态 ==="
RESULT=$("$PROBE" 2>/dev/null | grep -i "bemly" || true)
echo "${RESULT:-未注册}"

if echo "$RESULT" | grep -qi "hans"; then
  echo "=== 已收录!启用+选中 ==="
  "$APP/Contents/MacOS/AFMInput" --enable-input-source
  "$APP/Contents/MacOS/AFMInput" --select-input-source
  open "$APP"
  echo "完成:Ctrl+Space 切换到 AFM拼音,打开文本编辑打 nihao 测试"
else
  echo "=== 登录扫描未收录 ==="
  echo "处理:重新递交注册后再次注销重登 —"
  echo "  \"$APP/Contents/MacOS/AFMInput\" --register-input-source && echo 然后注销重登"
fi
