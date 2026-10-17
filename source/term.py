"""把面板脚本的真实输出渲染成 PNG —— 本地「模拟控制台」

原理：跑一遍 battery-panel.sh（用 PANEL_MOCK 灌假数据），把它的字节流
喂给这里的一个小终端模拟器（支持 CSI H/G/J/K/m、CR、LF、末列挂起换行），
再用 mkfont 的渲染器逐格画出来。因为字体、字号、PUA 映射跟手机完全一致，
所以本地看到的就是手机上看到的。

实机实测到的两个关键行为（已在本模拟器里复刻）：
  * CSI K（擦到行尾）用的是**当前背景色**填充 —— 所以 `ESC[44m` + `ESC[K`
    能铺满一整行；但反显（SGR 7）不参与擦除（内核在渲染时才做反显），
    所以 `ESC[7m` + `ESC[K` 铺不满，只擦成默认底色。
  * 帧缓冲亮度档位：正常 170 / 粗体 255 / 暗 85；16 色里前景背景同一套。

用法:
    python term.py <输出文本文件> [W H] [前缀名]
输出:
    preview/<前缀名>.png        整屏
    preview/<前缀名>_top.png    上 1280px（看得清细节）
"""
import os
import re
import sys

from PIL import Image

import mkfont

DIM_LEVEL = 85           # 暗色亮度（实机实测）
NORMAL_LEVEL = 170       # 正常亮度（实机实测）
BOLD_LEVEL = 255         # 粗体亮度（实机实测）

# VGA 16 色在 fbcon 上的实测 RGB（前 8 与后 8 相同，没有高亮背景色）
PALETTE = [
    (0, 0, 0), (170, 0, 0), (0, 170, 0), (170, 85, 0),
    (0, 0, 170), (170, 0, 170), (0, 170, 170), (170, 170, 170),
]

DEFAULT = (7, 0, False, False, False)   # fg, bg, bold, dim, rev


def load_pua(path):
    """读 pua.sed，返回 {PUA字符: 原字符} 的反查表"""
    rev = {}
    if not os.path.exists(path):
        return rev
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            m = re.match(r"^s/(.)/(.)/g$", ln.rstrip("\n"))
            if m:
                rev[m.group(2)] = m.group(1)
    return rev


class Term:
    def __init__(self, cols, rows, pua_rev):
        self.cols, self.rows = cols, rows
        self.pua = pua_rev
        self.grid = [[(" ", DEFAULT) for _ in range(cols)] for _ in range(rows)]
        self.x = self.y = 0
        self.wrap = False
        self.attr = DEFAULT

    # ---------- 屏幕操作 ----------
    def _cls(self):
        self.grid = [[(" ", DEFAULT) for _ in range(self.cols)]
                     for _ in range(self.rows)]

    def _scroll(self):
        self.grid.pop(0)
        self.grid.append([(" ", DEFAULT) for _ in range(self.cols)])

    def _nl(self):
        self.y += 1
        self.x = 0
        self.wrap = False
        if self.y >= self.rows:
            self.y = self.rows - 1
            self._scroll()

    def _put(self, ch):
        if self.wrap:
            self._nl()
        if ch in self.pua:
            ch = self.pua[ch]
        self.grid[self.y][self.x] = (ch, self.attr)
        if self.x + 1 >= self.cols:
            self.wrap = True          # 真机行为：写在最后一格不立刻换行
        else:
            self.x += 1

    def _el(self, mode):
        """CSI K —— 用当前**背景色**填充（反显不参与，见模块注释）"""
        if mode in (0, None):
            rng = range(self.x, self.cols)
        elif mode == 1:
            rng = range(0, self.x + 1)
        else:
            rng = range(0, self.cols)
        for i in rng:
            self.grid[self.y][i] = (" ", self.attr)

    def _sgr(self, params):
        fg, bg, bold, dim, rev = self.attr
        if not params:
            params = [0]
        for p in params:
            if p == 0:
                fg, bg, bold, dim, rev = DEFAULT
            elif p == 1:
                bold = True
            elif p == 2:
                dim = True
            elif p == 7:
                rev = True
            elif p == 22:
                bold = dim = False
            elif p == 27:
                rev = False
            elif 30 <= p <= 37:
                fg = p - 30
            elif p == 39:
                fg = 7
            elif 40 <= p <= 47:
                bg = p - 40
            elif p == 49:
                bg = 0
            elif 90 <= p <= 97:
                fg = p - 90
            elif 100 <= p <= 107:
                bg = p - 100
        self.attr = (fg, bg, bold, dim, rev)

    # ---------- 解析 ----------
    def feed(self, text):
        i, n = 0, len(text)
        while i < n:
            ch = text[i]
            if ch == "\x1b":
                i = self._csi(text, i + 1)
                continue
            if ch == "\r":
                self.x = 0
                self.wrap = False
            elif ch == "\n":
                self._nl()
            elif ch == "\b":
                self.x = max(0, self.x - 1)
                self.wrap = False
            elif ch == "\t":
                self.x = min(self.cols - 1, (self.x // 8 + 1) * 8)
            elif ord(ch) < 0x20 or ord(ch) == 0x7F:
                pass
            else:
                self._put(ch)
            i += 1

    def _csi(self, text, i):
        if i >= len(text):
            return i
        if text[i] != "[":
            return i + 1                     # 非 CSI（如 ESC c），跳过
        j = i + 1
        while j < len(text) and (text[j].isdigit() or text[j] in ";?>"):
            j += 1
        if j >= len(text):
            return j
        final = text[j]
        raw = text[i + 1:j].lstrip("?>").strip(";")
        params = [int(x) if x.isdigit() else None
                  for x in raw.split(";")] if raw else []
        if final in "Hf":
            r = (params[0] or 1) if params else 1
            c = (params[1] or 1) if len(params) > 1 else 1
            self.y = min(self.rows - 1, max(0, r - 1))
            self.x = min(self.cols - 1, max(0, c - 1))
            self.wrap = False
        elif final == "G":
            c = (params[0] or 1) if params else 1
            self.x = min(self.cols - 1, max(0, c - 1))
            self.wrap = False
        elif final == "A":
            self.y = max(0, self.y - ((params[0] or 1) if params else 1))
            self.wrap = False
        elif final == "B":
            self.y = min(self.rows - 1, self.y + ((params[0] or 1) if params else 1))
            self.wrap = False
        elif final == "C":
            self.x = min(self.cols - 1, self.x + ((params[0] or 1) if params else 1))
            self.wrap = False
        elif final == "D":
            self.x = max(0, self.x - ((params[0] or 1) if params else 1))
            self.wrap = False
        elif final == "J":
            m = params[0] if params else 0
            if m == 2:
                self._cls()
            elif m == 0:
                for r in range(self.y, self.rows):
                    c0 = self.x if r == self.y else 0
                    for c in range(c0, self.cols):
                        self.grid[r][c] = (" ", DEFAULT)
            elif m == 1:
                for r in range(0, self.y + 1):
                    c1 = self.x if r == self.y else self.cols - 1
                    for c in range(0, c1 + 1):
                        self.grid[r][c] = (" ", DEFAULT)
        elif final == "K":
            self._el(params[0] if params else 0)
        elif final == "m":
            self._sgr(params)
        return j + 1

    # ---------- 渲染 ----------
    def _colors(self, attr):
        """返回 (文字色, 背景色)"""
        fg, bg, bold, dim, rev = attr
        f = list(PALETTE[fg])
        b = list(PALETTE[bg])
        if bold:
            f = [BOLD_LEVEL if v else 0 for v in f]
        elif dim:
            f = [v * DIM_LEVEL // max(1, NORMAL_LEVEL) for v in f]
        if rev:
            f, b = b, f
        return tuple(f), tuple(b)

    def render(self, W, H, scale=1):
        ascii_size, cjk_size, sym_size, adv = mkfont.metrics(W, H)
        cache = {}
        canvas = Image.new("RGB", (self.cols * W, self.rows * H), (0, 0, 0))
        for r in range(self.rows):
            for c in range(self.cols):
                ch, attr = self.grid[r][c]
                fcol, bcol = self._colors(attr)
                if bcol != (0, 0, 0):
                    canvas.paste(bcol, (c * W, r * H, (c + 1) * W, (r + 1) * H))
                if ch == " ":
                    continue
                key = ch
                mask = cache.get(key)
                if mask is None:
                    g = mkfont.render(ch, W, H, ascii_size, cjk_size, adv, sym_size)
                    mask = g.convert("1")
                    cache[key] = mask
                if fcol == (0, 0, 0):
                    if bcol == (0, 0, 0):
                        continue
                    # 黑字落在有色底上：把底色刷成文字色区域
                    canvas.paste((0, 0, 0), (c * W, r * H, (c + 1) * W, (r + 1) * H),
                                 mask)
                else:
                    canvas.paste(fcol, (c * W, r * H, (c + 1) * W, (r + 1) * H), mask)
        return canvas

    def report(self):
        """报告每行内容的列范围，用来抓「内容溢出 / 右边框缺失」"""
        bad = []
        expected = set("│┐┤┘╮╯")          # 含圆角外框的 ╮ ╯
        for r in range(self.rows):
            cols = [c for c in range(self.cols) if self.grid[r][c][0] != " "]
            edge = self.grid[r][self.cols - 1][0]
            note = ""
            if not cols:
                note = "  <== 整行空（丢内容了？）"
                bad.append(r + 1)
            elif edge not in expected:
                note = "  <== 第 %d 列不是边框(是 %r)" % (self.cols, edge)
                bad.append(r + 1)
            lo = (cols[0] + 1) if cols else 0
            hi = (cols[-1] + 1) if cols else 0
            print("  %2d | 列 %2d..%-2d 共 %-2d 个非空格%s"
                  % (r + 1, lo, hi, len(cols), note))
        return bad


def main():
    src = sys.argv[1]
    W = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    H = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    name = sys.argv[4] if len(sys.argv) > 4 else "term"

    cols, rows = 1080 // W, 1920 // H
    pua = load_pua(os.path.join("out_font", "pua.sed"))
    with open(src, encoding="utf-8", errors="replace") as fh:
        data = fh.read()

    t = Term(cols, rows, pua)
    t.feed(data)
    bad = t.report()
    print("\n屏幕 %d 列 x %d 行，异常行: %s"
          % (cols, rows, bad if bad else "无 ✓"))

    img = t.render(W, H)
    os.makedirs("preview", exist_ok=True)
    full = "preview/%s.png" % name
    img.save(full)
    img.crop((0, 0, cols * W, min(rows * H, 1280))).save("preview/%s_top.png" % name)
    print("saved %s  (%dx%d)" % (full, cols * W, rows * H))
    return 0


if __name__ == "__main__":
    sys.exit(main())
