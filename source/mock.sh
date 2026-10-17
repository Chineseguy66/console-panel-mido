#!/bin/bash
# ============================================================================
# 本地预览用的假数据源（只在设了 PANEL_MOCK 时被 source）
#
# 作用是让 battery-panel.sh 在一台没有 /sys/class/power_supply 的电脑上
# 也能跑出一屏完整内容，方便改排版时秒看效果。
#
# 用法:
#   PANEL_MOCK=mock.sh PANEL_ONCE=1 bash battery-panel.sh panel_raw.txt
#   python term.py panel_raw.txt 30 40 v9
#
# 开关（不设就是「已接入 / 已登录启用中」的正常态）:
#   PANEL_MOCK_WIFI=0  模拟未接入（iw 读不出东西）
#   PANEL_MOCK_TS=0    模拟 tailscaled 没起来（socket 不存在）
#   PANEL_MOCK_TS=2    模拟 socket 在（守护进程活着）但**没登录** ——
#                      这正是「socket 存在只能证明进程起来，不能证明已登录」的边界
#   PANEL_MOCK_WEAR=1  模拟有 charge_full（走「损耗 N %」分支）
#   PANEL_MOCK_ALERT=1 模拟「高负载告警态」：内存/交换/CPU/磁盘/温度 全部超阈值，
#                      用来检查黄/红阈值配色有没有生效
#
# ⚠ 接口约定：这里覆盖的是 battery-panel.sh 里的采集函数。
#   采集函数统一「写全局变量」而不 echo（省 fork），所以 mock 也得照做。
#   改脚本时记得同步这里。
# ============================================================================

MOCK_BATT=/sys/class/power_supply/qcom-battery
MOCK_USB=/sys/class/power_supply/qcom-smbchg-usb

WIFI=${PANEL_MOCK_WIFI:-1}
TS=${PANEL_MOCK_TS:-1}
WEAR=${PANEL_MOCK_WEAR:-0}
ALERT=${PANEL_MOCK_ALERT:-0}

# ---------- 假 sysfs 目录（真机上这些是内核提供的）----------
# ⚠ 不要用 rm -rf（会被安全策略拦），目录里文件每次覆盖写就够了
MOCK_ROOT="${TMPDIR:-/tmp}/panel_mock"
mkdir -p "$MOCK_ROOT/thermal" "$MOCK_ROOT/rfkill"

_i=0
for spec in "cpu0-thermal 42000" "cpu1-thermal 44500" "gpu-thermal 41000" "pm8953-thermal 45200"; do
  set -- $spec
  d="$MOCK_ROOT/thermal/thermal_zone$_i"
  mkdir -p "$d"
  printf '%s' "$1" > "$d/type"
  if [ "$ALERT" = "1" ]; then printf '%s' "63500" > "$d/temp"; else printf '%s' "$2" > "$d/temp"; fi
  _i=$((_i + 1))
done

mkdir -p "$MOCK_ROOT/rfkill/rfkill0" "$MOCK_ROOT/rfkill/rfkill1"
printf 'bluetooth' > "$MOCK_ROOT/rfkill/rfkill0/type"
printf '0' > "$MOCK_ROOT/rfkill/rfkill0/soft"
printf '0' > "$MOCK_ROOT/rfkill/rfkill0/hard"
printf 'wlan' > "$MOCK_ROOT/rfkill/rfkill1/type"
printf '0' > "$MOCK_ROOT/rfkill/rfkill1/soft"
printf '0' > "$MOCK_ROOT/rfkill/rfkill1/hard"

# 路由表（真机 /proc/net/route 的格式：小端十六进制）
printf 'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n' > "$MOCK_ROOT/route"
printf 'wlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n'                 >> "$MOCK_ROOT/route"
printf 'wlan0\t0001A8C0\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0\n'                 >> "$MOCK_ROOT/route"

# ---------- 覆盖路径变量 ----------
THERM="$MOCK_ROOT/thermal"
RFK="$MOCK_ROOT/rfkill"
ROUTE="$MOCK_ROOT/route"

# ---------- 覆盖 to()：本地没有 timeout（Git Bash 下同名的是 Windows 的另一个
# 程序），直接执行即可；顺便也让本地渲染更快。tailscale 用假输出拦截。----------
to() {
  shift
  case "$*" in
    tailscale\ status*)
      case "$TS" in
        1) printf '%s\n' "100.100.100.100  mido-debian  1000000000@  linux  -" ;;
        2) printf '%s\n' "Logged out." ;;
        *) printf '%s\n' "Tailscale is stopped." ;;
      esac
      return 0 ;;
    # 冻结时钟。页眉那行 `mido 看板 · Debian 13 · <钟点>` 如果取真实时间，
    # 每次渲染出来的演示图就不一样 —— 而演示图是**构建产物**（会进包、会上传），
    # 于是整个包又变得不可复现了。这里给个固定值，要手动看实时效果再
    # `PANEL_MOCK_NOW='...'` 覆盖即可。第六字段是星期（6=周六）。
    date\ '+%Y-%m-%d|%H:%M:%S|%u'*)
      printf '%s\n' "${PANEL_MOCK_NOW:-2026-10-17|05:55:33|6}"
      return 0 ;;
  esac
  "$@" 2>/dev/null
}

# ---------- rdv：先看假 sysfs 目录，再按路径后缀匹配 ----------
rdv() {
  local v="" f
  case "$2" in
    "$MOCK_ROOT"/*)                             { read -r f < "$2"; } 2>/dev/null; v="$f" ;;
    */qcom-battery/status)                      v="Discharging" ;;
    */qcom-battery/capacity)                    v="79" ;;
    */qcom-battery/voltage_now)                 v="3842100" ;;
    */qcom-battery/current_now)                 v="350000" ;;
    */qcom-battery/temp)                        v="325" ;;
    */qcom-battery/health)                      v="Good" ;;
    */qcom-battery/charge_full)                 if [ "$WEAR" = "1" ]; then v="3760000"; else v=""; fi ;;
    */qcom-battery/charge_full_design)          v="4100000" ;;
    */qcom-battery/constant_charge_current_max) v="1600000" ;;
    */qcom-smbchg-usb/constant_charge_current)      v="1600000" ;;
    */qcom-smbchg-usb/constant_charge_current_max)  v="1600000" ;;
    */qcom-smbchg-usb/input_current_limit)          v="3000000" ;;
    */qcom-smbchg-usb/charge_term_current)          v="300000" ;;
    */qcom-smbchg-usb/charge_type)                  v="N/A" ;;
    */qcom-smbchg-usb/usb_type)                     v="Unknown SDP [DCP] CDP" ;;
    */scaling_cur_freq)                         v="1401600" ;;
    */qinglong.service/memory.current)          v="20398080" ;;
    */wlan0/operstate)                          if [ "$WIFI" = "1" ]; then v="up"; else v="down"; fi ;;
    *)                                          v="" ;;
  esac
  printf -v "$1" '%s' "$v"
}

# ---------- 采集函数（统一写全局变量）----------
_mock_cpu_n=0
snap_cpu() {
  _mock_cpu_n=$((_mock_cpu_n + 1))
  if [ "$ALERT" = "1" ]; then
    # Δuser/Δtotal = 760/820 ≈ 92% -> 触发 CPU 红色告警
    if [ "$_mock_cpu_n" -le 1 ]; then _CPU_U=100000; _CPU_T=800000
    else                            _CPU_U=100760; _CPU_T=800820; fi
    return 0
  fi
  # Δuser/Δtotal = 140/820 ≈ 17%，跟真机空闲时差不多
  if [ "$_mock_cpu_n" -le 1 ]; then _CPU_U=100000; _CPU_T=800000
  else                            _CPU_U=100140; _CPU_T=800820; fi
  return 0
}
if [ "$ALERT" = "1" ]; then
  # 高负载态：内存 92% / 交换 85% / 磁盘 93%
  snap_mem()   { _MEM_MT=2871564; _MEM_MA=229725; _MEM_ST=1435644; _MEM_SF=215346; return 0; }
  snap_disk()  { echo "24G 22.3G 93"; }
else
  snap_mem()   { _MEM_MT=2871564; _MEM_MA=2373000; _MEM_ST=1435644; _MEM_SF=1428000; return 0; }
  snap_disk()  { echo "24G 5.1G 23"; }
fi
snap_up()  { _UP_S=5790; return 0; }
snap_procs() { _PROCS=226; return 0; }
snap_5700() { return 0; }
snap_kver() { echo "6.16.3-calicocat-msm8953+"; }
ts_alive()  { if [ "$TS" = "0" ]; then _TS_ALIVE=0; else _TS_ALIVE=1; fi; return 0; }

# ip -o -4 addr show 的格式（未登录时隧道 IP 不存在）
snap_ips() {
  if [ "$TS" = "1" ]; then
    echo "4: tailscale0    inet 100.100.100.100/32 scope global tailscale0"
  fi
  if [ "$WIFI" = "1" ]; then
    echo "5: wlan0    inet 192.168.1.100/24 brd 192.168.1.255 scope global dynamic noprefixroute wlan0"
  fi
}

# iw dev wlan0 link 的格式（WIFI=0 时模拟「读不出东西」的网卡）
snap_wifi() {
  [ "$WIFI" = "1" ] || return 0
  printf 'Connected to 00:11:22:33:44:55 (on wlan0)\n'
  printf '\tSSID: MyWiFi\n'
  printf '\tfreq: 2467.0\n'
  printf '\tRX: 583758 bytes (3644 packets)\n'
  printf '\tsignal: -38 dBm\n'
  printf '\trx bitrate: 135.0 MBit/s MCS 7 40MHz\n'
}
