#!/bin/bash
# ============================================================================
# 本地一键重建：字体(psf) + pua.sed + 预编译脚本 + console-setup 用的 gz
#
# 改完 battery-panel.sh 之后跑这个，再跑 deploy.py 推送到手机。
# ============================================================================
set -e
cd "$(dirname "$0")"
PY="${PY:-C:/Users/Zy/.workbuddy/binaries/python/envs/default/Scripts/python.exe}"

echo "== 1/3 生成字体 + 预编译脚本 =="
"$PY" mkfont.py battery-panel.sh out_font \
      --runtime battery-panel.sh out_font/battery-panel.run.sh

echo
echo "== 2/3 打包 console-setup 用的字体 =="
# -n：不要把「原文件名 + 当前时间」写进 gzip 头。
# 否则字体内容一个字都没改，每次 rebuild 出来的 .gz 哈希都在变，
# 清单里就永远分不清「真改了」还是「只是又跑了一次」。解压结果完全一致。
gzip -9 -n -c out_font/mido-30x40.psf > out_font/Uni2-mido40x30.psf.gz
ls -l out_font/mido-30x40.psf out_font/Uni2-mido40x30.psf.gz out_font/pua.sed

echo
echo "== 3/3 本地自检（假数据渲染一屏，检查有没有溢出/丢边框）=="
PANEL_MOCK=mock.sh PANEL_ONCE=1 bash battery-panel.sh panel_raw.txt
"$PY" term.py panel_raw.txt 30 40 preview_latest | tail -4
echo
echo "自检图: preview/preview_latest.png"
