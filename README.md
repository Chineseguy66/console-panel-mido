# mido 屏幕看板 · 迁移备份包

> 版本 **v1.0** ｜ 打包日期 **2026-10-17** ｜ 来源机型 **红米 Note 4X（msm8953 / xiaomi-mido）**
> 适用系统 **Debian 12/13 arm64** ｜ 控制台 **1080×1920（36 列 × 48 行）**

这是一份「拿到就能一键还原整套控制台看板」的完整迁移包。里面是**经过实测验证的成品**，
不是草稿：字体、服务、脚本三者的校验和与生产机完全一致。

---

## 一、包里有什么

```
mido-console-panel/
├── install.sh              ★ 一键恢复脚本（在目标手机上执行）
├── uninstall.sh              卸载 / 回滚脚本
├── MANIFEST.txt              全部文件清单 + 安装路径映射 + 字节数（人看）
├── MANIFEST.sha256           全部文件的 SHA-256（机器校验完整性用）
├── README.md                 本文件
│
├── payload/                  「安装负载」——目录结构就是系统绝对路径的镜像
│   ├── etc/
│   │   ├── default/console-setup              控制台字体前提（FONTFACE=mido / 40x30）
│   │   └── systemd/system/
│   │       ├── battery-panel.service          看板主服务（每 5 秒重画一屏）
│   │       ├── console-font-mido.service     开机给 tty1 套上 30x40 中文点阵字体
│   │       └── screen-idle.service           息屏守护（120 秒无操作关背光，按键唤醒）
│   └── usr/
│       ├── local/bin/
│       │   ├── battery-panel.sh              ★ 看板脚本（预编译版，systemd 实际跑的）
│       │   └── screen-idle.py                息屏守护
│       ├── local/share/consolefonts/
│       │   ├── mido-30x40.psf                自建 PSF2 点阵字体（512 字形 / 30×40 / 含中文）
│       │   └── pua.sed                       汉字→PUA 码位映射表（仅重建字体时用）
│       └── share/consolefonts/
│           └── Uni2-mido40x30.psf.gz         同一个字体的 gz 版，给 console-setup 用
│
├── source/                  可读源码 + 构建工具链（想改看板时用）
│   ├── battery-panel.src.sh  看板**可读源码**（带中文注释，不能直接部署，见 §5.2）
│   ├── mkfont.py             从脚本提取字符集 → 生成 PSF2 字体 + 预编译脚本
│   ├── build.sh              本地一键重建（字体 + 预编译脚本 + 自检预览）
│   ├── term.py               本地终端模拟器：把脚本输出渲染成 PNG 预览
│   ├── mock.sh               假数据桩，让脚本脱离手机也能跑
│   └── deploy.py             推送到手机的脚本（口令从环境变量 MIDO_PASS 读，见 §5.7）
│
├── extras/                  可选件（install.sh 不装，按需手动用）
│   ├── qinglong.service      青龙面板服务（纯净安装 QL 后想加开机包装器时用）
│   └── qinglong-boot         青龙开机包装器（依赖就绪时跳过完整初始化，省 40 秒）
│
└── docs/
    └── images/屏幕看板-参考效果.png   还原成功后应该长这样（通用假数据演示）
```

**看板长什么样**：顶部蓝色标题条（日期 + 时间 + 机主），下面依次是
**电池 / 充电配置 / 系统（CPU·内存·交换·温度·磁盘·进程·运行时长）/ 青龙 / WLAN / 内网穿透** 六个分区，
每个分区是「浅灰底居中标题条 + 标签左对齐·数值右对齐的数据行」。

---

## 二、一键恢复（30 秒上手）

### 步骤 1：把整个包传到手机上

任选一种：

```bash
# 方式 A：scp（包在电脑上时）
scp -r mido-console-panel root@<手机IP>:/root/

# 方式 B：U 盘 / adb push / 任何方式把目录拷进去都行
```

> 路径随意，`install.sh` 会自动识别自己所在目录。

### 步骤 2：在手机上执行

```bash
ssh root@<手机IP>
cd /root/mido-console-panel
chmod +x install.sh uninstall.sh     # 从 Windows 拷过来可能会丢执行位
sudo ./install.sh
```

就这样。脚本会自己完成：**环境检查 → 分辨率检查 → 装依赖 → 备份旧文件 →
部署文件 → 硬件路径自适应 → 启用并启动服务 → 自检**，最后打印一份结果。

### 步骤 3：抬头看屏幕

物理屏幕应该立刻显示整套看板。若没显示：

```bash
echo 0 > /sys/class/graphics/fb0/blank     # 先确认屏幕没被休眠
systemctl restart battery-panel            # 再重画一帧
```

### 想先演练一遍？

```bash
sudo ./install.sh --dry-run      # 只打印会做什么，绝不改系统
```

### 参数速查

| 参数 | 作用 | 什么时候用 |
|---|---|---|
| （无） | 标准安装 | 九成情况 |
| `--dry-run` | 演练，不落盘 | 首次上手想先看看 |
| `--force` | 分辨率不匹配也强上 | 你清楚自己在做什么 |
| `--no-deps` | 跳过 `apt` 装依赖 | 离线环境 / 依赖已自备 |
| `--no-adapt` | 不做硬件路径自适应 | 机型与 mido 完全一致，想原样照搬 |

### 卸载

```bash
sudo ./uninstall.sh
```

会停用并删除 3 个单元与全部看板文件，并尝试还原 `/etc/default/console-setup`。
安装时的备份都在 `/root/mido-panel-backup/<时间戳>/`，卸载**不会**动它们。

---

## 三、依赖

`install.sh` 会自动 `apt` 安装下面这些（`--no-deps` 可跳过）。

**必需**

| 包 | 提供的命令 | 用途 |
|---|---|---|
| `kbd` | `setfont` | 往 tty1 套点阵字体（没有它等于没字库，全是豆腐块） |
| `iproute2` | `ip` `ss` | 取 IPv4 / 网关，判断青龙 5700 端口 |
| `iw` | `iw` | 取 WiFi 信号强度（dBm）与频段 |
| `python3` | `python3` | 跑息屏守护 |
| `mawk`/`gawk` | `awk` | 解析 `/proc/meminfo`、`/proc/net/route` 等 |

**可选（缺了只是对应栏目显示 N/A，不影响其它）**

| 包 | 影响 |
|---|---|
| `console-setup` | tty1~tty6 统一字体；缺了则只有 tty1 有字体 |
| `python3-evdev` | 息屏守护读按键的能力；缺了只能定时息屏、无法按键唤醒 |
| `procps` | `uptime`；缺了「运行时长」栏显示异常 |
| `tailscale` | 「内网穿透」栏有数据；缺了显示「未启用」（正常降级） |

**本包不含**：青龙面板本体、Tailscale 本体。它们是独立应用，看板只是在**读**它们的状态；
没装就在对应栏目显示 N/A，不会报错、不会影响其它分区。

---

## 四、前置条件

| 项 | 要求 |
|---|---|
| 系统 | Debian 12/13 arm64（其它发行版理论可用，但 `apt` 装依赖那步要自己处理） |
| 屏幕 | **控制台分辨率必须是 1080×1920**（见 §5.1，这是硬前提） |
| 环境 | 内核带 framebuffer console（`/dev/fb0` + `/dev/tty1` 存在） |
| 权限 | root |
| 网络 | 首次安装需要（装依赖）；之后看板本身完全离线 |

---

## 五、注意事项

这一节是重点，请务必过一遍。前三条是实际踩过的坑。

### 5.1 【硬前提】屏幕必须是 1080×1920

字体是 **30×40 像素/字** 的定制品，`1080 ÷ 30 = 36 列`、`1920 ÷ 40 = 48 行`，
**看板脚本的栅格常量（第 10 / 19 / 27 / 35 列等锚点）就是按 36 列写死的**。

* 分辨率≠1080×1920 → 字符格数不整除 → 画面错位、留黑边；`install.sh` 会**直接报错停下**
  （除非你加 `--force`，但那只是让它继续，画面照样是错的）。
* **换到别的分辨率的手机，正确做法是重建字体 + 改栅格常量**，不是加 `--force`：

  1. 改 `source/mkfont.py` 里的 `CANDIDATES = [(30, 40)]`，换成能整除新分辨率的一对
     （例如 720×1280 可用 `(20, 40)` → 36 列 × 32 行）；
  2. 改 `battery-panel.src.sh` 里所有依赖列宽的常量（`GW_*`、`G_V*`、`G_LR`、`G_L2`、
     `RULE_H` 长度、`CSI G` 的列号），以及总行数注释里的分区行数分配（48 行）；
  3. 跑 `bash source/build.sh` 重建，用 `term.py` 生成预览确认不错位；
  4. 再用 `deploy.py` 推上去。

  这属于「改造」而非「迁移」，工作量取决于新分辨率，别指望一键。

### 5.2 【重要】部署出去的看板脚本是「预编译」的，**不要直接编辑**

`/usr/local/bin/battery-panel.sh`（即 `payload/usr/local/bin/battery-panel.sh`）里：

* 所有**汉字已被替换成 PUA 私有区码位**（映射表就是 `pua.sed`），因为 512 字形的点阵字体
  只包含脚本实际用到的那些字，靠码位直映射才能显示中文；
* 你直接 `vim` 改它 → 写进去的汉字**没有对应字形** → 屏幕上变成空白/方块。

**要改内容，改 `source/battery-panel.src.sh`（可读源码），然后重建：**

```bash
# 前提：Windows（需要 consola.ttf 与 msyh.ttc）+ Python3 + Pillow
cd source
python -m pip install pillow
bash build.sh                 # 生成字体 + 预编译脚本 + 本地自检预览
# 预览图：../preview/preview_latest.png，先在这里确认视觉正确
```

`build.sh` 会重新生成 `mido-30x40.psf`、`Uni2-mido40x30.psf.gz`、`pua.sed` 和预编译版脚本。
**注意**：新增汉字可以（会自动进字体），但**新增字形会占用字体槽位** ——
字体已用 512 个字形，如果新字符超出容量，`mkfont.py` 会把尺寸升级到需要更大字形数的版本
（观察生成后的「字形数」）；极端情况下会顶到 PSF 上限。原来是刻意控制在 512 以内的。

**在电脑上不接手机也能预览**（推荐先这样验证）：

```bash
cd source
PANEL_MOCK=mock.sh PANEL_ONCE=1 bash battery-panel.src.sh /tmp/frame.txt
python term.py /tmp/frame.txt 30 40 preview     # → preview/preview.png
PANEL_MOCK=mock.sh PANEL_MOCK_ALERT=1  PANEL_ONCE=1 bash battery-panel.src.sh /tmp/a.txt   # 高负载告警态
PANEL_MOCK=mock.sh PANEL_MOCK_WIFI=0 PANEL_MOCK_TS=0 PANEL_ONCE=1 bash battery-panel.src.sh /tmp/d.txt  # 降级态
```

### 5.3 【重要】`/tmp` 是内存盘，千万不要用 `bash -x` 常驻调试

嵌入式 Debian 上 `/tmp` 通常是 **tmpfs（占内存）**。整个脚本开 `bash -x` 跑一帧会产生
**3 万多行**调试日志；写到 `/tmp` 就是往内存里灌，会**直接把内存打满**，然后内核发 SIGTERM 杀进程 ——
看起来就像「看板脚本内存泄漏把机器搞爆了」，其实是被日志撑爆的。

规矩：

* 排查问题用 `bash -x`，**但重定向到磁盘**：`bash -x /usr/local/bin/battery-panel.sh /dev/null 2>/var/log/xlog`；
* 排查完**立刻删掉**日志文件和临时文件；
* **正式运行永远不要带 `-x`**（systemd 单元里本来也没有，别手贱加）；
* 需要局部调试就分段 `set -x` / `set +x`，不要全局开；
* 脚本自己的自检输出也写磁盘：`install.sh` 用的是 `/root/.mido-panel-selftest.txt`，不是 `/tmp`。

### 5.4 硬件路径自适应（换机后能活多少）

`battery-panel.sh` 里原本写死了 mido 这套骁龙 8953 的节点名。`install.sh` 会**自动探测并改写**：

| 项目 | 原值（mido） | 自适应方式 |
|---|---|---|
| 电池节点 | `/sys/class/power_supply/qcom-battery` | 扫 `power_supply/*/type`，取第一个 `type=Battery` |
| 充电器节点 | `/sys/class/power_supply/qcom-smbchg-usb` | 取第一个 `type=USB` 或 `Mains` |
| 无线网卡 | `wlan0` | 扫 `/sys/class/net/*/wireless` |
| 背光路径 | `/sys/class/backlight/backlight/brightness` | 取 `/sys/class/backlight/` 下第一个 |
| 亮屏亮度 | `BRIGHT_ON = 2048` | **只在下调时改**：若本机 `max_brightness` 小于 2048 才压到上限，否则保持 2048 |
| 待监控按键 | `gpio-keys` `pm8941_pwrkey` `pm8941_resin` `ft5x06` | 见下 |

**输入设备的处理有个细节值得说明**：`screen-idle.py` 是按**子串**匹配设备名的
（`if any(k in dev.name ...)`），所以源机上的 `"ft5x06"` 实际匹配的是真机名
`generic ft5x06 (3b)`。因此 `install.sh` 采取「最小改动优先」策略：

* **原配置在本机全部仍能命中 → 一个字都不改**。源机就是这种情况，还原后 `WATCH_NAMES`
  与原来完全一致（4 个词，含 `ft5x06`）。
* **有词失效了（换机）→ 用「仍有效的旧词 + 本机新认出来的交互设备」重建**
  （新词按 key/pwr/touch/haptic/jack 等关键字挑，并跳过已被现有词覆盖的）。

认不出来就保持原样并给警告。这样在源机上是零改动，换机时又能自动适配。

**亮屏亮度刻意不调高**：源机的 2048 是调过的（够亮、不过热、不费电），
而这块屏的 `max_brightness` 是 4095；盲目取上限会让屏幕更亮更热更费电。
所以只在「本机上限比 2048 还低」时才压下来。觉得偏暗/偏亮就手改
`/usr/local/bin/screen-idle.py` 里的 `BRIGHT_ON`（0 ~ max_brightness），再
`systemctl restart screen-idle`。

改之前原文件会另存为 `*.preadapt`。**看板脚本和源码版会同步改写**，保持一致。

**自适应也没救的部分**（换机后这些字段大概率显示 N/A，属正常）：

* **充电配置**（恒流上限 / 输入限流 / 截止电流）—— 读的是高通充电 IC 私有节点
  （`constant_charge_current_max` / `input_current_limit`），非高通平台没有这套节点；
* **电池的电压 / 电流 / 功率 / 温度 / 健康** —— 依赖节点名与字段名，非骁龙平台命名不同；
* **CPU 主频 / 温度区** —— `cpu0/cpufreq` 与 `/sys/class/thermal` 是通用接口，一般能读到；
  但「最高温度」是取所有 zone 的最大值，含义随平台而变。

想彻底适配某台新机，就对照 `battery-panel.src.sh` 的「数据源」小节改路径，再 `build.sh` 重建。

### 5.5 字体是「两套路径」加载的，别只装一套

| 加载方式 | 文件 | 由谁负责 |
|---|---|---|
| 直接给 tty1 套字体 | `/usr/local/share/consolefonts/mido-30x40.psf` | `console-font-mido.service`（`setfont -C /dev/tty1`） |
| 系统级控制台字体 | `/usr/share/consolefonts/Uni2-mido40x30.psf.gz` | `console-setup.service`（读 `/etc/default/console-setup` 的 `FONTFACE=mido` `FONTSIZE=40x30`） |

两者**内容必须一致**（同一个字体的未压缩 / gz 形式）。文件名不能随便改：
`console-setup` 按 `Uni2-<FONTFACE><FONTSIZE>.psf.gz` 的规则找文件。

**看板真正依赖的是第一套**（`console-font-mido.service`）；第二套是让 tty1~tty6 统一字体。
如果目标机不装 `console-setup`，看板照样正常，只是 `/etc/default/console-setup` 这份配置没用。

### 5.6 服务顺序与被遮挡的登录提示符

* `console-font-mido.service` 里写了 `After=console-setup.service` + `Before=battery-panel.service`，
  保证**先有字库，再画看板**。这个顺序不能乱，否则第一帧会用错字体渲染。
* `getty@tty1.service` 默认是开着的，占着同一个 tty1。看板每帧都先清屏再画，所以**看不到登录提示符**，
  属于正常现象 —— 但如果你需要 tty1 的登录界面，那就要在看板和服务之间做个取舍。
* 可选加固：如果这台机器不需要在 tty1 上敲命令，建议
  `systemctl disable --now getty@tty1`，少一个进程抢 tty，行为更干净。

### 5.7 `source/deploy.py` 的连接参数从环境变量读

`source/deploy.py` 是**改完脚本之后推送用的**本机工具，不参与安装流程 —— `install.sh` 完全不需要它。
它的 `HOST / USER / PASS` 都从环境变量读，默认值只是占位示例：

`MIDO_HOST=192.168.1.x MIDO_PASS=你的口令 python deploy.py`

更彻底一点：改用 SSH 密钥登录并去掉密码认证。

### 5.8 看板本身的开销

* 单帧 CPU ≈ **0.265 s**（8 核 A53，即整机约 0.036%），常驻内存 ≈ **1.5~2.8 MB**；
* 刷新间隔 5 秒，每帧都会 fork 若干外部命令（`awk` / `ip` / `iw` / `df` 等）；
* **不要在低端机上把刷新间隔调到 1 秒以下** —— 瓶颈全在 `fork+exec`，
  8 核 A53 上 fork 一次约 10~15 ms，间隔太短会明显吃 CPU。
* 内存泄漏自查：`systemctl show -p NRestarts --value battery-panel` 长时间应为 0，
  `awk '/VmRSS/{print $2,$3}' /proc/$(systemctl show -p MainPID --value battery-panel)/status` 应稳定在几 MB。

### 5.9 换机 / 拷贝时的小坑

* **保持 LF 换行**：`install.sh`、`uninstall.sh`、`battery-panel.sh`、`screen-idle.py`、
  systemd 单元文件都必须是 LF。在 Windows 上编辑后如果变成 CRLF，
  `install.sh` 会报 ``bash: $'\r': command not found``、systemd 会报单元解析失败。
  修：`sed -i 's/\r$//' <文件>` 或 `dos2unix <文件>`；
* **执行位**：从 Windows 拷过来的 `install.sh` 可能没有 `+x`，先 `chmod +x install.sh uninstall.sh`；
* **`fb0` 编号**：个别平台是 `/dev/fb1` 或 `/sys/class/graphics/fb1`。
  如果 `install.sh` 报「读不到帧缓冲分辨率」，把命令里的 `fb0` 换成实际编号即可（脚本里也可以改）。

---

## 六、验证是否还原成功

对照 `docs/images/屏幕看板-参考效果.png` 看物理屏幕，应满足：

1. **满屏 48 行**，四周有圆角边框（`╭ ╮ ╰ ╯`），没有黑边、没有错位；
2. **汉字正常显示**（不是方块、不是空白）→ 说明字体套对了；
3. **日期行是黑底亮字**，第二行没有继承蓝色背景；
4. **六个分区标题条居中**，数据行「标签左对齐、数值右对齐」，数字位数变化时整行不跳；
5. **颜色语义正确**：绿色=正常/运行/已接入、黄色=告警（内存高/温度高/信号差）、红色=异常/断开，正常数值是白色。

命令行侧的检查：

```bash
systemctl status battery-panel console-font-mido screen-idle   # 三个都该是 active
PANEL_ONCE=1 /usr/local/bin/battery-panel.sh /root/one.txt     # 渲染一帧
wc -l /root/one.txt                                            # 约 47~48 行
tr -cd '\n' < /root/.mido-panel-selftest.txt | wc -c           # install.sh 留下的自检帧
```

---

## 七、常见问题排查

| 现象 | 原因与处置 |
|---|---|
| 屏幕全黑，但服务是 active | 屏幕被休眠：`echo 0 > /sys/class/graphics/fb0/blank`。若装了息屏守护，按一下电源/音量键唤醒 |
| 汉字变成方块 / 空白 | 字体没套上。`setfont -C /dev/tty1 /usr/local/share/consolefonts/mido-30x40.psf` 手动套一次；再看 `journalctl -u console-font-mido` |
| 汉字变成方块，但手动 setfont 后正常 | 开机顺序问题：确认 `console-font-mido.service` 是 enabled，且 `Before=battery-panel.service` 还在 |
| 画面错位、右边框跑到屏幕外 | 分辨率不是 1080×1920（见 §5.1）。核对 `cat /sys/class/graphics/fb0/virtual_size` |
| 电池栏全是 N/A | 电池节点没认对。核对 `ls /sys/class/power_supply/` 与脚本里的 `BATT=`；或用 `--no-adapt` 之外的方式手工改 |
| WLAN 栏显示「未开启」 | 网卡名不是 `wlan0` 或没连网。核对 `ls /sys/class/net/*/wireless`，以及脚本里 `wlan0` 是否被替换成了实际名 |
| 「内网穿透」显示未启用 | 没装 Tailscale 或没登录，正常降级 |
| 青龙栏显示未运行 | 没装青龙，正常降级；装了则 `systemctl status qinglong` |
| `install.sh` 报 `$'\r': command not found` | 行尾是 CRLF，见 §5.9 |
| 服务反复重启（`NRestarts` 一直涨） | `journalctl -u battery-panel -n 50 --no-pager` 看报错；常见是 `/dev/tty1` 不存在或脚本被改坏（§5.2） |
| 内存突然被打满、进程被 SIGTERM | 检查是不是有人在跑 `bash -x` 且日志写到了 `/tmp`（§5.3）。`rm -f /tmp/*.log /tmp/xlog`，`df -h /tmp` 确认是 tmpfs |
| 改完脚本没生效 | 只改了 `battery-panel.src.sh` 是没用的，**预编译版才是 systemd 跑的**（§5.2）。改完要 `build.sh` 重建并重新部署，然后 `systemctl restart battery-panel` |

---

## 八、想改看板怎么办

```bash
# 1) 改源码（可读版）
vim source/battery-panel.src.sh

# 2) 电脑上预览，别一上来就上真机
cd source
PANEL_MOCK=mock.sh PANEL_ONCE=1 bash battery-panel.src.sh /tmp/f.txt
python term.py /tmp/f.txt 30 40 preview     # → preview/preview.png

# 3) 重建字体 + 预编译
bash build.sh

# 4) 推到手机（先改 deploy.py 里的 IP/账号，见 §5.7）
python deploy.py
```

`deploy.py` 会把 4 个文件推到位并重启服务、顺带做验证：
`mido-30x40.psf`、`Uni2-mido40x30.psf.gz`、`pua.sed`、预编译脚本 → `/usr/local/bin/battery-panel.sh`，
同时把源码备份成 `/usr/local/bin/battery-panel.src.sh`。

---

## 九、源码怎么读

`source/` 里是全部可读源码，关键设计都写在注释里：
青龙在手机上的部署与开机加速、控制台字体的程序化绘制（为什么圆角边框要自己画）、
排版栅格的设计与实测、性能优化前后对比（**同一视效下比初版省 45% CPU**）、
以及一路上踩过的所有坑（`/tmp` tmpfs 内存打满、glob 的 `*` 不是量词导致 ANSI 剥离吞串、
终端 SGR 属性传染导致第二行继承蓝底、变量「先算 A 再用 A 算 B」的顺序 bug……）。

**建议先看 `source/battery-panel.src.sh` 文件头的「排版约定」和「全局栅格」，再看正文。**

---

## 十、文件校验

```bash
sha256sum -c MANIFEST.sha256     # 校验全部文件未被改动/未损坏
```

`MANIFEST.txt` 里还有每项的路径映射（包内路径 → 系统安装路径）与字节数。
