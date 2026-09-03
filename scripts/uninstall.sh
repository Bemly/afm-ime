#!/bin/bash
# 完全卸载 AFM拼音:进程、bundle、defaults 启用条目
# 注: TIS 注册表条目会在下次注销重登时由登录扫描自动清除
set -euo pipefail

killall AFMInput 2>/dev/null || true
rm -rf "$HOME/Library/Input Methods/AFM拼音.app"
sudo -n rm -rf "/Library/Input Methods/AFM拼音.app" 2>/dev/null || true

TMP=$(mktemp /tmp/hitoolbox.XXXXXX.plist)
defaults export com.apple.HIToolbox "$TMP"
python3 - "$TMP" <<'EOF'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f:
    d = plistlib.load(f)
removed = 0
for k in list(d.keys()):
    if isinstance(d[k], list) and any('afm' in str(e).lower() for e in d[k]):
        before = len(d[k])
        d[k] = [e for e in d[k] if 'afm' not in str(e).lower()]
        removed += before - len(d[k])
with open(p, 'wb') as f:
    plistlib.dump(d, f)
print(f"defaults 清理: 移除 {removed} 条")
EOF
defaults import com.apple.HIToolbox "$TMP"
rm -f "$TMP"
echo "卸载完成。TIS 注册表残留会在下次注销重登时自动清除。"
