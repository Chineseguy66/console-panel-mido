#!/bin/bash
# ==============================================================================
#  mido 屏幕看板 —— 一键恢复 / 安装脚本
# ------------------------------------------------------------------------------
#  适用：Debian 12/13 (arm64) 手机或单板机，控制台分辨率 1080x1920
#        （其它分辨率见 README「注意事项」—— 需要重建字体，不属于一键范围）
#
#  用法（在目标手机上传整个包目录后，进目录执行）：
#        sudo ./install.sh                  # 标准安装
#        sudo ./install.sh --dry-run        # 只演练，不落盘
#        sudo ./install.sh --force          # 分辨率不匹配也强上
#        sudo ./install.sh --no-deps        # 跳过 apt 装依赖（离线环境）
#        sudo ./install.sh --no-adapt       # 不做硬件路径自适应（照搬 mido 原值）
#        sudo ./install.sh --help
#
#  卸载：sudo ./uninstall.sh
# ==============================================================================

set -euo pipefail

VERSION="1.0"
PKG_DATE="2026-10-17"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SELF/payload"
BAK_ROOT="/root/mido-panel-backup"

# ---------- 目标路径（与 payload/ 下的镜像结构一一对应）----------
D_PANEL=/usr/local/bin/battery-panel.sh          # 预编译运行版（systemd 真正执行的）
D_SRC=/usr/local/bin/battery-panel.src.sh        # 可读源码版（只做参考，不执行）
D_IDLE=/usr/local/bin/screen-idle.py
D_FONT=/usr/local/share/consolefonts/mido-30x40.psf
D_PUASED=/usr/local/share/consolefonts/pua.sed
D_GZFONT=/usr/share/consolefonts/Uni2-mido40x30.psf.gz
D_CS=/etc/default/console-setup
D_UNITDIR=/etc/systemd/system
UNITS="battery-panel.service console-font-mido.service screen-idle.service"
SELFTEST=/root/.mido-panel-selftest.txt          # 注意：不要写 /tmp（tmpfs，占内存）

# ---------- 期望的屏幕几何（字体 30x40 的前提）----------
EXP_W=1080
EXP_H=1920
EXP_COLS=36
EXP_ROWS=48

FORCE=0; NO_DEPS=0; NO_ADAPT=0; DRY=0

# ------------------------------------------------------------------ 输出
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
  C_B=$'\033[36m'; C_BLD=$'\033[1m'; C_N=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_BLD=""; C_N=""
fi
STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s[%d] %s%s\n' "$C_BLD" "$STEP" "$*" "$C_N"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_N" "$*"; }
info() { printf '    · %s\n' "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_N" "$*"; }
err()  { printf '    %s×%s %s\n' "$C_R" "$C_N" "$*"; }
die()  { err "$*"; printf '\n%s安装中止。%s\n' "$C_R" "$C_N"; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '    %s[dry-run]%s %s\n' "$C_Y" "$C_N" "$*"; else "$@"; fi; }

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

for a in "$@"; do
  case "$a" in
    --force)    FORCE=1 ;;
    --no-deps)  NO_DEPS=1 ;;
    --no-adapt) NO_ADAPT=1 ;;
    --dry-run)  DRY=1 ;;
    -h|--help)  usage ;;
    *) die "未知参数：$a（用 --help 看用法）" ;;
  esac
done

printf '%s╔══════════════════════════════════════════════════════════╗%s\n' "$C_B" "$C_N"
printf '%s║  mido 屏幕看板 · 一键恢复  v%s  (%s)%s\n'      "$C_B" "$VERSION" "$PKG_DATE" "$C_N"
printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "$C_B" "$C_N"
[ "$DRY" = 1 ] && warn "演练模式：只打印动作，不修改系统"

# ==============================================================================
step "环境检查"
# ==============================================================================

[ "$(id -u)" = 0 ] || die "需要 root 权限。请用： sudo ./install.sh"
ok "以 root 运行"

[ -d "$PAYLOAD" ] || die "找不到 $PAYLOAD —— 请确认在解包后的目录里执行本脚本"
ok "负载目录就位：$PAYLOAD"

# 发行版
DISTRO=""; . /etc/os-release 2>/dev/null || true
DISTRO="${ID:-unknown} ${VERSION_ID:-}"
case "$DISTRO" in
  debian*) ok "发行版：Debian ${VERSION_ID:-?}（${PRETTY_NAME:-}）" ;;
  *)       warn "发行版不是 Debian（识别为 ${DISTRO:-未知}）—— apt 装依赖可能不适用" ;;
esac

[ -e /dev/tty1 ] || warn "/dev/tty1 不存在，看板会画不出东西（检查内核是否启用虚拟终端）"
[ -e "$D_PANEL" ] && info "检测到已安装的看板，本次为「覆盖升级」（旧文件会自动备份）"

# ==============================================================================
step "屏幕分辨率适配检查"
# ==============================================================================

FB_W=""; FB_H=""
# 首选 /sys/class/graphics/fb0/virtual_size（格式 1080,1920）
if [ -r /sys/class/graphics/fb0/virtual_size ]; then
  _vs="$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || true)"
  FB_W="${_vs%%,*}"; FB_H="${_vs##*,}"
fi
# 退路：modes（格式 U:1080x1920p-0）
if { [ -z "$FB_W" ] || [ -z "$FB_H" ]; } && [ -r /sys/class/graphics/fb0/modes ]; then
  _m="$(head -1 /sys/class/graphics/fb0/modes 2>/dev/null || true)"
  FB_W="${_m#*:}"; FB_W="${FB_W%%x*}"
  _h="${_m#*x}";  FB_H="${_h%%[!0-9]*}"
fi

if [ -n "$FB_W" ] && [ -n "$FB_H" ]; then
  ok "帧缓冲分辨率：${FB_W}x${FB_H}"
  GOK=1
  [ $((FB_W % 30)) -ne 0 ] && GOK=0
  [ $((FB_H % 40)) -ne 0 ] && GOK=0
  [ "$FB_W" -eq "$EXP_W" ] && [ "$FB_H" -eq "$EXP_H" ] || GOK=0
  if [ "$GOK" = 1 ]; then
    ok "与字体前提一致：${FB_W}÷30 = $((FB_W / 30)) 列，${FB_H}÷40 = $((FB_H / 40)) 行"
  else
    warn "分辨率与字体前提不符（期望 ${EXP_W}x${EXP_H}，即 ${EXP_COLS} 列 × ${EXP_ROWS} 行）"
    warn "字体 30x40 是按 1080x1920 定的；其它分辨率下字符格数不整除，画面会错位/留黑边。"
    warn "正确做法：用 source/ 里的 mkfont.py 重建字体 + 调整脚本栅格常量（见 README）。"
    if [ "$FORCE" = 1 ]; then
      warn "--force 已指定，继续（画面可能异常）。"
    else
      die "分辨率不匹配，已停止。确认要继续请加 --force"
    fi
  fi
else
  warn "读不到帧缓冲分辨率（/sys/class/graphics/fb0 不可用？），跳过这项检查"
fi

# ==============================================================================
step "安装依赖"
# ==============================================================================

# 必需：setfont(kbd) / ip+ss(iproute2) / iw / python3(screen-idle) / awk
# 可选：console-setup（tty1..6 统一字体）、python3-evdev（息屏守护读按键）、procps(uptime)
REQ="kbd iproute2 iw python3"
OPT="console-setup python3-evdev procps"

if [ "$NO_DEPS" = 1 ]; then
  warn "--no-deps：跳过依赖安装"
else
  _missing=""
  for p in $REQ $OPT; do
    dpkg -s "$p" >/dev/null 2>&1 || _missing="$_missing $p"
  done
  if [ -z "$_missing" ]; then
    ok "依赖已齐（$REQ $OPT）"
  else
    info "待安装：$_missing"
    if run env DEBIAN_FRONTEND=noninteractive apt-get update -qq \
       && run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $_missing; then
      ok "依赖安装完成"
    else
      warn "apt 安装未完全成功（离线？）—— 必需项缺失会影响功能，请对照 README 手工补装"
    fi
  fi
fi

for c in setfont ip ss iw awk python3; do
  if command -v "$c" >/dev/null 2>&1; then ok "命令可用：$c"
  else
    case "$c" in
      python3) warn "缺少 $c —— 息屏守护将无法运行（看板本体不受影响）" ;;
      *)       err  "缺少 $c —— 看板对应字段会显示 N/A，建议补装" ;;
    esac
  fi
done
command -v tailscale >/dev/null 2>&1 \
  && ok "tailscale 已安装（内网穿透栏会有数据）" \
  || info "未安装 tailscale —— 「内网穿透」栏会显示未启用（属正常降级，不影响其它）"

# ==============================================================================
step "备份已有文件"
# ==============================================================================

BACKUP_DIR="$BAK_ROOT/$(date +%Y%m%d-%H%M%S)"
if [ "$DRY" = 0 ]; then mkdir -p "$BACKUP_DIR"; fi
info "备份目录：$BACKUP_DIR"

backup_one() {
  local src="$1" dstbase
  [ -e "$src" ] || return 0
  dstbase="$BACKUP_DIR/${src#/}"
  if [ "$DRY" = 1 ]; then
    printf '    %s[dry-run]%s 备份 %s\n' "$C_Y" "$C_N" "$src"
  else
    mkdir -p "$(dirname "$dstbase")"
    cp -a "$src" "$dstbase"
    ok "已备份 $src"
  fi
}

for f in "$D_PANEL" "$D_SRC" "$D_IDLE" "$D_FONT" "$D_PUASED" "$D_GZFONT" "$D_CS"; do
  backup_one "$f"
done
for u in $UNITS; do
  backup_one "$D_UNITDIR/$u"
done

# ==============================================================================
step "部署文件到系统"
# ==============================================================================

# payload/ 下的目录结构就是绝对路径的镜像，直接整棵覆盖过去
if [ "$DRY" = 1 ]; then
  printf '    %s[dry-run]%s 拷贝 9 个负载文件到系统对应位置（etc/ 与 usr/）\n' "$C_Y" "$C_N"
else
  # 先建目录（consolefonts 在部分最小化系统上可能不存在）
  mkdir -p /usr/local/bin /usr/local/share/consolefonts /usr/share/consolefonts \
           /etc/systemd/system /etc/default
  cp -a "$PAYLOAD/usr/local/bin/battery-panel.sh"  "$D_PANEL"
  cp -a "$PAYLOAD/usr/local/bin/screen-idle.py"    "$D_IDLE"
  cp -a "$PAYLOAD/usr/local/share/consolefonts/mido-30x40.psf"       "$D_FONT"
  cp -a "$PAYLOAD/usr/local/share/consolefonts/pua.sed"             "$D_PUASED"
  cp -a "$PAYLOAD/usr/share/consolefonts/Uni2-mido40x30.psf.gz"     "$D_GZFONT"
  cp -a "$PAYLOAD/etc/default/console-setup"                        "$D_CS"
  for u in $UNITS; do
    cp -a "$PAYLOAD/etc/systemd/system/$u" "$D_UNITDIR/$u"
  done
  chmod 755 "$D_PANEL" "$D_IDLE"
  chmod 644 "$D_FONT" "$D_PUASED" "$D_GZFONT" "$D_CS"
  chmod 644 "$D_UNITDIR"/*.service
  # 附一份可读源码，方便以后改（不执行）
  cp -a "$SELF/source/battery-panel.src.sh" "$D_SRC" 2>/dev/null || true
  chmod 755 "$D_SRC" 2>/dev/null || true
  ok "看板脚本 → $D_PANEL"
  ok "息屏守护 → $D_IDLE"
  ok "控制台字体 → $D_FONT"
  ok "字体前提配置 → $D_CS"
  ok "3 个 systemd 单元 → $D_UNITDIR/"
  ok "可读源码 → $D_SRC"
fi

# ==============================================================================
step "硬件路径自适应"
# ==============================================================================

if [ "$NO_ADAPT" = 1 ]; then
  warn "--no-adapt：保留 mido 原机路径（qcom-battery / qcom-smbchg-usb / wlan0）"
  warn "若目标机不是骁龙 msm8953，电池与 WLAN 栏会大面积显示 N/A"
else
  # ---- 电池 / 充电器：按 /sys/class/power_supply/*/type 认名 ----
  DET_BATT=""; DET_CHG=""; DET_WLAN=""
  for d in /sys/class/power_supply/*; do
    [ -r "$d/type" ] || continue
    _t="$(cat "$d/type" 2>/dev/null || true)"
    case "$_t" in
      Battery) [ -n "$DET_BATT" ] || DET_BATT="$(basename "$d")" ;;
      USB|Mains) [ -n "$DET_CHG" ] || DET_CHG="$(basename "$d")" ;;
    esac
  done
  # ---- 无线网卡：靠 /sys/class/net/*/wireless 目录判定 ----
  for d in /sys/class/net/*; do
    if [ -d "$d/wireless" ]; then DET_WLAN="$(basename "$d")"; break; fi
  done

  patch_file() {  # patch_file <文件> <sed表达式...>
    local f="$1"; shift
    [ -f "$f" ] || return 0
    if [ "$DRY" = 1 ]; then
      printf '    %s[dry-run]%s %s  <%s>\n' "$C_Y" "$C_N" "$f" "$*"
      return 0
    fi
    cp -a "$f" "$BACKUP_DIR/${f#/}.preadapt" 2>/dev/null || true
    for e in "$@"; do LC_ALL=C sed -i "$e" "$f"; done
  }

  CHANGED=0
  if [ -n "$DET_BATT" ] && [ "$DET_BATT" != "qcom-battery" ]; then
    patch_file "$D_PANEL" "s#^BATT=\\\$PS/qcom-battery#BATT=\$PS/$DET_BATT#"
    patch_file "$D_SRC"   "s#^BATT=\\\$PS/qcom-battery#BATT=\$PS/$DET_BATT#"
    ok "电池节点：qcom-battery → $DET_BATT"; CHANGED=1
  elif [ -n "$DET_BATT" ]; then ok "电池节点：$DET_BATT（与原值一致）"
  else warn "认不出电池节点（/sys/class/power_supply 下无 type=Battery）—— 电池栏会显示 N/A"; fi

  if [ -n "$DET_CHG" ] && [ "$DET_CHG" != "qcom-smbchg-usb" ]; then
    patch_file "$D_PANEL" "s#^USB=\\\$PS/qcom-smbchg-usb#USB=\$PS/$DET_CHG#"
    patch_file "$D_SRC"   "s#^USB=\\\$PS/qcom-smbchg-usb#USB=\$PS/$DET_CHG#"
    ok "充电器节点：qcom-smbchg-usb → $DET_CHG"; CHANGED=1
  elif [ -n "$DET_CHG" ]; then ok "充电器节点：$DET_CHG（与原值一致）"
  else warn "认不出充电器节点 —— 充电配置栏会显示 N/A"; fi

  if [ -n "$DET_WLAN" ] && [ "$DET_WLAN" != "wlan0" ]; then
    patch_file "$D_PANEL" "s#wlan0#$DET_WLAN#g"
    patch_file "$D_SRC"   "s#wlan0#$DET_WLAN#g"
    ok "无线网卡：wlan0 → $DET_WLAN"; CHANGED=1
  elif [ -n "$DET_WLAN" ]; then ok "无线网卡：$DET_WLAN（与原值一致）"
  else warn "没找到无线网卡（/sys/class/net/*/wireless）—— WLAN 栏会显示未开启"; fi

  [ "$CHANGED" = 1 ] && info "自适应改动已记录，原文件另存为 *.preadapt" || info "无需自适应改动"

  # ---- 息屏守护：背光路径 / 亮度上限 / 待监控输入设备 ----
  if [ -f "$D_IDLE" ]; then
    BL_DIR="$(ls /sys/class/backlight/ 2>/dev/null | head -1 || true)"
    if [ -n "$BL_DIR" ]; then
      BL_MAX="$(cat "/sys/class/backlight/$BL_DIR/max_brightness" 2>/dev/null || true)"
      [ -n "$BL_MAX" ] && [ "$BL_MAX" -gt 0 ] 2>/dev/null || BL_MAX=""
      patch_file "$D_IDLE" \
        "s#^BACKLIGHT = .*#BACKLIGHT = \"/sys/class/backlight/$BL_DIR/brightness\"#"

      # 亮屏亮度：只在「包内值超出本机上限」时才下调，绝不主动调高。
      # （源机的 2048 是调过的：够亮、不过热、不费电。盲目改成 max_brightness
      #   会让屏幕更亮更热更费电，还可能把面板烤着。）
      CUR_ON="$(sed -n 's/^BRIGHT_ON *= *\([0-9]\+\).*/\1/p' "$D_IDLE" 2>/dev/null | head -1)"
      if [ -n "$BL_MAX" ] && [ -n "$CUR_ON" ] && [ "$CUR_ON" -gt "$BL_MAX" ] 2>/dev/null; then
        patch_file "$D_IDLE" "s|^BRIGHT_ON = .*|BRIGHT_ON = $BL_MAX   # auto: 原值 $CUR_ON 超出本机 max_brightness|"
        warn "亮屏亮度 $CUR_ON 超出本机上限，已下调为 $BL_MAX"
      elif [ -n "$BL_MAX" ] && [ -n "$CUR_ON" ]; then
        ok "背光：/sys/class/backlight/$BL_DIR，亮屏亮度 = $CUR_ON（本机上限 $BL_MAX，未改动）"
        info "觉得偏暗/偏亮：改 $D_IDLE 里的 BRIGHT_ON（0~$BL_MAX），然后 systemctl restart screen-idle"
      else
        ok "背光：/sys/class/backlight/$BL_DIR"
      fi
    else
      warn "没有 /sys/class/backlight —— 息屏守护无法控光，建议 systemctl disable screen-idle"
    fi

    # 输入设备名：把「本机真实存在的设备名」套进 WATCH_NAMES。
    # 关键点：脚本是按**子串**匹配的（`k in dev.name`），所以源机的 "ft5x06"
    # 能匹配到真机上的 "generic ft5x06 (3b)"。
    # 策略（最小改动优先）：
    #   · 原配置在本机**全部**仍能命中 → 一个字都不改（源机就是这种情况）
    #   · 有词失效了（换机） → 用「仍有效的旧词 + 新认出来的设备」重建
    if command -v python3 >/dev/null 2>&1 && [ -r /proc/bus/input/devices ]; then
      ALL_NAMES="$(awk -F'"' '/^N: Name=/{print $2}' /proc/bus/input/devices 2>/dev/null || true)"
      if [ -n "$ALL_NAMES" ]; then
        if [ "$DRY" = 1 ]; then
          printf '    %s[dry-run]%s 本机输入设备：%s\n' "$C_Y" "$C_N" "$(printf '%s' "$ALL_NAMES" | tr '\n' '|')"
        else
          NAME_ARR=()
          while IFS= read -r _n; do [ -n "$_n" ] && NAME_ARR+=("$_n"); done <<< "$ALL_NAMES"
          python3 - "$D_IDLE" "${NAME_ARR[@]}" <<'PYEOF'
import io, sys, re

path     = sys.argv[1]
allnames = sys.argv[2:]
src      = io.open(path, encoding="utf-8").read()

m = re.search(r'^WATCH_NAMES = \((.*?)\)', src, re.M | re.S)
cur = re.findall(r'"([^"]*)"', m.group(1)) if m else []
if not m:
    print("    ! 没找到 WATCH_NAMES 行，未改写")
    sys.exit(0)

# 原有词里，仍能子串命中本机某个设备名的（脚本就是按子串匹配的）
valid = [w for w in cur if any(w.lower() in d.lower() for d in allnames)]

if cur and len(valid) == len(cur):
    print("    ok 待监控输入设备：原配置在本机全部有效，保持不变 -> " + str(tuple(cur)))
    sys.exit(0)

# 有词失效：用「仍有效的旧词 + 新认出来的交互设备」重建
KW = (r'key|pwr|power|gpio|resin|vol|kpd|btn|hall|switch|touch|tpd|synaptics|'
      r'goodix|focaltech|atmel|elan|fts|x0[0-9]|ft[0-9]|gt9|ili|himax|novatek|'
      r'haptic|jack')
det = [d for d in allnames if re.search(KW, d, re.I)]

final = list(valid)
for w in det:
    low = w.lower()
    if any(low in x.lower() or x.lower() in low for x in final):
        continue                      # 已被现有词覆盖（含互为子串），不必重复
    final.append(w)

if not final:
    print("    ! 没认出任何交互设备，WATCH_NAMES 保持原样")
    sys.exit(0)

lit = "(" + ", ".join('"%s"' % n.replace("\\", "\\\\").replace('"', '\\"')
                      for n in final) + ")"
new, n = re.subn(r"^WATCH_NAMES = .*$", "WATCH_NAMES = " + lit,
                 src, count=1, flags=re.M)
if n:
    io.open(path, "w", encoding="utf-8", newline="\n").write(new)
    print("    ok 待监控输入设备（原值 %d 个词中 %d 个仍有效）-> %s"
          % (len(cur), len(valid), lit))
else:
    print("    ! 改写 WATCH_NAMES 失败")
PYEOF
        fi
      else
        warn "读不到 /proc/bus/input/devices 里的设备名"
      fi
    else
      warn "跳过输入设备探测（缺 python3 或 /proc/bus/input/devices）—— 唤醒功能可能失效（息屏仍有效）"
    fi
  fi
fi

# ==============================================================================
step "启用并启动服务"
# ==============================================================================

if [ "$DRY" = 1 ]; then
  printf '    %s[dry-run]%s systemctl daemon-reload\n' "$C_Y" "$C_N"
  printf '    %s[dry-run]%s systemctl enable --now %s\n' "$C_Y" "$C_N" "$UNITS"
else
  systemctl daemon-reload
  ok "systemd 单元已重新加载"

  # apt 装 console-setup 时会自带一个 console-setup.service；这里顺带应用配置
  if command -v setupcon >/dev/null 2>&1; then
    setupcon --force >/dev/null 2>&1 && ok "console-setup 配置已应用（setupcon）" \
                                      || warn "setupcon 未成功（不影响 tty1 字体，那由 console-font-mido 负责）"
  fi

  for u in $UNITS; do
    systemctl enable "$u" >/dev/null 2>&1 && ok "已设开机自启：$u" || warn "enable 失败：$u"
  done

  # 字体单元是 oneshot，必须 restart 才会真正跑 setfont
  for u in console-font-mido.service screen-idle.service battery-panel.service; do
    systemctl restart "$u" >/dev/null 2>&1 && ok "已启动：$u" || warn "启动失败：$u（稍后用 journalctl -u $u 看原因）"
  done
fi

# ==============================================================================
step "自检"
# ==============================================================================

sleep 2 2>/dev/null || true

if [ "$DRY" = 1 ]; then
  info "[dry-run] 跳过运行时自检"
else
  FAILED=""
  for u in $UNITS; do
    _st="$(systemctl is-active "$u" 2>/dev/null || true)"
    if [ "$_st" = "active" ]; then ok "$u：active"
    else err "$u：$_st"; FAILED="$FAILED $u"; fi
  done

  # 单帧渲染（注意写 /root，不要写 /tmp —— 嵌入式 /tmp 多为 tmpfs，占内存）
  if PANEL_ONCE=1 "$D_PANEL" "$SELFTEST" >/dev/null 2>&1; then
    _b="$(stat -c%s "$SELFTEST" 2>/dev/null || echo 0)"
    _r="$(tr -cd '\n' < "$SELFTEST" 2>/dev/null | wc -c | tr -d ' ')"
    ok "单帧渲染成功：${_b} 字节，${_r} 个换行"
    if [ "$_r" -ge 46 ] && [ "$_r" -le 49 ]; then ok "行数符合预期（${EXP_ROWS} 行满屏）"
    else warn "行数 $_r 不在 46~49，画面可能不满屏或滚屏"; fi
    if [ "$_b" -lt 800 ]; then warn "帧偏小（$_b 字节），可能有字段采集失败"; fi
  else
    err "单帧渲染失败 —— 手动跑一下看报错：PANEL_ONCE=1 $D_PANEL /root/xx.txt"
    FAILED="$FAILED battery-panel(render)"
  fi

  # 服务重启次数（判断有没有崩溃循环）
  _nr="$(systemctl show -p NRestarts --value battery-panel.service 2>/dev/null || echo '?')"
  info "battery-panel 重启次数：$_nr"

  _pid="$(systemctl show -p MainPID --value battery-panel.service 2>/dev/null || echo 0)"
  if [ "$_pid" != 0 ] && [ -r "/proc/$_pid/status" ]; then
    _rss="$(awk '/VmRSS/{print $2" "$3}' "/proc/$_pid/status" 2>/dev/null || true)"
    info "看板常驻内存：${_rss:-未知}"
  fi

  if [ -n "$FAILED" ]; then
    warn "以下单元异常：$FAILED"
    warn "排查：journalctl -u <单元名> -n 30 --no-pager"
  else
    ok "全部单元运行正常"
  fi
fi

# ==============================================================================
printf '\n%s══════════════════════════════════════════════════════════%s\n' "$C_B" "$C_N"
if [ "$DRY" = 1 ]; then
  printf '%s  演练结束，未改动系统。去掉 --dry-run 正式安装即可。%s\n' "$C_G" "$C_N"
else
  printf '%s  安装完成。%s\n' "$C_G" "$C_N"
  printf '  看板正在 /dev/tty1 上运行；物理屏幕应显示整套面板。\n'
  printf '  备份在 %s\n' "$BACKUP_DIR"
  printf '  自检帧 %s（可 cat 看原始字节流）\n' "$SELFTEST"
  printf '\n  常用命令：\n'
  printf '    systemctl status battery-panel        # 看板状态\n'
  printf '    journalctl -u battery-panel -n 30     # 看板日志\n'
  printf '    systemctl restart battery-panel       # 改完重载\n'
  printf '    卸载回滚：sudo ./uninstall.sh\n'
fi
printf '%s══════════════════════════════════════════════════════════%s\n' "$C_B" "$C_N"
