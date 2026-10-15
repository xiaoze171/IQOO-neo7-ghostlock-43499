#!/system/bin/sh
# ============================================================================
#  GhostLock on-device staging — 把 gl_stage/ 里的工具链分发进 Termux 私有目录
#
#  设备端执行（需要 root，su 通道可用时跑一次）：
#     su -c sh /data/local/tmp/gl_stage/stage_install.sh
#
#  做的事：
#    1. 把 gl_stage/ 里的 exploit / 补丁脚本 / loader / root.sh 拷进
#       ~/ghostlock/（Termux 私有目录，属主必须是 Termux uid，否则读不了）
#    2. 兜底写入 ~/.termux/termux.properties (allow-external-apps=true)
#
#    （开机自动执行已移除：每次开机由用户在 Termux 里手动跑
#      bash ~/ghostlock/root.sh ；需要自动时把 00-ghostlock.sh 放进
#      ~/.termux/boot/ 并装 Termux:Boot 即可）
#    4. 若 gl_stage 里有 adbkey（Termux 专用 adb 密钥），一并装进 ~/.android
#
#  注意：Android 端 sh 是 mksh + toybox，不要用 bash 语法。
# ============================================================================
set -e

STAGE=/data/local/tmp/gl_stage
THOME=/data/data/com.termux/files/home
GL=$THOME/ghostlock

[ "$(id -u)" = 0 ] || { echo "[-] 必须 root 执行：su -c sh $0"; exit 1; }
[ -d "$STAGE" ] || { echo "[-] 缺少 $STAGE，先把文件推上来"; exit 1; }

# Termux uid 每台设备不同，从其 home 目录属主动态取
TUID=$(stat -c %u $THOME) || { echo "[-] 取不到 Termux uid（Termux 装了吗？）"; exit 1; }
echo "[*] Termux uid = $TUID"

# ---- 1) 工具链 → ~/ghostlock/ ---------------------------------------------
mkdir -p $GL
for f in gl_mcast43 ksu_loader.sh sakisu_raw.ko patch_vermagic.py \
         patch_shnabs.py unknown_syms.txt fix_ashmem.sh root_ondevice.sh; do
  [ -f $STAGE/$f ] || { echo "[-] $STAGE/$f 缺失"; exit 1; }
  cp $STAGE/$f $GL/$f
done
# root_ondevice.sh 在手机上的入口名就是 root.sh
cp $STAGE/root_ondevice.sh $GL/root.sh
chmod 755 $GL/gl_mcast43 $GL/root.sh $GL/ksu_loader.sh $GL/fix_ashmem.sh
chmod 644 $GL/sakisu_raw.ko $GL/patch_vermagic.py $GL/patch_shnabs.py $GL/unknown_syms.txt

# ---- 2) termux.properties -------------------------------------------------
# 注意：首启模板里有一行注释掉的 "# allow-external-apps = true"，grep 裸关键词
# 会被它误导，必须匹配未注释的键。
if ! grep -qE '^[[:space:]]*allow-external-apps[[:space:]]*=[[:space:]]*true' \
     $THOME/.termux/termux.properties 2>/dev/null; then
  echo "allow-external-apps = true" >> $THOME/.termux/termux.properties
fi

# ---- 4) Termux 专用 adb 密钥（可选，setup 脚本推了才装） --------------------
if [ -f $STAGE/glkey ]; then
  mkdir -p $THOME/.android
  cp $STAGE/glkey $THOME/.android/adbkey
  cp $STAGE/glkey.pub $THOME/.android/adbkey.pub
  chmod 700 $THOME/.android
  chmod 600 $THOME/.android/adbkey $THOME/.android/adbkey.pub
  # 加入 adbd 白名单（去重追加）
  PUB=$(cat $THOME/.android/adbkey.pub)
  touch /data/misc/adb/adb_keys
  grep -qF "$PUB" /data/misc/adb/adb_keys || echo "$PUB" >> /data/misc/adb/adb_keys
  echo "[+] adb 密钥已装进 ~/.android 并加入 adbd 白名单"
fi

# ---- 5) 属主统一归还 Termux uid -------------------------------------------
chown -R $TUID:$TUID $GL $THOME/.termux $THOME/.android 2>/dev/null

echo "[+] 安装完成："
ls -l $GL
echo "[*] 下一步（Termux 里手动执行一次）：pkg install -y python android-tools"