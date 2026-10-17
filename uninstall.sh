#!/bin/bash
# ==============================================================================
#  mido 屏幕看板 —— 卸载 / 回滚脚本
# ------------------------------------------------------------------------------
#  用法：sudo ./uninstall.sh [--keep-backup]
#
#  做三件事：
#    1) 停用并禁用 3 个 systemd 单元，删掉单元文件
#    2) 删掉看板脚本 / 息屏守护 / 自建字体
#    3) 还原 /etc/default/console-setup（若安装时有备份）
#
#  默认会删掉本次安装写入的文件，但**不会**删 /root/mido-panel-backup 里的备份。
# ==============================================================================

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAK_ROOT="/root/mido-panel-backup"
KEEP_BAK=0
for a in "$@"; do
  case "$a" in
    --keep-backup) KEEP_BAK=1 ;;
    -h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$a"; exit 1 ;;
  esac
done

if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_BLD=$'\033[1m'; C_N=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_BLD=""; C_N=""
fi
step() { printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_N"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_N" "$*"; }

[ "$(id -u)" = 0 ] || { echo "${C_R}需要 root：sudo ./uninstall.sh${C_N}"; exit 1; }

UNITS="battery-panel.service console-font-mido.service screen-idle.service"

step "停止并禁用服务"
for u in $UNITS; do
  systemctl disable --now "$u" >/dev/null 2>&1 && ok "已停用 $u" || warn "$u 未在运行或不存在"
done

step "删除单元文件"
for u in $UNITS; do
  if [ -e "/etc/systemd/system/$u" ]; then
    rm -f "/etc/systemd/system/$u" && ok "已删除 /etc/systemd/system/$u"
  fi
done
systemctl daemon-reload
ok "systemd 已重新加载"
systemctl reset-failed >/dev/null 2>&1 || true

step "删除看板文件"
for f in /usr/local/bin/battery-panel.sh \
         /usr/local/bin/battery-panel.src.sh \
         /usr/local/bin/screen-idle.py \
         /usr/local/share/consolefonts/mido-30x40.psf \
         /usr/local/share/consolefonts/pua.sed \
         /usr/share/consolefonts/Uni2-mido40x30.psf.gz \
         /root/.mido-panel-selftest.txt ; do
  if [ -e "$f" ]; then rm -f "$f" && ok "已删除 $f"; fi
done

# 清掉安装过程中产生的 .preadapt / .bak.* 残留（只动这几个前缀，不碰别的）
find /usr/local/bin /usr/local/share/consolefonts /usr/share/consolefonts \
     -maxdepth 1 \( -name 'battery-panel.sh.*' -o -name 'screen-idle.py.*' \
     -o -name 'mido-30x40.psf.*' -o -name 'Uni2-mido40x30.psf.gz.*' \) \
     -print -delete 2>/dev/null | sed 's/^/    · 已清理 /' || true

step "还原 console-setup 配置"
LATEST=""
[ -d "$BAK_ROOT" ] && LATEST="$(ls -1d "$BAK_ROOT"/*/ 2>/dev/null | sort | tail -1 || true)"
if [ -n "$LATEST" ] && [ -f "${LATEST}etc/default/console-setup" ]; then
  cp -a "${LATEST}etc/default/console-setup" /etc/default/console-setup
  ok "已从 $LATEST 还原 /etc/default/console-setup"
  command -v setupcon >/dev/null 2>&1 && setupcon --force >/dev/null 2>&1 && ok "已重新应用（setupcon）" || true
else
  warn "没找到 console-setup 的备份，保留当前配置（FONTFACE=mido 指向已删除的字体）"
  warn "请手工把 /etc/default/console-setup 里的 FONTFACE/FONTSIZE 改回例如 FONTFACE=\"Terminus\" FONTSIZE=\"16\""
fi

printf '\n%s卸载完成。%s\n' "$C_G" "$C_N"
if [ "$KEEP_BAK" = 1 ]; then
  printf '  备份保留在 %s\n' "$BAK_ROOT"
elif [ -d "$BAK_ROOT" ]; then
  printf '  备份仍在 %s（如需彻底清掉：rm -rf %s）\n' "$BAK_ROOT" "$BAK_ROOT"
fi
printf '  想恢复看板：重新执行 sudo ./install.sh\n'
