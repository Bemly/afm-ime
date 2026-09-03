#!/bin/bash
# Debug 模式开关:创建标志文件后由系统按需拉起输入法(launchd),日志实时跟踪
# 用法: scripts/debug.sh        — 开启 debug + 重启输入法 + tail 日志
#       scripts/debug.sh --stop — 关闭 debug + 停止输入法
# 日志: /tmp/afm-ime.log
set -euo pipefail
cd "$(dirname "$0")/.."

LOG="${AFM_LOG:-/tmp/afm-ime.log}"
FLAG=/tmp/afm-ime-debug

killall AFMInput 2>/dev/null || true

if [[ "${1:-}" == "--stop" ]]; then
  rm -f "$FLAG"
  echo "debug 已关闭,输入法已停止(打字或切换输入法时系统会自动拉起)"
  exit 0
fi

touch "$FLAG"
: > "$LOG"

# 让系统重新拉起(launchd 管理,别手动 nohup——手动进程客户端连不上)
open "$HOME/Library/Input Methods/AFM拼音.app" 2>/dev/null || true
sleep 1
echo "AFM拼音 debug 已开启(PID $(pgrep -x AFMInput | head -1)) 日志: $LOG"
echo "若切换输入法后仍无日志,切到 ABC 再切回 AFM拼音 触发重连"
echo "================================================"
tail -f "$LOG"
