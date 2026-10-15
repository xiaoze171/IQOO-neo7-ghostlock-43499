#!/usr/bin/env bash
# ============================================================================
#  GhostLock on-device one-time setup — 电脑端一次性配置（Git Bash / WSL / Linux）
#
#  跑完这个脚本后，手机就不再依赖电脑：重启后在 Termux 里
#     bash ~/ghostlock/root.sh
#  或由 Termux:Boot 开机自动跑（root.sh --auto）。
#
#  前置条件：
#    1. 手机已按 docs/使用指南.md 跑通过电脑端流程（SakiSU 已装，su 通道可用）
#    2. 当前 USB adb 已连接，且 su -c id 能拿到 uid=0
#       （最佳时机：刚跑完 onekey_root 的时候）
#    3. 手机上已安装 Termux（不需要先装 python/android-tools，之后在 Termux 里装）
#
#  用法：
#    ./setup_ondevice.sh              # 单设备
#    ./setup_ondevice.sh <序列号>     # 多设备时指定 -s
#
#  本脚本生成 scripts/ondevice/glkey（Termux 专用 adb 密钥），已在 .gitignore 排除，
#  不要提交、不要分享。
# ============================================================================
set -e

# Git Bash / MSYS 会把以 / 开头的参数（adb push 的远端路径）改写成本地 Git 安装
# 前缀路径（实测变成 <Git>/data/...），必须禁用；Linux/WSL 上这两个变量无意义。
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# 上面关掉了 MSYS 路径转换，adb.exe（Windows 程序）认不了 /d/... 形式的本地
# 路径，这里显式转成 D:/... 混合形式（bash 本地工具同样接受，Linux/WSL 无 cygpath 不受影响）
command -v cygpath >/dev/null 2>&1 && HERE="$(cygpath -m "$HERE")" && REPO="$(cygpath -m "$REPO")"
ADB="${ADB:-adb}"
STAGE=/data/local/tmp/gl_stage
THOME=/data/data/com.termux/files/home
KEY="$HERE/glkey"

S="${1:-}"
adbq() { if [ -n "$S" ]; then "$ADB" -s "$S" "$@"; else "$ADB" "$@"; fi; }
sh_()  { adbq shell "$@" | tr -d '\r'; }
su_()  { adbq shell "su -c '$1'" | tr -d '\r'; }

say() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[-]\033[0m %s\n' "$*"; exit 1; }

# ---- 0) 环境检查 -----------------------------------------------------------
command -v "$ADB" >/dev/null 2>&1 || die "找不到 adb，先设置 ADB=adb完整路径 再跑"
adbq get-state >/dev/null 2>&1 || die "设备未连接（adb devices 检查）"
ID0=$(su_ "id")
case "$ID0" in *uid=0*) ok "root 通道可用：$ID0";;
  *) die "su 不可用（su -c id 不是 uid=0）。先在电脑端跑通一次 onekey_root 拿到 root。" ;; esac

# ---- 1) adbd 开机监听 TCP 5555 --------------------------------------------
# 注意：不要用 ctl.restart/ctl.stop 重启 adbd —— shell 随 adbd 一起被杀，
# ctl.start 送不进去，设备会卡 offline（实测踩过）。切换用 host 端 `adb tcpip`：
# adbd 自己优雅退出并由 init 拉起，USB 自动恢复。
TP=$(sh_ "getprop service.adb.tcp.port" | tr -d ' \r')
PP=$(sh_ "getprop persist.adb.tcp.port" | tr -d ' \r')
if [ "$PP" = "5555" ] && [ "$TP" = "5555" ]; then
  ok "adbd 已监听 TCP 5555，跳过切换"
else
  say "设置 persist.adb.tcp.port=5555 并切换 adbd 到 TCP 模式"
  su_ "setprop persist.adb.tcp.port 5555"
  adbq tcpip 5555 >/dev/null 2>&1 || true
  sleep 5
  for i in $(seq 1 15); do
    st=$(adbq get-state 2>/dev/null) && [ "$st" = "device" ] && break
    sleep 2
  done
  TP=$(sh_ "getprop service.adb.tcp.port" | tr -d ' \r')
  [ "$TP" = "5555" ] || die "adbd TCP 切换失败（service.adb.tcp.port=$TP）。persist 已写入，重启手机后再跑本脚本即可。"
fi
ok "adbd 将在每次开机监听 TCP 5555（仅白名单密钥可连，ro.adb.secure=1）"

# ---- 2) Termux 专用 adb 密钥 ----------------------------------------------
say "生成 Termux 专用 adb 密钥并加入 adbd 白名单"
[ -f "$KEY" ] || "$ADB" keygen "$KEY" >/dev/null
adbq shell "rm -rf $STAGE && mkdir -p $STAGE"
adbq push "$KEY" "$STAGE/glkey" >/dev/null
adbq push "$KEY.pub" "$STAGE/glkey.pub" >/dev/null
ok "密钥已推送到设备（stage_install 会装进 Termux ~/.android）"

# ---- 3) 工具链推送 → gl_stage ---------------------------------------------
say "推送工具链到 $STAGE"
adbq push "$REPO/exploit/bin/gl_mcast43"   "$STAGE/gl_mcast43"       >/dev/null
adbq push "$REPO/ksu/ksu_loader.sh"        "$STAGE/ksu_loader.sh"    >/dev/null
adbq push "$REPO/ksu/sakisu_raw.ko"        "$STAGE/sakisu_raw.ko"    >/dev/null
adbq push "$REPO/ksu/patch_vermagic.py"    "$STAGE/patch_vermagic.py">/dev/null
adbq push "$REPO/ksu/patch_shnabs.py"      "$STAGE/patch_shnabs.py"  >/dev/null
adbq push "$REPO/ksu/unknown_syms.txt"     "$STAGE/unknown_syms.txt" >/dev/null
adbq push "$REPO/scripts/fix_ashmem.sh"    "$STAGE/fix_ashmem.sh"    >/dev/null
adbq push "$REPO/scripts/ondevice/root_ondevice.sh" "$STAGE/root_ondevice.sh" >/dev/null
# 开机自动执行（Termux:Boot）已按用户要求移除：每次开机手动跑
#   bash ~/ghostlock/root.sh
# 如需恢复自动，把 scripts/ondevice/00-ghostlock.sh 放进 ~/.termux/boot/ 即可。
adbq push "$HERE/stage_install.sh"         "$STAGE/stage_install.sh" >/dev/null

# 哈希校验（adb push 偶发写入损坏内容，实测踩过）
for f in gl_mcast43 sakisu_raw.ko root_ondevice.sh; do
  lh=$(sha256sum "$REPO/exploit/bin/$f" 2>/dev/null | cut -d' ' -f1)
  case "$f" in
    gl_mcast43)      lp="$REPO/exploit/bin/$f";;
    sakisu_raw.ko)   lp="$REPO/ksu/$f";;
    root_ondevice.sh) lp="$REPO/scripts/ondevice/$f";;
  esac
  lh=$(sha256sum "$lp" | cut -d' ' -f1)
  rh=$(sh_ "sha256sum $STAGE/$f" | cut -d' ' -f1)
  [ "$lh" = "$rh" ] || die "$f 推送校验失败（device=$rh repo=$lh），重跑本脚本"
done
ok "工具链就绪（关键文件哈希校验通过）"

# ---- 4) 设备端分发 --------------------------------------------------------
say "执行 stage_install.sh（分发进 Termux 私有目录并 chown）"
su_ "sh $STAGE/stage_install.sh"

# ---- 5) 验证 --------------------------------------------------------------
say "验证安装结果"
GLL=$(su_ "ls $THOME/ghostlock")
for f in root.sh gl_mcast43 sakisu_raw.ko patch_vermagic.py patch_shnabs.py ksu_loader.sh; do
  printf '%s' "$GLL" | grep -q "$f" || die "$THOME/ghostlock/$f 缺失"
done
UID2=$(su_ "stat -c %u $THOME/ghostlock/root.sh")
TUID=$(su_ "stat -c %u $THOME")
[ "$UID2" = "$TUID" ] || die "属主不对（root.sh uid=$UID2，Termux=$TUID）"
ok "全部就绪。"

cat <<'EOF'

══════════════════════════════════════════════════════════════
 手机端还差两步（只能在手机上做，做完即可脱离电脑）：

 1) 打开 Termux，装依赖（建议 TUNA 源，约 100MB）：
      pkg install -y python android-tools
    若 android-tools 报 cannot locate symbol __hash_memory：
      不用 pkg upgrade，直接把仓库里 libc++ 包解出的
      libc++_shared.so 覆盖进 $PREFIX/lib/（见 scripts/ondevice/README.md）

 2) 开机自启三件套：
      - 安装 Termux:Boot（F-Droid / TUNA 镜像），装完打开一次
      - vivo 设置 → 自启动管理：放行 Termux 和 Termux:Boot
      - 给 Termux 开「允许后台高耗电」（防冻结）

 之后每次开机：解锁一次屏幕 → Termux:Boot 自动跑
   bash ~/ghostlock/root.sh --auto
 → SakiSU 管理器里点一次【允许】→ 完整 root（约 3-5 分钟）。
 也可以手动：bash ~/ghostlock/root.sh
══════════════════════════════════════════════════════════════
EOF