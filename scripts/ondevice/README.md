# 手机端一键 root（无需电脑）

让 iQOO Neo7 在**不连接电脑**的情况下自己完成提权：开机后在手机上跑一条命令
（或让 Termux:Boot 开机自动跑），链路与电脑端一键脚本完全相同，只是把「电脑上的
adb」换成「手机内部连自己的 adbd」。

```
Termux 里的 root.sh
      │  adb connect 127.0.0.1:5555   ← 手机内部 loopback，不需要 USB
      ▼
手机自己的 adbd（persist.adb.tcp.port=5555，密钥鉴权）→ uid 2000 / u:r:shell:s0
      │  发枪 gl_mcast43 → kallsyms → 补丁 .ko → insmod（经 exploit 的 root 通道）
      ▼
SakiSU 内核模块接管 → 在 SakiSU 里点一次【允许】→ root → SELinux 回 Enforcing → 修网络
```

## 为什么必须绕这一圈

exploit 要求以 **uid 2000 / `u:r:shell:s0`** 的进程发起：`untrusted_app` 域
（普通 App、Termux 自身）打不开 `perf_event_open`（KASLR 泄漏依赖它），也写不了
`/data/local/tmp`。手机上唯一能提供这个身份的途径就是「自己连自己的 adbd」——
adbd 开机自启，配好 `persist.adb.tcp.port` + 一把已授权密钥即可免电脑使用。

## 一次性配置（需要电脑一次）

**脚本化（推荐）**：手机按 docs/使用指南.md 跑通过一次（su 可用）后，在 Git Bash 里：

```bash
cd scripts/ondevice
ADB="D:/Android/platform-tools/adb.exe" ./setup_ondevice.sh   # 多设备加序列号参数
```

脚本自动完成：adbd 开机监听 TCP 5555 → 生成 Termux 专用密钥并加白名单 →
推送工具链 → 哈希校验 → 调用 `stage_install.sh` 分发进 Termux 私有目录并 chown。
跑完后按脚本末尾提示，在手机上装 Termux 依赖与 Termux:Boot 即可。

`setup_ondevice.sh` 会在本目录生成 `glkey`（Termux 专用 adb 私钥），已在
`.gitignore` 排除——**不要提交、不要分享**。

### 手动配置（脚本失败时的兜底）

前置：手机已按电脑端流程跑通过一次（SakiSU 管理器已安装）；电脑有 platform-tools；
手机上装好 Termux 与 Termux:Boot（F-Droid 或 TUNA 镜像均可）。

```bash
ADB=adb ; S=<序列号>

# 1) 让 adbd 每次开机监听 TCP（ro.adb.secure=1 → 只有白名单密钥能连）
$ADB -s $S shell "su -c 'setprop persist.adb.tcp.port 5555; setprop ctl.restart adbd'"

# 2) 生成手机专用密钥并加入 adbd 白名单
$ADB keygen glkey
$ADB -s $S push glkey glkey.pub /data/local/tmp/
$ADB -s $S shell "su -c 'mkdir -p /data/data/com.termux/files/home/.android; \
  cp /data/local/tmp/glkey /data/data/com.termux/files/home/.android/adbkey; \
  cp /data/local/tmp/glkey.pub /data/data/com.termux/files/home/.android/adbkey.pub; \
  chmod 600 /data/data/com.termux/files/home/.android/adbkey; \
  cat /data/data/com.termux/files/home/.android/adbkey.pub >> /data/misc/adb/adb_keys'"

# 3) 工具链铺进 Termux 私有目录：把 setup_ondevice.sh 第 3 步列的文件推到
#    /data/local/tmp/gl_stage/（root_ondevice.sh 也推进去），然后：
$ADB -s $S shell "su -c 'sh /data/local/tmp/gl_stage/stage_install.sh'"
#    脚本会拷贝到 ~/ghostlock/（root_ondevice.sh → root.sh）、装 boot 入口、
#    按动态取到的 Termux uid chown。

# 4) 在 Termux 里装依赖（约 100MB，建议 TUNA 源）
pkg install -y python android-tools
```

### 两个实测踩过的坑

- **Termux 的 `pkg`/`apt` 拒绝 root 运行**，所以要装包必须让 Termux 自己跑。
  没有电脑时：打开 Termux 手动执行 `pkg install ...` 即可。用电脑时也可给
  Termux:Boot 的接收器发一个显式广播来代跑（`am broadcast -a
  android.intent.action.BOOT_COMPLETED -n com.termux.boot/.BootReceiver`，
  把脚本临时放进 `~/.termux/boot/`）。
- **`android-tools` 可能与 bootstrap 的 `libc++_shared.so` ABI 不匹配**
  （报 `cannot locate symbol __hash_memory`）。无需 `pkg upgrade`（会卡在
  openssl.cnf 交互提示），直接把仓库里的 `libc++` 包解出 `libc++_shared.so`
  覆盖进 `$PREFIX/lib/` 即可。2026-10-15 实测的现成做法：
  `https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main/pool/main/libc/libc++/libc++_30_aarch64.deb`
  （.deb 是 ar 归档，python 解出 data.tar 里的 `libc++_shared.so`，覆盖后
  chown 回 Termux uid）；注意首启模板 termux.properties 里有一行**注释掉的**
  `# allow-external-apps = true`，用 grep 判断是否已启用时必须匹配未注释行，
  否则 RUN_COMMAND/Boot 通道会静默失效。

## 日常使用

| 方式 | 操作 |
|---|---|
| 手动（当前唯一方式） | 打开 Termux，执行 `bash ~/ghostlock/root.sh`（root.sh 已内置保活看门狗，跑的时候 Termux 会被自动拉到前台防冻结） |

> 开机自动执行（Termux:Boot）已按用户要求移除：`~/.termux/boot/` 入口与部署
> 脚本中的相关步骤均已删掉。如需恢复：装 Termux:Boot 并把
> `scripts/ondevice/00-ghostlock.sh` 放进 `~/.termux/boot/`，同时给 Termux 开
> 「后台高耗电」（发枪期间 vivo freezer 会冻结后台 Termux，实测卡死过全链路）。

脚本流程：连接本机 adbd → 状态判定（脏 boot 提示重启；KSU 已加载则直接跳到修复）
→ 推送/校验 exploit 与 loader → 发枪（失败自动重启重试，默认 3 次）→ 拉 kallsyms
→ 本机补丁（python）→ insmod → 拉起 SakiSU 管理器等授权 → SELinux 回 Enforcing +
重载策略（修网络）→ 验证。

发枪期间脚本会关闭 WiFi/移动数据降低调度噪声（loopback 不受影响），结束自动恢复。

### 实测需要知道的三件事

1. **发枪后要到 SakiSU 管理器里点一次【允许】**（授权不跨 boot 生效），root 才会
   真正可用；脚本会自己把管理器拉到前台并等待。
2. **不要在别处单独执行 `adb root`**：在本机 adbd 上它会触发 adbd 重启并丢掉
   TCP 监听，手机内的脚本立刻连不上自己（要恢复只能重启手机）。
3. 跑的时候**保持屏幕亮着、Termux 在前台**：vivo 会把后台的 Termux 冻进
   `do_freezer_trap`，脚本会卡住（跑之前可在设置里给 Termux 开「允许后台高耗电」）。

### 故障速查（症状 → 结论，2026-10-13 实测补充）

| 症状 | 结论 | 处理 |
|---|---|---|
| 脚本跑完 `id` 仍显示 uid=2000，怀疑是假 root | `id` 走的是手机内 adbd 通道，恒为 `shell`；root 真伪看 `su -c id`。电脑端「`adb root` 后 adb shell=uid 0」的结束态在手机端不存在 | 以脚本打印的 `root id`（`uid=0(root)`）为准 |
| 只看到「root 已就绪」，之后再没有输出就中断 | 修复（SELinux 回 Enforcing + `load_policy`）与最终验证都没执行，表现为 DNS/网络半坏、第三方 app 闪退 | 重跑脚本：KSU 已加载时会自动跳过发枪，直接补授权 → 修复 → 验证 |
| SakiSU 管理器打开是**红色**；点了允许、开了 ADB root 但 adbd 仍不是 root，脚本卡在等授权 | vivo 用 seccomp 击杀管理器首启时的 libksud 功能探针（`SIGSYS`, syscall 142），管理器在"未接管"状态下与内核模块的通信通道没建立——此时**所有开关操作都写不进内核**，划掉重开后探针重新跑，握手才成功 | **已自动化**（2026-10-15）：脚本在授权等待中约 18s 无果自动划掉重开管理器、约 48s 仍无 root 自动重启 adbd（等价 ADB root 关-开，开关配置须已持久）；仍失败才需人工：划掉重开 → 确认变绿 → 检查【ADB root】开关 → 重跑脚本 |
| 脚本运行途中手机自己重启了 | 发枪失败后的**设计内重试**：失败轮次内核残留 boot_id 劫持，同 boot 禁止二次发枪，唯一安全动作是重启回干净状态再试（自动最多 3 次）；偶发发枪 panic 软重启同理 | 无需处理；3 次全失败才需手动重跑 |
| 用着用着画面冻死、只能长按电源重启 | vivo 性能框架互锁：system_server 的 WMS 全局锁被 vperf 客户端（`libvivo-vperfd-client_system.so`）卡住、AMS 锁被 `pm dump` 卡住，ui/input 全堵死（dropbox 里 `Blocked in handler on ui thread`）。**与 KSU/exploit 无关**——实测 KSU 未加载的轮次同样发生 | 长按电源重启 → 重跑脚本；发枪窗口内避开 Scene / vivothermal / metric monitor 等重型调参、监控 App |
| 怎么确认本轮真的完整跑完 | — | 日志末尾出现「完成（修复+验证均已执行）」；旁证：`/data/local/tmp/fix_ashmem.sh` 存在、`gl_ondevice.log` 时间戳为当轮 |
| 脚本刚连接就秒退（`拿不到可用 shell`） | adbd 刚被重启过（管理器里切换【ADB Root】会重启 adbd），首个 shell 撞上连接竞态 | 已内置 10 轮 connect+探测重试；仍失败隔几秒重跑 |
| 非交互环境（boot 脚本/`su -c`）跑时报 `ADB server didn't ACK` | `TMPDIR` 未设置，adb 去写 `/data/local/tmp/adb.<uid>.log`（Termux uid 无权限） | 已内置默认 `TMPDIR=$PREFIX/tmp`，无需手工处理 |
| KSU 已加载且管理器里开过【ADB Root】 | adbd 直接以 root 运行（`adb shell id` = `uid=0 context=u:r:ksu:s0`） | 脚本自动识别并**跳过发枪**，直接修复+验证（实测 2026-10-13 全链路通过）；下次开机 insmod 后同样适用 |

### 更新部署（仓库改了以后）

手机里 `~/ghostlock/` 是**部署快照**，仓库改动不会自动同步（实测踩过「手机里跑
旧版 root.sh、仓库已修」的坑）。本目录更新后：

1. 在电脑上重跑 `setup_ondevice.sh`（会重新推送 + 分发 + 校验），或手动把新文件
   放进 `/data/local/tmp/gl_stage/`；
2. root 可用时执行 `su -c sh /data/local/tmp/gl_stage/stage_install.sh` 重新分发
   （脚本会拷贝并按动态取到的 Termux uid chown）；
   **无 root 时**在 Termux 里手动跑（gl_stage 在持久 DE 存储，重启/未解锁也可读）：
   `cp /data/local/tmp/gl_stage/root_ondevice.sh ~/ghostlock/root.sh && chmod 700 ~/ghostlock/root.sh`
3. 核对 `sha256sum ~/ghostlock/root.sh` 与仓库一致后再跑。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `GL_DIR` | `~/ghostlock` | 工具链目录 |
| `GL_SERIAL` | `127.0.0.1:5555` | 本机 adbd 端点 |
| `GL_FIRE_TIMEOUT` | `300` | 单次发枪超时（秒） |
| `GL_MAX_FIRE` | `3` | 发枪最大次数 |
| `GL_BOOT_DELAY` | `120` | 自动模式下等系统负载沉淀的时间（秒） |
| `GL_KEEP_RADIOS` | `0` | 设为 1 则发枪期间不关无线 |

## 安全说明（重要）

- `persist.adb.tcp.port=5555` 会让 adbd **在局域网接口上监听**。本机
  `ro.adb.secure=1`，只有持有白名单密钥（Termux 私有目录里的 `~/.android/adbkey`）
  的客户端能连上，但它毕竟是一个网络可达的 shell 入口。不需要时关掉：

  ```bash
  adb shell "su -c 'setprop persist.adb.tcp.port \"\"; setprop ctl.restart adbd'"
  ```

- `~/.android/adbkey`（私钥）不要导出/分享。
- root 不持久化：**每次开机都要重跑**；同一 boot 内不要重复发枪。
- 本目录内容仅用于你自己的设备，遵守当地法律法规。
