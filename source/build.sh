#!/bin/bash
# ============================================================================
# 本地一键重建：字体(psf) + pua.sed + 预编译脚本 + console-setup 用的 gz
#
# 用法（Linux / macOS / git-bash 都可以）：
#     bash build.sh
#
# 依赖：python3 + Pillow + 一款开源等宽字体 + 一款开源中文字体
#     Debian/Ubuntu: sudo apt install python3-pil fonts-dejavu-core fonts-wqy-zenhei
#     Fedora:        sudo dnf install python3-pillow dejavu-sans-mono-fonts wqy-zenhei-fonts
#
# 可覆盖的变量：
#     PY=/path/to/python3  指定解释器（默认自动探测带 Pillow 的那个）
#     SRC=xxx.sh           指定面板源码（默认自动找 battery-panel.src.sh / battery-panel.sh）
# ============================================================================
set -e
cd "$(dirname "$0")"

# ---- 源码文件名 ----
# 仓库里源码叫 battery-panel.src.sh（避免和打包后的运行版同名混淆），
# 开发目录里叫 battery-panel.sh，这里两个都认，避免再出现「引用错文件名」。
SRC="${SRC:-}"
if [ -z "$SRC" ]; then
  for c in battery-panel.src.sh battery-panel.sh; do
    if [ -f "$c" ]; then SRC="$c"; break; fi
  done
fi
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "✗ 找不到面板源码（battery-panel.src.sh / battery-panel.sh），请在本脚本所在目录执行。" >&2
  exit 1
fi

# ---- Python 解释器 ----
# 老版本这里写死了 Windows 上某个 venv 的绝对路径（PY="${PY:-C:/Users/...}"），
# 在别人的 Linux 上必然跑不起来。现在改成：有 $PY 就用 $PY，否则自动探测
# 一个**能 import PIL** 的 python3/python。
pick_py() {
  if [ -n "${PY:-}" ]; then
    printf '%s\n' "$PY"
    return 0
  fi
  # python3 / python 覆盖绝大多数 Linux/macOS；py 是 Windows 的官方启动器
  # （Windows 上 `python` 常常指向 Microsoft Store 的占位程序，装了 Pillow 也未必是它）
  for c in python3 python py; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" -c "import PIL" >/dev/null 2>&1; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}
if ! PY="$(pick_py)"; then
  cat >&2 <<'EOF'
✗ 找不到带 Pillow 的 Python。请先安装 Pillow：
    Debian/Ubuntu: sudo apt install python3-pil
    Fedora:        sudo dnf install python3-pillow
    macOS/Windows: pip3 install pillow
  或者用 PY=/path/to/python3 指定解释器。
EOF
  exit 1
fi
if ! "$PY" -c "import PIL" >/dev/null 2>&1; then
  echo "✗ $PY 无法 import PIL，请换一个带 Pillow 的解释器（或用 PY=... 指定）。" >&2
  exit 1
fi

echo "源码    : $SRC"
echo "Python  : $PY（$("$PY" -c 'import sys; print(sys.version.split()[0])')）"
echo

echo "== 1/3 生成字体 + 预编译脚本 =="
"$PY" mkfont.py "$SRC" out_font \
      --runtime "$SRC" out_font/battery-panel.run.sh

echo
echo "== 2/3 打包 console-setup 用的字体 =="
# -n：不要把「原文件名 + 当前时间」写进 gzip 头。
# 否则字体内容一个字都没改，每次 rebuild 出来的 .gz 哈希都在变，
# 清单里就永远分不清「真改了」还是「只是又跑了一次」。解压结果完全一致。
gzip -9 -n -c out_font/mido-30x40.psf > out_font/Uni2-mido40x30.psf.gz
ls -l out_font/mido-30x40.psf out_font/Uni2-mido40x30.psf.gz out_font/pua.sed

echo
echo "== 3/3 本地自检（假数据渲染一屏，检查有没有溢出/丢边框）=="
PANEL_MOCK=./mock.sh PANEL_ONCE=1 bash "$SRC" panel_raw.txt
"$PY" term.py panel_raw.txt 30 40 preview_latest | tail -4
echo
echo "自检图: preview/preview_latest.png"
