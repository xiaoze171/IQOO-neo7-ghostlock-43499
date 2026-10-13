#!/data/data/com.termux/files/usr/bin/bash
# Termux:Boot entry — 开机后自动跑手机端一键 root（放到 ~/.termux/boot/00-ghostlock.sh）。
# 需要：
#   - Termux:Boot 已安装，且在 vivo「自启动管理」里放行 Termux / Termux:Boot
#   - Android 在用户解锁后才发 BOOT_COMPLETED —— 开机后请解锁一次手机
export HOME=/data/data/com.termux/files/home
export PREFIX=/data/data/com.termux/files/usr
export PATH="$PREFIX/bin:$PATH"
LOG="$HOME/ghostlock/boot.log"
mkdir -p "$HOME/ghostlock"
exec >>"$LOG" 2>&1
echo "=== boot trigger $(date) ==="
sleep 20
# 把 Termux 拉到前台：流程可见，同时避免被后台冻结（freezer）掐断
am start -n com.termux/.app.TermuxActivity >/dev/null 2>&1
sleep 5
exec bash "$HOME/ghostlock/root.sh" --auto
