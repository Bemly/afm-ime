#!/bin/bash
# Debug 模式重启输入法并实时跟踪日志
# 用法: scripts/debug.sh        — 重启 + tail 日志(Ctrl+C 退出跟踪,输入法继续运行)
#       scripts/debug.sh --stop — 停止输入法
# 环境变量: AFM_LOG(默认 /tmp/afm-ime.log)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$HOME/Library/Input Methods/AFM拼音.app"
export AFM_LOG="${AFM_LOG:-/tmp/afm-ime.log}"

if [[ "${1:-}" == "--stop" ]]; then
  killall AFMInput 2>/dev/null || true
  echo "输入法已停止"
  exit 0
fi

[[ -x "$APP/Contents/MacOS/AFMInput" ]] || { echo "先 scripts/package.sh + 安装"; exit 1; }

killall AFMInput 2>/dev/null || true
sleep 0.5
: > "$AFM_LOG"

export AFM_DEBUG=1
nohup "$APP/Contents/MacOS/AFMInput" >>"$AFM_LOG" 2>&1 &
disown
sleep 1
echo "AFM拼音 debug 模式已启动(PID $(pgrep -x AFMInput | head -1))"
echo "日志: $AFM_LOG  (Ctrl+C 退出跟踪)"
echo "================================================"
tail -f "$AFM_LOG"
