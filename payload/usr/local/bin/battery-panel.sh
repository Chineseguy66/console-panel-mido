#!/bin/bash
# ============================================================================
# ⚠ 本文件由 tools/mkfont.py 自动生成（PUA 预编译版），请不要直接改这里。
#
#   源码:  battery-panel.src.sh   <-- 要改文案/布局改这个
#   重建:  在笔记本上跑 tools/build.sh（会同时重生成字体和本文件）
#
#   编译期做了什么：把源码里的汉字换成 U+F000..U+F1FF 的「直接字形索引」码点。
#   内核把 CJK 当双宽字符（占 2 格但只画左半格），换成这类码点后宽度变 1 格，
#   中文就能像英文一样紧凑。好处是运行期不再需要 sed 过滤。
#   ⚠ 字符集变化时必须重建字体 + 本文件，否则新字会变成方块。
# ============================================================================
# ============================================================================
# mido 系统看板 —— 每 60 秒刷新到指定 TTY
#
# 用法: battery-panel.sh [tty路径]
#
# ★ 这是「源码版」，可以直接在手机上跑（需要 pua.sed 做运行期过滤）。
#   部署到 systemd 的是 mkfont.py 生成的「预编译版」：
#   汉字在编译期就换成 PUA 码点，运行期不再需要 sed 过滤。
#
# 关于中文显示（重要，改之前先读）:
#   内核把 CJK 当「双宽」字符：光标前进 2 格、但字形只画左边 1 格，
#   右边留空，于是中文看起来又稀又像竖排。
#   解决办法是把汉字换成 U+F000..U+F1FF 区间的「直接字形索引」码点
#   （内核 consolemap.c: UNI_DIRECT_BASE/UNI_DIRECT_MASK），
#   这类码点宽度为 1 格，内核直接拿 (码点-0xF000) 当字形槽位号画图，
#   于是汉字变成紧凑的 1 格宽 —— 和英文一样密。
#
#   ⚠ 改了文案（新增汉字）必须重新跑一次 mkfont.py：
#     它会重生成字体 + pua.sed + 预编译脚本，否则新字会掉成方块。
#
#   ⚠ 图形符号只能用这几个（微软雅黑里确实有的）：●○◆◇■□▲▼§↑↓←→±×÷°·
#     ✓✗▸▾⚡ 这类雅黑里没有，会渲染成「豆腐块」，别用。
#
# 排版约定:
#   屏幕 36 列 × 48 行（1080x1920 像素 ÷ 30x40 的格子）。
#   第 1 列 = 左边框，第 2..35 列 = 内容（34 格），第 36 列 = 右边框。
#   **整屏必须正好 48 行**：多一行就滚屏，少一行底部留白。
#
#   ★ 全局栅格（2026-10-17 统一）：所有内容行共用一套**固定列锚点**，
#     标签永远左对齐、数值永远右对齐，位数变化时整行不左右跳动：
#
#        列 1 │  2 空格  3..8 L1(6)  9 空格  10..18 V1(9)
#             19 空格  20..25 L2(6) 26 空格  27..35 V2(9)  36 │
#
#     · row2   双字段行（标签+数值 各两组）
#     · row1   单字段行，数值右对齐到第 35 列（IPv4/网关/SSID/供电类型等长值）
#     · kvrow  三段行：标签 + 值（右对齐到 18）+ 右组（右对齐到 35，占 19..35）
#     · rowlr  页眉第二行：左文从第 3 列起，右文右对齐到第 35 列
#     · bar_ctr 分区标题条，标题在 34 格内容区里**居中**
#
#   ⚠⚠ 这几个原语的入参是「**颜色码 + 纯文本**」**成对**给的，不是拼好的彩色串。
#     因为宽度只数纯文本的字符数 —— 一旦把带 ANSI 转义的串丢进来量宽度，
#     就得逐段剥转义，实测每帧多花 38 ms（见「显示宽度」小节的说明）。
#     标签则靠 `CSI G` 绝对跳列定位，连标签宽度都不用算。
#
#   分区行数预算（改 layout 前后都对一遍，合计必须 = 48）:
#     页眉 4 │ 电池 8 │ 充电 7 │ 系统 10 │ 青龙 5 │ WLAN 9 │ 穿透 5
#
# ══ 调试规矩（2026-10-17 踩坑）════════════════════════════════════════
#   ⚠ **不要**对整份脚本全局开 `bash -x`。本脚本 800+ 行，一次执行会产生
#     上万行追踪；而嵌入式 Debian 里 `/tmp` 是 **tmpfs（内存文件系统）**，
#     日志直接吃内存 —— 一不留神就把内存打满，进程被 SIGTERM 杀掉，
#     看上去像「看板脚本内存泄漏 / 内存爆满」，其实是调试输出干的。
#   规矩：
#     1. 调试日志写到磁盘目录（如 /var/log/xlog），**不要写 /tmp**；
#     2. `bash -x` 只用于临时排障，生产 unit 的 ExecStart **绝不带**；
#     3. 需要追踪时用局部 `set -x` 包住可疑的几行，别全局开。
#   （本次就是这么被误导过：屏幕上的「内存 100%」一度被怀疑是调试搞的，
#     后来在真机上单独复现才定位到是 snap_mem 的提前 break 逻辑错误。）
#
# 实机实测的终端能力（决定了下面为什么这么写）:
#   * CSI n G（绝对列）、CSI K（擦到行尾）、SGR 1/2/7 都支持。
#   * SGR 1 -> 白 255，SGR 2 -> 灰 85，正常 -> 灰 170（16 色里没有更亮的白底）。
#   * **CSI K 用的是「当前背景色」**：所以 `ESC[47m` + `ESC[K` 能把整行
#     铺成浅灰底（标题条就是这么做的，不用自己算 padding）。
#     但反显（SGR 7）不参与擦除 —— 内核是渲染时才做反显 —— 所以
#     `ESC[7m` + `ESC[K` 铺不满，只剩一小截「标签块」。
#   * 也正因为 CSI K 带底色，条内改颜色只能用 `ESC[3xm`（只改前景），
#     不能用 `ESC[0m`，否则底色会被一起清成黑。
#
# ══ 超时策略（防「某条命令卡住 → 整个刷新循环卡死」）══════════════════
#   实测：8 核 A53 上 fork+exec 一次 ~6.5ms，所以不能无脑给每条命令套
#   timeout（那样开销翻倍）。分三类处理：
#
#   ① 内核 sysfs / procfs 单值读取  ->  rdv / ts_alive
#      用 bash 内建 `read -t N` 自带超时，**零 fork**，
#      实测只比 `$(<file)` 贵 0.011ms，等于白送。
#
#   ② 会碰网络栈 / 守护进程 / 文件系统 / 控制台的外部命令  ->  to
#      一律 `timeout N` 包住，卡住就返回空（实测只贵 2.0ms/条）。
#      覆盖：iw、ip、ss、df、date、uname、wpa_cli、tailscale、setfont
#
#   ③ 纯算术过滤（awk/sed/tr/grep 处理已经拿到的字符串）
#      不涉及 IO，不可能阻塞，不套超时（套了纯属浪费 fork）。
#
#   另外还有 BUDGET（单次刷新总预算）：每轮开始把 bash 内建秒表 SECONDS
#   归零，to() 每次先看还剩多少秒，超预算就直接返回空，不再执行命令。
#   于是即使整条链路都在卡，单轮外部命令的总阻塞也有硬上限。
#
#   ⚠ tailscale 单独说：不能直接无脑调 `tailscale status` ——
#     未登录 / 服务没起来时，部分版本会阻塞等网络。所以：
#
#       第 1 步（零 fork，7ms）：扫 /proc/net/unix，看 tailscaled 的控制
#         socket 有没有被**绑上**。比 `-S socket文件存在` 更准（进程崩溃后
#         socket 文件会残留），比扫 /proc/*/comm 便宜（7ms vs 20ms）。
#         → socket 不在：**直接判【未启用】，一条 tailscale 命令都不调**。
#
#       第 2 步（socket 在才做）：`timeout 1 tailscale status`，**解析输出**。
#
#     ⚠ 边界（重要，别搞混）：socket 存在只能说明**守护进程起来了**，
#       不能说明「已登录 / 隧道通」。典型场景：tailscaled 正常跑着但没登录，
#       这时 socket 在、却没有隧道 IP。所以第 2 步必须以
#       「**解析出来的首个字段是不是 IPv4**」为准：
#         有 IP      -> 已登录且拿到了地址 -> 启用中 + 显示该 IP
#         没有 IP    -> 输出是 "Logged out." / "Tailscale is stopped." 之类
#                      -> 未启用 + 地址「无」
#       命令本身不可用 / 超时（完全没输出）时才退回接口地址兜底。
#       至于「隧道是否真能连通对端」在本地是判不出来的，本栏不做承诺。
#
# ══ 异常兜底（任何一项采集失败都不许影响其它面板）════════════════════
#   原则：**采集失败 = 显示 N/A，绝不中断本轮渲染**。
#   ① `to()`   ：超时 / 报错 / 无返回 一律返回空字符串（stderr 也丢掉）。
#   ② `rdv()`  ：文件不存在 / 不可读 / 读超时 一律留空。
#   ③ `san()`  ：所有参与算术的值先过一遍整数校验，非数字退回默认值，
#                避免 `$(( ))` 收到空串或乱码直接报错。
#   ④ 整帧先拼好再落盘（frame=$(screen)）：万一某一节渲染中途出错，
#      本轮就不刷新，保留上一帧完整画面，而不是把屏幕画成半截。
#   ⑤ 服务单元是 Restart=always / RestartSec=5，脚本万一真挂了 5 秒后自愈。
#   ⑥ `iw` 有个坑：**命令失败也返回 rc=0**（例如 "No such device"），
#      所以判断只能靠「解析出来的字段是否为空」，不能看退出码。
#      而且不是所有网卡/驱动都报 freq / signal —— 读不到就显示 N/A。
#   ⑦ 采集函数统一写全局变量（不 echo），既省 fork，也天然不会被
#      「管道里某一段失败」污染输出。
# ============================================================================
TTY="${1:-/dev/tty1}"
FONT=/usr/local/share/consolefonts/mido-30x40.psf
# 预编译版由生成器把下面这行改成 PUA_SED=""（空 = 不再过滤，屏幕上已是紧凑字）
PUA_SED=""  # cleared by generator: precompiled, no runtime filter

# ⚠ 宽度计算要「按字符数」而不是「按字节数」：bash 只在 UTF-8 locale 下
#   才这么算（C locale 下 "中文" 会被算成 6）。实测本机有 C.utf8。
export LC_ALL=C.utf8

# 套用大号中文字体（字体不存在时保持系统默认，不影响使用）
[ -c "$TTY" ] && [ -f "$FONT" ] && timeout 3 setfont -C "$TTY" "$FONT" 2>/dev/null

COLS=36
INNER=$((COLS - 2))          # 34

# ---------- 超时 ----------
TO_SYSFS=1        # 内核 sysfs/procfs 单值（read -t，零 fork）
TO_DEV=2          # iw / ss / ip：要问内核网络栈
TO_DAEMON=2       # wpa_cli：要跟守护进程通话
TO_TS=1           # tailscale status：未登录时可能阻塞等网络，给 1 秒就够
TO_FS=3           # df：碰文件系统
TO_MISC=2         # date / uname / setfont
BUDGET=15         # 单次刷新的外部命令总预算（秒）

to() {            # to <期望超时秒> <命令...>；超预算或命令卡住都返回空
  local w=$1 left
  shift
  left=$(( BUDGET - SECONDS ))
  [ "$left" -lt 1 ] && return 0
  [ "$w" -gt "$left" ] && w=$left
  timeout "$w" "$@" 2>/dev/null
  return 0
}
# 本次 sysfs 读取该给几秒
_to_sys() {
  local t=$(( BUDGET - SECONDS ))
  [ "$t" -gt "$TO_SYSFS" ] && t=$TO_SYSFS
  [ "$t" -lt 1 ] && t=1
  printf -v _TO "$t"
}
# 读一个内核文件到变量：不存在 / 不可读 / 超时 一律留空，**零 fork**
rdv() {
  local v=""
  printf -v "$1" '%s' ''
  [ -r "$2" ] || return 0
  _to_sys
  read -t "$_TO" -r v < "$2" 2>/dev/null
  printf -v "$1" '%s' "$v"
  return 0
}
# 整数校验：非数字（空串 / 乱码 / 多负号）就退回默认值，防止 $(( )) 报错中断
# 用法: san "$原值" 目标变量 [默认值=0]
san() {
  case "$1" in
    '' | '-' | *[!0-9-]*) printf -v "$2" '%s' "${3:-0}" ;;
    *?*-*)                printf -v "$2" '%s' "${3:-0}" ;;
    *)                    printf -v "$2" '%s' "$1" ;;
  esac
}

# ---------- 终端控制 ----------
E=$'\033'
# _dw 要抹掉「ESC [ 参数 终结字母」这种转义。glob 没有量词，`[0-9;]*` 里的 `*`
# 是「任意字符串」而不是「重复前一项」，贪婪起来会把整串吞掉 —— 所以必须开 extglob
# 用 `+([0-9;])` 表示「一个或多个参数字符」。开一次，全局生效。
shopt -s extglob
N="${E}[0m"          # 全部复位
DIM="${E}[2m"        # 暗（次要信息）
BLD="${E}[1m"        # 亮（数值）
RD="${E}[2m"         # 外框/分隔线：暗色，别抢内容的注意力
CLR="${E}[2J${E}[H"  # 清屏 + 光标归位
# 框线字符（圆角外框由 mkfont.py 程序化画四分之一圆弧，和 ─ │ 无缝衔接）
VB=$'│'
TL=$'╭'; TR=$'╮'; BL=$'╰'; BR=$'╯'
NL=$'\r\n'
RC="${E}[36G"                             # 跳到第 36 列
BG="${E}[36G${VB}${NL}"                   # 行尾：右框 + 换行
END="${E}[36G${BR}${E}[1;1H"              # 末行：右下角 + 光标归位（不换行，避免滚屏）
EK="${E}[K"                               # 擦到行尾（用当前背景色填充！）

# 条内只改前景色的转义（不能用 $N，否则会把条底色清掉）
F_K="${E}[30m"   # 黑字（浅色条上的正文）
F_W="${E}[97m"   # 白字（深色条上的正文）
F_R="${E}[31m"   # 红
F_G="${E}[32m"   # 绿
F_Y="${E}[33m"   # 黄
F_C="${E}[36m"   # 青

HC="${E}[44;97m"  # 页眉条：蓝底白字
SC="${E}[47;30m"  # 分区条：浅灰底黑字

# ══ 状态配色：全屏**只有这一套语义**，别在别处另起炉灶 ═════════════════════
#   绿 = 正常 / 运行 / 已接入 / 充电中
#   黄 = 告警（温度偏高、内存高、信号一般或弱……）
#   红 = 异常 / 断开 / 故障 / 未运行
#   白（BLD）= 普通数值，不上色 —— 「不要大面积上色」，只有值得盯的项才给颜色
OK_C="$F_G$BLD"; WARN_C="$F_Y$BLD"; ERR_C="$F_R$BLD"

RULE_H=""
for ((i = 0; i < INNER; i++)); do RULE_H+="─"; done

# 圆角外框：顶部 ╭───╮，分隔 ├───┤，底部 ╰───╯（全部用暗色 $RD，不抢内容）
rule_top() { printf '%s%s%s%s' "${RD}${TL}${RULE_H}" "$RC" "${RD}${TR}${Z}" "$NL"; }
rule_mid() { printf '%s%s%s%s' "${RD}├${RULE_H}" "$RC" "${RD}┤${Z}" "$NL"; }
rule_bot() { printf '%s%s%s%s' "${RD}${BL}${RULE_H}" "$RC" "${RD}${BR}${Z}${E}[1;1H"; }

# ---------- 显示宽度（含 ANSI 转义时按可见格数算）----------
# ⚠ 这是渲染里最热的函数。两条实测经验：
#   坑 1：glob 里 `*` 是「任意字符串」而不是量词。写成 `[0-9;]*[A-Za-z]` 就是
#         「一个参数字符 + 任意串 + 一个字母」，贪婪匹配会从第一个 ESC 一路吞到
#         最后一个字母，把整串抹成空。正确写法要用 extglob 的 `*(...)`。
#   坑 1b：必须是 `*([0-9;?])`（**零个**或多个）而不是 `+([0-9;])`。
#         后者要求至少一个参数，于是 `ESC[K`（擦到行尾）`ESC[H`（光标归位）这种
#         **无参数 CSI** 匹配不上，会残留成 3 个可见字符 —— `bar_ctr` 的标题条宽度
#         就会多算 3 格、把居中算歪。实测就是靠这个 37 ≠ 34 抓出来的。
#   坑 2：别用 local。实测每次 local ≈ 25 us，4 个就是 100 us，比替换本身还贵。
#   还有：先把 ESC 换成 \001（正文里不可能出现的字节），这样 `\001[` 只可能是转义头。
# 纯 bash，零 fork，结果放 $_DW。
# LC_ALL=C.utf8 下 ${#} 数的是**字符**：ASCII 1 字符 = 1 格，预编译后的汉字是 1 个
# PUA 码点也是 1 字符 = 1 格，正好等于显示宽度（所以 %-*s 按字节算宽度是错的）。
_dw() {
  case "$1" in
    *"$E"*) ;;
    *) _DW=${#1}; return 0 ;;                # 快路径：无转义，字符数即格数
  esac
  _DW="${1//$E/$M1}"
  _DW="${_DW//$M1\[*([0-9;?])[A-Za-z]/}"
  _DW=${#_DW}
}
M1=$'\001'

blank() { printf '%s%s' "$VB" "$BG"; }

# ══ 全局栅格（见文件头「全局栅格」）════════════════════════════════════
# 列锚点（1-based 可见列号）：
#   [1] 左边框 │ [2] 留空 │ [3..8] 标签1(6格) │ [10..18] 值1(9格)
#   [19] 分隔 │ [20..25] 标签2(6格) │ [27..35] 值2(9格) │ [36] 右边框
#
# ⚠ 关键：标签靠 CSI G **绝对定位**，不补空格、也不需要量宽度 —— 标签写多长都
#   不会影响后面的列；数值右对齐补左空格时只数**纯文本**的字符数（C.utf8 下 ${#}
#   按字符，预编译后的汉字/PUA 正好 1 字符 = 1 格）。于是宽度测量彻底离开热路径，
#   ANSI 转义也不用解析。结果就是「标签左对齐、数值右对齐、占位固定」，
#   数值位数变化时整行不会左右跳动。
GW_V=9                                   # 值字段宽（值1 / 值2）
GW_V1=9; GW_L1=6; GW_L2=6; GW_V2=9       # 兼容旧引用（fit 用 GW_V1）
GW_VF=26                                 # 单字段行的值宽：第 10..35 列
GW_RG=17                                 # 三段行右组宽：第 19..35 列（值1 占 10..18）
GW_LR=16                                 # 页眉右组宽：第 20..35 列
G_V1="${E}[10G"; G_L2="${E}[20G"; G_V2="${E}[27G"
G_VF="${E}[10G"; G_LR="${E}[20G"; G_RG="${E}[19G"

# 生成 n 个空格（结果在 $_SP）。printf 的 '%*s' 是内建，实测 26 us/次，
# 和「空格池 + 子串截取」的 25 us/次几乎一样，但不用维护全局池、也不用 local。
_sp() { printf -v _SP '%*s' "$1" ''; }        # 调用方保证 $1 >= 0

# 值的左补空格（右对齐用）：<目标变量> <纯文本> <字段宽>，结果写进 $1 指定的变量。
# 传进来的必须是不含 ANSI 的纯文本（这样 ${#} 就是显示宽度）。
fp() {
  if [ "$3" -le "${#2}" ]; then printf -v "$1" '%s' ''
  else printf -v "$1" '%*s' "$(( $3 - ${#2} ))" ''; fi
}

# 字段超宽兜底：值超过字段宽就截断（结果写进 $1 指定的变量）。
# ⚠ 不截断的后果不是「难看」，而是**溢出到第 36 列、吃掉右边框，甚至触发换行滚屏**
#   ——「滚屏就毁了」是这块屏的硬约束。而数值只在特定数据下才变长
#   （内存 10240/16384、Tailscale IP 多两位、磁盘 100G 以上…），源机上永远碰不到，
#   换台设备就翻车。所以每个字段在补齐前都过一次这个闸。
# 纯内建，正常路径只有一次整数比较，零 fork。
fitv() {
  if [ "${#2}" -gt "$3" ]; then printf -v "$1" '%s' "${2:0:$3}"
  else                           printf -v "$1" '%s' "$2"; fi
}

# 双字段行：标签左对齐 + 数值右对齐（数值位数变化时整行不跳动）
#   <标签1色> <标签1> <值1色> <值1> <标签2色> <标签2> <值2色> <值2>
row2() {
  fitv _V1 "$4" "$GW_V"; fitv _V2 "$8" "$GW_V"
  fp _PA "$_V1" "$GW_V"; fp _PB "$_V2" "$GW_V"
  printf '%s %s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s' \
    "$VB" "$1" "$2" "$G_V1" "$_PA" "$3" "$_V1" "$Z" \
    "$G_L2" "$5" "$6" "$G_V2" "$_PB" "$7" "$_V2" "$Z" "$BG"
}

# 单字段行：标签左对齐，值右对齐到第 35 列（IPv4 / 网关 / SSID 这类长值）
#   <标签色> <标签> <值色> <值>
row1() {
  fitv _V1 "$4" "$GW_VF"
  fp _PA "$_V1" "$GW_VF"
  printf '%s %s%s%s%s%s%s%s%s' "$VB" "$1" "$2" "$G_VF" "$_PA" "$3" "$_V1" "$Z" "$BG"
}

# 三段行：标签 + 值（右对齐到第 18 列）+ 右组（右对齐到第 35 列）
#   <标签色> <标签> <值色> <值> <右组色> <右组>
# 右组字段比值字段宽（17 > 9），用于「定级 + 数值」这种要连读的右半段。
kvrow() {
  fitv _V1 "$4" "$GW_V"; fitv _V2 "$6" "$GW_RG"
  fp _PA "$_V1" "$GW_V"; fp _PB "$_V2" "$GW_RG"
  printf '%s %s%s%s%s%s%s%s' "$VB" "$1" "$2" "$G_V1" "$_PA" "$3" "$_V1" "$Z"
  printf '%s%s%s%s%s%s' "$G_RG" "$_PB" "$5" "$_V2" "$Z" "$BG"
}

# 页眉第二行：左边从第 3 列起，右边右对齐到第 35 列（右组固定 16 格 → 从第 20 列起，
# 左边最多 17 格，互不打架）
#   <左色> <左文本> <右色> <右文本>
rowlr() {
  fitv _V2 "$4" "$GW_LR"
  fp _PA "$_V2" "$GW_LR"
  printf '%s %s%s%s%s%s%s%s' "$VB" "$1" "$2" "$G_LR" "$_PA" "$3" "$_V2" "$BG"
}

# 标题条：条底色 + 标题在 34 格内容区里**居中**；CSI K 用当前底色铺到行尾，
# 所以不用自己补满空格。
# ⚠ 收尾必须**先复位属性再画右边框**：否则属性（背景色）会顺着终端状态带到下一行
#   ——「页眉第二行日期整片变蓝」就是这么来的（不是画了蓝底，是继承了蓝底）。
bar_ctr() {
  local tw k l
  fitv _T "$2" 34                # 标题是变量拼的（「系统 · 内核 $kver」），超宽会冲出边框
  _dw "$_T"; tw=$_DW
  k=$(( 34 - tw )); [ "$k" -lt 0 ] && k=0
  l=$(( k / 2 ))
  _sp "$l";            local sl="$_SP"
  _sp "$(( k - l ))";  local sr="$_SP"
  printf '%s%s%s%s%s%s%s%s%s' "$VB" "$1" "$sl" "$_T" "$sr" "$EK" "$Z" "$RC" "$VB$NL"
}

# 截断到 n 格（结果在 $_TR）
trunc() {
  local s="$1" n="$2"
  if [ "${#s}" -gt "$n" ]; then printf -v _TR '%s..' "${s:0:n-2}"; else _TR="$s"; fi
}
# 值放不进 n 格时截到 n 格（结果在 $_FIT）—— 保证任何一行都不会挤出右边框
fit() {
  local s="$1" n="$2"
  _dw "$s"
  if [ "$_DW" -gt "$n" ]; then printf -v _FIT '%s' "${s:0:n}"; else printf -v _FIT '%s' "$s"; fi
}

# ══ 阈值配色（结果在 $_TH）════════════════════════════════════════════
# 规格：负载类「超阈值=黄（注意），异常=红（告警）」；**正常不给颜色**（白）。
#   内存 >=75 黄 / >=90 红   交换 >=50 黄 / >=80 红   CPU >=70 黄 / >=90 红
#   温度 >=50 黄 / >=60 红   磁盘 >=75 黄 / >=90 红   青龙内存 >=512 黄 / >=1024 红
#   电量 <=35 黄 / <=15 红（反向：越低越糟）
# 传入值必须已过 san()，否则 $(( )) 里的比较会报错。
th_hi() {                    # th_hi <值> <黄阈值> <红阈值>
  local v="$1" y="$2" r="$3"
  if   [ "$v" -ge "$r" ]; then _TH="$ERR_C"
  elif [ "$v" -ge "$y" ]; then _TH="$WARN_C"
  else                         _TH="$BLD"; fi
}
th_lo() {                    # th_lo <值> <黄阈值> <红阈值>（值越小红）
  local v="$1" y="$2" r="$3"
  if   [ "$v" -le "$r" ]; then _TH="$ERR_C"
  elif [ "$v" -le "$y" ]; then _TH="$WARN_C"
  else                         _TH="$BLD"; fi
}

# 秒 -> 1天02:15（结果在 $_UP）
fmt_up() {
  local s="${1:-0}" d h m
  s=${s%.*}; san "$s" s
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then printf -v _UP '%d%02d:%02d' "$d" "$h" "$m"
  else printf -v _UP '%02d:%02d' "$h" "$m"; fi
}

# ---------- 用户配置 ----------
# 页眉右上角的署名。改成你自己的昵称即可（建议 ≤8 格，超了会自动截断）。
#
# ⚠ 改成**新汉字**之后必须重新跑 `bash build.sh` 重建字体：
#   中文是靠编译期「预编译成 PUA 码点」显示 1 格的，字形由 mkfont.py 从脚本正文
#   里提取。新出现的字如果不在字体里，会**静默**掉回 `- + * #` 这种豆腐块。
#   （只改 ASCII 如 "mido" 则无需重建。）
OWNER="${PANEL_OWNER:-}"

# ---------- 数据源 ----------
PS=/sys/class/power_supply
BATT=$PS/qcom-battery
USB=$PS/qcom-smbchg-usb
NET=/sys/class/net
# 下面这些只是「路径变量」，方便本地预览时换成假目录（tools/mock.sh）
THERM=/sys/class/thermal        # 温度区
RFK=/sys/class/rfkill           # 无线硬/软开关
ROUTE=/proc/net/route           # 默认路由（取网关）
UNIXSOCK=/proc/net/unix         # 判断 tailscaled 控制 socket 有没有被绑上
TS_SOCK=/var/run/tailscale/tailscaled.sock
CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
QLMEM=/sys/fs/cgroup/system.slice/qinglong.service/memory.current

# 采集函数统一写全局变量（不 echo）—— 省掉一次 fork，也不会被管道污染。
# 本地预览时由 PANEL_MOCK 整段覆盖，见 tools/mock.sh。

# CPU 计数器：解析 /proc/stat（零 fork，且 read -t 可超时）
snap_cpu() {
  local l
  _CPU_U=0; _CPU_T=0
  while read -t "$TO_SYSFS" -r l; do
    case "$l" in
      "cpu "*) set -- $l
               _CPU_U=$(( $2+$3+$4+$7+$8 ))
               _CPU_T=$(( $2+$3+$4+$5+$6+$7+$8 ))
               return 0 ;;
    esac
  done < /proc/stat
  return 0
}

# 内存 + 交换：一次扫完 /proc/meminfo（零 fork）
#
# ⚠ 踩过的坑（2026-10-17，屏幕上「内存 100%」的元凶）：
#   原来写成  _MEM_SF=0  ...  [ -n "$_MEM_SF" ] && break
#   `_MEM_SF` 初值是字符串 "0"，**非空**！于是循环读完第一行（MemTotal）就
#   立刻 break —— MemAvailable / SwapTotal / SwapFree 一个都没读到。
#   结果 ma=0 → 内存占用恒等于 100%，交换恒等于 0/0。
#   教训：判「是否已拿到」必须用**空初值**，不能用 0；而且要同时确认
#   拿到的是哪几个字段，不能靠单个哨兵变量。
snap_mem() {
  local k v
  _MEM_MT=""; _MEM_MA=""; _MEM_MF=""; _MEM_BU=""; _MEM_CA=""
  _MEM_ST=""; _MEM_SF=""
  while read -t "$TO_SYSFS" -r k v _; do
    case "$k" in
      MemTotal:)     _MEM_MT=$v ;;
      MemAvailable:) _MEM_MA=$v ;;
      MemFree:)      _MEM_MF=$v ;;
      Buffers:)      _MEM_BU=$v ;;
      Cached:)       _MEM_CA=$v ;;
      SwapTotal:)    _MEM_ST=$v ;;
      SwapFree:)     _MEM_SF=$v ;;
    esac
    # 关键四个都到手就提前收工（Swap* 一定存在，所以最多扫十几行）
    if [ -n "$_MEM_MT" ] && [ -n "$_MEM_ST" ] && [ -n "$_MEM_SF" ] \
       && { [ -n "$_MEM_MA" ] || [ -n "$_MEM_CA" ]; }; then break; fi
  done < /proc/meminfo
  return 0
}

snap_up() {
  local s _
  _UP_S=0
  read -t "$TO_SYSFS" -r s _ < /proc/uptime 2>/dev/null
  [ -n "$s" ] && _UP_S=$s
  return 0
}

# 进程数：直接数 /proc 下的数字目录，一次 fork 都不用
snap_procs() { local p=(/proc/[0-9]*); _PROCS=${#p[@]}; return 0; }

snap_ips() { to "$TO_DEV" ip -o -4 addr show; }

# 无线：首选 iw（一条命令同时给出「是否已连接 / SSID / 频率 / 信号 dBm」）。
# ⚠ iw 的坑：命令失败也返回 rc=0，所以只能靠「有没有解析出字段」判断；
#   并且不是所有网卡/驱动都报 freq / signal —— 读不到上层显示 N/A。
#   兜底：iw 什么都读不出来（或没装）时退回 wpa_cli（能给 ssid/freq，但没有 dBm）。
snap_wifi() {
  local out
  out=$(to "$TO_DEV" iw dev wlan0 link)
  case "$out" in
    *"SSID:"* | *"Connected to"* | *"signal:"*) printf '%s' "$out" ;;
    *) to "$TO_DAEMON" wpa_cli -i wlan0 status ;;
  esac
}

snap_disk() { to "$TO_FS" df -h / | awk 'NR==2{gsub("%","",$5); print $2, $3, $5}'; }

# 5700 端口：让 ss 自己过滤，省掉 awk + grep 两个进程
snap_5700() { [ -n "$(to "$TO_DEV" ss -tlnH "sport = :5700")" ]; }

snap_kver() { to "$TO_MISC" uname -r; }

# tailscaled 是否活着：扫 /proc/net/unix 看它的控制 socket 有没有被绑上。
# 比 `-S 文件存在` 更准（崩溃后 socket 文件会残留），比扫 /proc/*/comm 便宜
# （实测 7.0ms vs 19.9ms），而且零 fork。结果放 $_TS_ALIVE。
ts_alive() {
  local l
  _TS_ALIVE=0
  [ -S "$TS_SOCK" ] || return 0
  while read -t "$TO_SYSFS" -r l; do
    case "$l" in *tailscaled.sock*) _TS_ALIVE=1; break ;; esac
  done < "$UNIXSOCK"
  return 0
}

# 退出时恢复光标（用 >> 而不是 >：对字符设备两者等价，但重定向到普通文件时不会截断内容）
trap 'printf "\033[?25h" >> "$TTY"' EXIT

# 本地预览钩子：设了 PANEL_MOCK 就加载假数据源（生产环境不设，等价于不存在）
# 必须放在取 uname 之前，否则本地预览显示的是电脑的内核版本
[ -n "$PANEL_MOCK" ] && [ -r "$PANEL_MOCK" ] && . "$PANEL_MOCK"

# 内核版本（不会变，循环外取一次就够）
kver=$(snap_kver)
kver=${kver%%-*}                       # 6.16.3-calicocat-msm8953+ -> 6.16.3
kver=${kver:-?}

# ---------- 画一屏 ----------
# 布局共 48 行，正好铺满 36x48 的字符屏；多一行就会滚屏，少一行底部留白。
#   页眉 4 │ 电池 8 │ 充电 7 │ 系统 10 │ 青龙 5 │ WLAN 9 │ 穿透 5 = 48
# 每个分区的形状固定：空行 + 标题条 + 数据行... + 空行 + 分隔线。
# 栅格一律走 row2 / row1 / kvrow，参数是「颜色 + 纯文本」成对给，
# 宽度只数纯文本 —— 这才是「数值右对齐、占位固定、不左右跳动」的实现方式。
screen() {
  printf '%s' "$CLR"

  # ── 页眉：只有标题条是蓝底；第二行是黑底亮字（bar_ctr 收尾已复位属性，
  #    否则这里会继承上面的蓝底，看起来像「顶部两层蓝色背景」）
  rule_top
  bar_ctr "$HC" "mido  · Debian 13 · ${now_t}"
  rowlr "$BLD" "${now_d} ${wd}" "$F_C$BLD" "$OWNER"
  rule_mid

  # ---------- 电池（原先的反色进度条按用户反馈去掉，改由「电量 %」表达）----------
  blank
  bar_ctr "$SC" ""
  row2 "$L" "" "$cap_col"   "${cap}%"          "$L" "" "$st_col"     "$st_cn"
  row2 "$L" "" "$BLD"       "${volt} V"        "$L" "" "$pcol"       "${pow} W"
  row2 "$L" "" "$BLD"       "${cur} A"         "$L" "" "$BLD"        "${btemp} °C"
  row2 "$L" "" "$health_col" "$health_cn"      "$L" "$cap_label" "$BLD"   "$cap_val"
  blank
  rule_mid

  # ---------- 充电配置（这些是「当前生效的设定值」，不是瞬时值）----------
  blank
  bar_ctr "$SC" " ()"
  row2  "$L" "" "$BLD" "${cmax} A" "$L" "" "$BLD" "${ilim} A"
  kvrow "$L" "" "$BLD" "${cterm} A"  "$BLD"  "$ctyp_cn"
  row1  "$L" "" "$BLD" "$utyp_cn"
  blank
  rule_mid

  # ---------- 系统（内核版本挪到标题条，腾出一行给「内存/交换」各自的占用率）----------
  blank
  bar_ctr "$SC" " ·  ${kver}"
  row2 "$L" "CPU"     "$cpu_col"  "${cpu}%"             "$L" "" "$BLD"      "${freq} MHz"
  row2 "$L" " MB" "$mem_col"  "${mem_used}/${mem_tot}" "$L" "" "$mem_col" "${mem_p}%"
  row2 "$L" " MB" "$sw_col"   "${sw_used}/${sw_tot}"   "$L" "" "$sw_col"  "${sw_p}%"
  row2 "$L" ""    "$t_col"    "${cpu_t} °C"         "$L" "" "$tmax_col" "${tmax} °C"
  row2 "$L" ""    "$d_col"    "${dfit}"             "$L" "" "$d_col"    "${dpct}%"
  row2 "$L" ""    "$BLD"      "$nproc_n"            "$L" "" "$BLD"      "$up"
  blank
  rule_mid

  # ---------- 青龙（5700 端口号挪到标题条，行内只留状态和内存）----------
  blank
  bar_ctr "$SC" " ·  5700"
  row2 "$L" "" "$ql_col" "${ql_cn} ${ql_sym}" "$L" "" "$ql_mem_col" "$ql_mem"
  blank
  rule_mid

  # ---------- WLAN（信号：定级+圆点在左，频段+dBm 在右）----------
  blank
  bar_ctr "$SC" "WLAN"
  row2  "$L" "" "$wlan_col" "$wlan_st" "$L" "" "$link_col" "$link_st"
  row1  "$L" "" "$BLD" "$ssid_disp"
  kvrow "$L" "" "$sig_col" "$sig_mid" "$sig_col" "$sig_right"
  row1  "$L" "IPv4" "$BLD" "$ip_wlan"
  row1  "$L" "" "$BLD" "$gw"
  blank
  rule_mid

  # ---------- 内网穿透 (Tailscale) ----------
  blank
  bar_ctr "$SC" " (Tailscale)"
  # 右组只放 IP 本身：Tailscale 的 IPv4 最长 15 格（100.115.255.255），
  # 加「地址 」前缀就是 18 格、超出右组字段宽（17）会把前面的字挤掉 —— 见 fitv()。
  kvrow "$L" "" "$ts_col" "$ts_st" "$BLD" "$ts_ip"
  blank
  rule_bot
}

# 开机时本服务比青龙先起来（青龙要 ~13 秒），首帧若立刻判端口会把「正常」误报成「异常」。
# 所以第一轮多等一会儿；之后每轮只探一次，不拖慢刷新节奏。
first=1

while true; do
  SECONDS=0                  # bash 内建秒表，to()/rdv() 靠它算剩余预算

  # ---------- CPU 占用（1 秒采样）----------
  # 保留一份整数形式 cpu10（千分之一为单位）给阈值配色用，cpu 是显示用的字符串
  snap_cpu; u1=$_CPU_U t1=$_CPU_T
  sleep 1
  snap_cpu; u2=$_CPU_U t2=$_CPU_T
  san "$u1" u1; san "$t1" t1; san "$u2" u2; san "$t2" t2
  cpu="0.0"; cpu10=0
  if [ "$t2" -gt "$t1" ] && [ "$u2" -ge "$u1" ]; then
    cpu10=$(( (u2 - u1) * 1000 / (t2 - t1) ))
    [ "$cpu10" -gt 1000 ] && cpu10=1000
    [ "$cpu10" -lt 0 ] && cpu10=0
    printf -v cpu '%d.%d' $(( cpu10 / 10 )) $(( cpu10 % 10 ))
  fi

  # ---------- 内存 / 交换 ----------
  snap_mem
  san "$_MEM_MT" mt; san "$_MEM_ST" st; san "$_MEM_SF" sf
  # MemAvailable 是「真正可用」（含可回收 cache），3.14+ 才有；
  # 老内核退回 MemFree + Buffers + Cached 近似。两者都拿不到就按 0 处理
  # （宁可显示 100% 也不让 $(( )) 报错中断整轮渲染）。
  if [ -n "$_MEM_MA" ] && [ "$_MEM_MA" -gt 0 ] 2>/dev/null; then
    ma=$_MEM_MA
  else
    san "$_MEM_MF" mf; san "$_MEM_BU" bu; san "$_MEM_CA" ca
    ma=$(( mf + bu + ca ))
  fi
  mem_used=$(( (mt - ma) / 1024 )); mem_tot=$(( mt / 1024 ))
  sw_used=$(( (st - sf) / 1024 ));  sw_tot=$(( st / 1024 ))
  [ "$mem_used" -lt 0 ] && mem_used=0
  [ "$sw_used" -lt 0 ]  && sw_used=0
  if [ "$mt" -gt 0 ]; then mem_p=$(( (mt - ma) * 100 / mt )); else mem_p=0; fi
  [ "$mem_p" -lt 0 ] && mem_p=0
  [ "$mem_p" -gt 100 ] && mem_p=100
  if [ "$st" -gt 0 ]; then sw_p=$(( (st - sf) * 100 / st )); else sw_p=0; fi
  [ "$sw_p" -lt 0 ] && sw_p=0
  [ "$sw_p" -gt 100 ] && sw_p=100
  th_hi "$mem_p" 75 90;  mem_col="$_TH"
  th_hi "$sw_p"  50 80;  sw_col="$_TH"
  th_hi "$cpu10" 700 900; cpu_col="$_TH"

  # ---------- 主频 / 温度 ----------
  rdv fr_raw "$CPUFREQ"
  san "$fr_raw" fr_raw
  if [ "$fr_raw" -gt 0 ]; then freq=$(( fr_raw / 1000 )); else freq="N/A"; fi
  cpu_t=0; tmax=0
  for z in "$THERM"/thermal_zone*; do
    rdv _ty "$z/type"
    [ -n "$_ty" ] || continue
    rdv _tv "$z/temp"
    san "$_tv" _tv
    [ "$_tv" -ne 0 ] || continue
    c=$(( _tv / 1000 ))
    [ "$c" -gt "$tmax" ] && tmax=$c
    case "$_ty" in
      *cpu* | *gpu*) [ "$c" -gt "$cpu_t" ] && cpu_t=$c ;;
    esac
  done

  # 温度配色：>=50 黄，>=60 红
  th_hi "$cpu_t" 50 60; t_col="$_TH"
  th_hi "$tmax"  50 60; tmax_col="$_TH"

  # ---------- 磁盘 / 进程 / 运行时长 ----------
  read -r dsize dused dpct < <(snap_disk)
  [ -z "$dsize" ] && { dsize="N/A"; dused="N/A"; dpct="N/A"; }
  san "$dpct" dpct 0
  th_hi "$dpct" 75 90; d_col="$_TH"
  # "5.2G/24G" 一般 8 格刚好；万一容量很大（"1023G/1024G"）放不下就退化成只显示已用，
  # 保证 V1 这个 9 格锚点永远不会被撑破。
  dfit="${dused}/${dsize}"
  _dw "$dfit"
  [ "$_DW" -gt "$GW_V1" ] && dfit="$dused"
  snap_procs; nproc_n=$_PROCS
  snap_up; fmt_up "$_UP_S"; up=$_UP

  # ---------- 网络接口地址 ----------
  ip_wlan=""; ip_ts=""
  while read -r _idx _ifc _kw _adr _rest; do
    [ "$_kw" = "inet" ] || continue
    case "$_ifc" in
      wlan0)      ip_wlan="${_adr%%/*}" ;;
      tailscale0) ip_ts="${_adr%%/*}" ;;
    esac
  done < <(snap_ips)
  [ -z "$ip_wlan" ] && ip_wlan="N/A"

  # ---------- 默认网关：/proc/net/route 纯 bash 解析（零 fork）----------
  # 表里是小端十六进制，0101A8C0 -> C0.A8.01.01 -> 192.168.1.1
  gw_hex=""
  while read -r _ifc _dest _gw _rest; do
    if [ "$_dest" = "00000000" ] && [ -n "$_gw" ]; then gw_hex="$_gw"; break; fi
  done < "$ROUTE"
  case "$gw_hex" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      printf -v gw '%d.%d.%d.%d' \
        "$((16#${gw_hex:6:2}))" "$((16#${gw_hex:4:2}))" \
        "$((16#${gw_hex:2:2}))" "$((16#${gw_hex:0:2}))" ;;
    *) gw="N/A" ;;
  esac

  # ---------- WLAN 开关 ----------
  rdv w_oper "$NET/wlan0/operstate"
  wlan_st=""
  if [ -n "$w_oper" ] && [ "$w_oper" != "down" ]; then wlan_st=""; fi
  for r in "$RFK"/rfkill*; do                      # rfkill 说被 block 就是关着
    rdv _ty "$r/type"
    [ "$_ty" = "wlan" ] || continue
    rdv _sd "$r/soft"; rdv _hd "$r/hard"
    if [ "$_sd" != "0" ] || [ "$_hd" != "0" ]; then wlan_st=""; fi
  done

  # ---------- WLAN 接入 / SSID / 频率 / 信号 ----------
  # 两种输出格式都解析：
  #   iw      : "Connected to .." / "\tSSID: MyWiFi" / "\tfreq: 2467.0" / "\tsignal: -38 dBm"
  #   wpa_cli : "ssid=MyWiFi" / "freq=2467" / "wpa_state=COMPLETED"
  w_conn=""; w_ssid=""; w_freq=""; w_sig=""
  while IFS= read -r l; do
    case "$l" in
      "Connected to"* | wpa_state=COMPLETED*) w_conn=1 ;;
      *SSID:*)   w_ssid="${l#*SSID:}" ;;
      ssid=*)    w_ssid="${l#ssid=}" ;;
      *freq:*)   w_freq="${l#*freq:}" ;;
      freq=*)    w_freq="${l#freq=}" ;;
      *signal:*) w_sig="${l#*signal:}" ;;
    esac
  done < <(snap_wifi)
  # 去掉前后空白（iw 的字段带制表符，wpa_cli 是纯净的）
  _t="${w_ssid#"${w_ssid%%[![:space:]]*}"}"; w_ssid="${_t%"${_t##*[![:space:]]}"}"
  _t="${w_freq#"${w_freq%%[![:space:]]*}"}"; w_freq="${_t%%[[:space:]]*}"
  _t="${w_sig#"${w_sig%%[![:space:]]*}"}";   w_sig="${_t%%[[:space:]]*}"

  link_st=""
  if [ -n "$w_conn" ]; then
    link_st=""
  elif [ "$w_oper" = "up" ] && [ -n "$w_ssid" ]; then
    link_st=""                    # iw 没报但接口 up 且有 SSID，也算接上了
  fi
  case "$wlan_st" in ) wlan_col="$OK_C" ;; *) wlan_col="$ERR_C" ;; esac
  case "$link_st" in ) link_col="$OK_C" ;; *) link_col="$ERR_C" ;; esac

  # SSID：按 WLAN 原始数据直接显示，不做任何转译
  if [ -z "$w_ssid" ]; then ssid_disp="N/A"; else trunc "$w_ssid" 26; ssid_disp=$_TR; fi

  # 信号强度定级（dBm）：读不到就 N/A（部分网卡/驱动不报 signal），面板照常渲染。
  # 5 格用圆点（●/○）而不是实心块 —— 实心块满格时糊成一整条，圆点更清爽。
  # 配色按统一规则：强/良 = 绿（正常）；一般/弱 = 黄（预警）；差 = 红（异常）。
  sig_val="N/A"; sig_cn="N/A"; sig_col="$BLD"; sig_on=""; sig_off="○○○○○"
  if [[ "$w_sig" =~ ^-?[0-9]+$ ]]; then
    sig_val="${w_sig} dBm"
    if   [ "$w_sig" -ge -50 ]; then sig_cn="";   sig_n=5; sig_col="$OK_C"
    elif [ "$w_sig" -ge -60 ]; then sig_cn="";   sig_n=4; sig_col="$OK_C"
    elif [ "$w_sig" -ge -70 ]; then sig_cn=""; sig_n=3; sig_col="$WARN_C"
    elif [ "$w_sig" -ge -80 ]; then sig_cn="";   sig_n=2; sig_col="$WARN_C"
    else                            sig_cn="";   sig_n=1; sig_col="$ERR_C"
    fi
    sig_on=""; sig_off=""
    for ((i = 0; i < 5; i++)); do
      if [ "$i" -lt "$sig_n" ]; then sig_on+="●"; else sig_off+="○"; fi
    done
  fi
  # 中段值：有定级就「强 ●●●●●」，读不到就只写 N/A（不要孤零零一串空心点）
  sig_mid="$sig_cn"
  [ -n "$sig_on" ] && sig_mid="$sig_cn $sig_on$sig_off"

  # 频段：~2500 -> 2.4GHz；否则 5GHz。读不到就 N/A
  band="N/A"
  fq=${w_freq%%.*}
  if [[ "$fq" =~ ^[0-9]+$ ]] && [ "$fq" -gt 0 ]; then
    if [ "$fq" -lt 3000 ]; then band="2.4GHz"; else band="5GHz"; fi
  fi
  # ⚠ 必须在 band 算完之后才能拼右组 —— 写在上面的信号块里会用到上一帧的 band
  #   （第一帧干脆是空的，屏幕上就成了「 · -38 dBm」这种缺一块的样子）。
  # 右组：dBm 读不到就只留频段，避免「N/A · N/A」这种凑数
  if [ "$sig_val" = "N/A" ]; then sig_right="$band"; else sig_right="${band} · ${sig_val}"; fi

  # ---------- 内网穿透 (Tailscale) ----------
  # 第 1 步：tailscaled 的控制 socket 有没有被绑上（零 fork，~7ms）。
  #          socket 不在 -> 直接判「未启用」，一条 tailscale 命令都不调
  #          （未登录/服务没起来时该命令在部分版本会阻塞等网络）。
  # 第 2 步：socket 在才调 `timeout 1 tailscale status`，**以解析结果为准**。
  #          ⚠ socket 存在只证明「守护进程起来了」，不证明「已登录 / 隧道通」：
  #            没登录时 socket 在但没有隧道 IP，所以必须按「首个字段是不是
  #            IPv4」来判 —— 不是 IPv4（"Logged out." / "Tailscale is stopped."）
  #            就当未启用。命令完全没输出（不可用/超时）才退回接口地址兜底。
  ts_st=""; ts_ip=""
  ts_alive
  if [ "$_TS_ALIVE" = "1" ]; then
    ts_out=$(to "$TO_TS" tailscale status --peers=false)
    if [ -n "$ts_out" ]; then
      ts_line="${ts_out%%$'\n'*}"
      ts_ip="${ts_line%%[[:space:]]*}"
      case "$ts_ip" in '' | *[!0-9.]*) ts_ip="" ;; esac   # 不是 IPv4 = 没登录
    else
      case "$ip_ts" in '' | *[!0-9.]*) ts_ip="" ;; *) ts_ip="$ip_ts" ;; esac
    fi
    if [ -n "$ts_ip" ]; then ts_st=""; else ts_ip=""; fi
  fi
  case "$ts_st" in
    ) ts_col="$OK_C" ;;
    *)      ts_col="$ERR_C" ;;
  esac

  # ---------- 电池 ----------
  rdv st_raw "$BATT/status"
  case "$st_raw" in
    Charging) st_cn="" ;;
    Discharging) st_cn="" ;;
    Full) st_cn="" ;;
    "Not charging") st_cn="" ;;
    *) st_cn="" ;;
  esac
  rdv cap "$BATT/capacity"; san "$cap" cap 0
  rdv vraw "$BATT/voltage_now"
  rdv iraw "$BATT/current_now"
  rdv traw "$BATT/temp"
  # 一次 awk 算完电压/电流/功率/温度（原来是 5 次 awk，省 4 次 fork ≈ 26ms）
  read -r volt cur pow powf btemp < <(awk -v v="$vraw" -v i="$iraw" -v t="$traw" 'BEGIN{
    volt = (v=="" ? "N/A" : sprintf("%.3f", v/1000000))
    if (i=="") cur = "N/A"
    else if (i<500 && i>-500) cur = "0.000"
    else if (i<0) cur = sprintf("+%.3f", -i/1000000)
    else cur = sprintf("%.3f", i/1000000)
    if (v=="" || i=="") { pow = "N/A"; powf = "N/A" }
    else {
      p = -v*i/1e12
      if (p<0.0005 && p>-0.0005) { pow = "0.000"; powf = "+0.000" }
      else if (p<0) { pow = sprintf("%.3f",  p); powf = sprintf("%+7.3f", p) }
      else          { pow = sprintf("+%.3f", p); powf = sprintf("%+7.3f", p) }
    }
    if (t=="") btemp = "N/A"; else btemp = sprintf("%.1f", t/10)
    print volt, cur, pow, powf, btemp
  }')
  [ -z "$volt" ] && volt="N/A"
  [ -z "$cur" ]  && cur="N/A"
  [ -z "$pow" ]  && pow="N/A"
  # 功率配色（按**状态**上色，不按正负）：
  #   充电中/已充满 = 正常 → 绿；放电/静置 = 默认白。正负号本身已经说明了方向。
  case "$st_cn" in
     | ) pcol="$OK_C"; st_col="$OK_C" ;;
    *)               pcol="$BLD";  st_col="$BLD"  ;;
  esac
  # 电量配色：<=35% 黄，<=15% 红（越低越糟，用反向阈值）
  th_lo "$cap" 35 15; cap_col="$_TH"

  rdv health_raw "$BATT/health"
  case "$health_raw" in
    Good) health_cn="" ;;
    Overheat) health_cn="" ;;
    Dead) health_cn="" ;;
    "Over voltage") health_cn="" ;;
    "Unspecified failure") health_cn="" ;;
    Cold) health_cn="" ;;
    Warm) health_cn="" ;;
    Cool) health_cn="" ;;
    "" | Unknown) health_cn="" ;;
    *) health_cn="$health_raw" ;;
  esac
  # 健康配色：良好绿；偏热/偏凉黄；其余（过热/损坏/过压/异常）红
  case "$health_raw" in
    Good)                       health_col="$OK_C" ;;
    Warm | Cool)                health_col="$WARN_C" ;;
    "" | Unknown)               health_col="$BLD" ;;
    *)                          health_col="$ERR_C" ;;
  esac
  # 损耗百分比需要 charge_full（当前满充容量）；本内核的 pmi8996-fg 只导出了
  # charge_full_design（设计容量），所以算不出损耗，退化成显示设计容量。
  rdv cf "$BATT/charge_full"
  rdv cfd "$BATT/charge_full_design"
  san "$cf"  cf_n  0
  san "$cfd" cfd_n 0
  if [ -n "$cf" ] && [ "$cf_n" -gt 0 ] && [ "$cfd_n" -gt 0 ]; then
    wear=$(( (cfd_n - cf_n) * 100 / cfd_n ))
    [ "$wear" -lt 0 ] && wear=0
    cap_label="";     cap_val="${wear} %"
  elif [ "$cfd_n" -gt 0 ]; then
    cap_label=""; cap_val="$(( cfd_n / 1000 )) mAh"
  else
    cap_label="";     cap_val="N/A"
  fi

  # ---------- 充电参数（全是「当前生效的配置值」，不是瞬时电流）----------
  rdv c1 "$USB/constant_charge_current"
  [ -z "$c1" ] && rdv c1 "$BATT/constant_charge_current_max"
  [ -z "$c1" ] && rdv c1 "$USB/constant_charge_current_max"
  rdv c2 "$USB/input_current_limit"
  rdv c3 "$USB/charge_term_current"
  # 一次 awk 格式化三个电流值（绝对值，3 位小数）
  read -r cmax ilim cterm < <(awk -v a="$c1" -v b="$c2" -v c="$c3" '
    function av(x){ if(x=="") return "N/A"; x=x+0; if(x<0) x=-x; return sprintf("%.3f", x/1000000) }
    BEGIN{ print av(a), av(b), av(c) }')
  [ -z "$cmax" ]  && cmax="N/A"
  [ -z "$ilim" ]  && ilim="N/A"
  [ -z "$cterm" ] && cterm="N/A"

  rdv ctyp "$USB/charge_type"
  case "$ctyp" in
    Fast | "Fast Charging") ctyp_cn="Fast ()" ;;
    Trickle) ctyp_cn="Trickle ()" ;;
    Slow) ctyp_cn="Slow ()" ;;
    "Not Charging") ctyp_cn="Not Charging ()" ;;
    "" | Unknown | "N/A") ctyp_cn="N/A" ;;
    *) ctyp_cn="$ctyp" ;;
  esac

  # usb_type 形如 "Unknown SDP [DCP] CDP"，方括号里的才是当前识别出来的类型（纯 bash 解析）
  rdv ut_raw "$USB/usb_type"
  utyp=""
  case "$ut_raw" in
    *"["*"]"*) tmp="${ut_raw#*[}"; utyp="${tmp%%]*}" ;;
  esac
  if [ -z "$utyp" ]; then
    for t in SDP DCP CDP ACA OCP; do
      case " $ut_raw " in *" $t "*) utyp="$t"; break ;; esac
    done
  fi
  case "$utyp" in
    SDP) utyp_cn="SDP (USB)" ;;
    DCP) utyp_cn="DCP ()" ;;
    CDP) utyp_cn="CDP ()" ;;
    ACA) utyp_cn="ACA ()" ;;
    OCP) utyp_cn="OCP ()" ;;
    *) utyp_cn="N/A" ;;
  esac

  # ---------- 青龙：按 5700 端口有没有在监听判定 ----------
  if snap_5700; then
    ql_cn=""; ql_cn2=""; ql_sym="●"
  else
    ql_cn=""; ql_cn2=""; ql_sym="○"
    # 开机首轮青龙还没起来，多等一会儿再判一次，避免误报
    if [ "$first" = "1" ]; then
      for ((k = 0; k < 5; k++)); do
        sleep 3
        if snap_5700; then
          ql_cn=""; ql_cn2=""; ql_sym="●"
          break
        fi
      done
    fi
  fi
  first=0
  # ⚠ 状态色只在「标签条」里能配 $F_K（黑字）；现在状态挪到正文行（黑底），
  #   必须用亮色 + 行尾 $N 复位，否则黑字黑底看不见。
  case "$ql_sym" in
    "●") ql_col="$OK_C" ;;
    *)   ql_col="$ERR_C" ;;
  esac
  rdv ql_mem_raw "$QLMEM"
  san "$ql_mem_raw" ql_mem_raw 0
  if [ "$ql_mem_raw" -gt 0 ]; then
    ql_mb=$(( ql_mem_raw / 1048576 ))
    ql_mem="${ql_mb} MB"
  else
    ql_mb=0
    ql_mem="N/A"
  fi
  # 青龙自身内存也算「高负载项」：>=512MB 黄，>=1024MB 红
  th_hi "$ql_mb" 512 1024; ql_mem_col="$_TH"

  # ---------- 时间（一次 date 拿全，省两次 fork）----------
  IFS='|' read -r now_d now_t dow < <(to "$TO_MISC" date '+%Y-%m-%d|%H:%M:%S|%u')
  [ -z "$now_d" ] && now_d="N/A"
  [ -z "$now_t" ] && now_t="N/A"
  case "$dow" in
    1) wd="" ;; 2) wd="" ;; 3) wd="" ;; 4) wd="" ;;
    5) wd="" ;; 6) wd="" ;; *) wd="" ;;
  esac
  # 标签/值配色：标签用默认色（灰 170），数值用粗体（白 255）。
  # 原来标签用 DIM(85)，在这块屏上偏暗、强光下看不清，用户反馈后统一调亮。
  L=""; Z="$N"

  # ---------- 输出 ----------
  # 整帧先拼好再落盘：某一节渲染出错也不会把屏幕画成半截，
  # 宁肯本轮不刷新，保留上一帧完整画面。
  if frame=$(screen) && [ -n "$frame" ]; then
    # 源码版（PUA_SED 非空）：过一遍 sed 把汉字换成 1 格宽码点
    # 预编译版（PUA_SED 为空）：直接输出，零额外进程
    if [ -n "$PUA_SED" ] && [ -r "$PUA_SED" ]; then
      printf '%s' "$frame" | sed -f "$PUA_SED" > "$TTY"
    else
      printf '%s' "$frame" > "$TTY"
    fi
  fi

  # 本地预览：跑一屏就退出
  [ -n "$PANEL_ONCE" ] && break

  sleep 60
done
