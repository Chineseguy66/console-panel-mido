"""从面板脚本里提取字符集，生成 PSF2 控制台位图字体（含中文），并可选地
把面板脚本「预编译」成 PUA 码点版本（去掉运行时的 sed 过滤）。

用法:
    python mkfont.py <源文本文件> <输出目录> [--runtime <源脚本> <输出脚本>]
                     [--font-mono <等宽字体>] [--font-cjk <中文字体>]

字体策略（**只用开源字体**）:
    - ASCII(0x20-0x7E) 用 DejaVu Sans Mono（Bitstream Vera 许可），按格子高度定字号
    - 中文/全角     用 文泉驿正黑 / Noto Sans CJK，按格子宽度定字号后纵向拉伸填满格子
    - 制表符(┌─┐│└┘├┤)  程序化绘制，保证 36 格拼起来完全无缝
    - 图形符号(●○◆▲✓) 用中文字体居中绘制，不拉伸（保持正圆/正方）
    - █(U+2588) / ░(U+2591) 程序化绘制，保证进度条锐利

为什么不用 Consolas / 微软雅黑：两者都是微软专有字体，把它们渲染出的点阵字体
随源码分发有版权风险（上游 review 明确指出）。现在的两个替代品都可自由分发：
    DejaVu Sans Mono —— Bitstream Vera / DejaVu 许可
    文泉驿正黑      —— GPLv2+，带字体嵌入例外（font embedding exception）
    Noto Sans CJK   —— SIL Open Font License 1.1

字体来源（任选其一，或自己装好后用 --font-mono/--font-cjk 指定路径）：
    Debian/Ubuntu: sudo apt install fonts-dejavu-core fonts-wqy-zenhei
    Fedora:        sudo dnf install dejavu-sans-mono-fonts wqy-zenhei-fonts
    也可把字体放到本文件同级的 fonts/ 目录（DejaVuSansMono.ttf / wqy-zenhei.ttc）
"""
import json
import math
import os
import struct
import sys
import unicodedata

from PIL import Image, ImageDraw, ImageFont

# ── 字体解析 ────────────────────────────────────────────────────────────────
# 优先级：命令行参数 > 环境变量 > 工程内 fonts/ 副本 > 系统常见路径。
# 找不到就**直接报错退出**，并打印安装提示 —— 绝不悄悄回退到微软字体。
_HERE = os.path.dirname(os.path.abspath(__file__))
_FONT_DIR = os.path.join(_HERE, "fonts")

MONO_CANDIDATES = [
    os.path.join(_FONT_DIR, "DejaVuSansMono.ttf"),
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
]

CJK_CANDIDATES = [
    os.path.join(_FONT_DIR, "wqy-zenhei.ttc"),
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    "/usr/share/fonts/wqy-zenhei/wqy-zenhei.ttc",
    "/usr/share/fonts/truetype/arphic/uming.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
]


def pick_font(candidates, kind, env, flag, override=""):
    """返回一个可用的字体路径。

    优先级：命令行参数 > 环境变量 > 候选路径列表。
    ⚠ 必须把 override 放在**最前面判断**：早期版本在 import 阶段就调用了本函数，
      结果「机器上一款都没有」时直接 SystemExit，用户按提示加 `--font-mono /path`
      也救不回来 —— 因为参数还没解析。现在改成 main() 里解析完参数再解析字体。
    """
    if override:
        if not os.path.isfile(override):
            raise SystemExit("✗ %s 指定的字体不存在：%s" % (flag, override))
        return override
    custom = os.environ.get(env) or ""
    if custom:
        if not os.path.isfile(custom):
            raise SystemExit("✗ %s=%s 指向的文件不存在" % (env, custom))
        return custom
    for p in candidates:
        if p and os.path.isfile(p):
            return p
    pkg = "fonts-dejavu-core fonts-wqy-zenhei" if kind == "mono" else "fonts-wqy-zenhei"
    raise SystemExit(
        "✗ 没找到可用的%s字体（本项目只使用开源字体，不再使用 Consolas / 微软雅黑）。\n"
        "  安装办法：sudo apt install %s\n"
        "  或用参数指定：mkfont.py ... %s /path/to/font\n"
        "  也可把字体放到 %s\n"
        "  已尝试的路径：\n    %s"
        % ("等宽" if kind == "mono" else "中文", pkg, flag, _FONT_DIR,
           "\n    ".join(candidates)))


# 由 resolve_fonts() 在解析完命令行参数后填（见文件末尾 main()）
CODE_FONT = None
CJK_FONT = None


def resolve_fonts(mono="", cjk=""):
    """解析两个字体路径并写入全局。任何一款都不可用就直接退出，不做静默回退。"""
    global CODE_FONT, CJK_FONT
    CODE_FONT = pick_font(MONO_CANDIDATES, "mono", "PANEL_FONT_MONO", "--font-mono", mono)
    CJK_FONT = pick_font(CJK_CANDIDATES, "cjk", "PANEL_FONT_CJK", "--font-cjk", cjk)
    return CODE_FONT, CJK_FONT

# (宽, 高) —— 必须能整除 1080x1920，否则 console 会留黑边
CANDIDATES = [(30, 40)]

FULL_BLOCK = 0x2588
LIGHT_SHADE = 0x2591
H_LINE = 0x2500
V_LINE = 0x2502
BOX_DRAW = {
    0x250C: ("R", "D"),   # ┌ 右 + 下
    0x2510: ("L", "D"),   # ┐ 左 + 下
    0x2514: ("R", "U"),   # └ 右 + 上
    0x2518: ("L", "U"),   # ┘ 左 + 上
    0x251C: ("R", "UD"),  # ├ 右 + 上下
    0x2524: ("L", "UD"),  # ┤ 左 + 上下
}
# 圆角外框（╭ ╮ ╯ ╰）：四分之一圆弧 + 两根短直线段。
# 弧心放在「水平线 y」和「垂直线 x」各自内缩 R 的位置，这样弧与直线相切，
# 拼起来看不出接缝。用它做「现代卡片」质感的外框。
ROUND_DRAW = {
    0x256D: ("L", "D"),   # ╭ 弧在右下方向
    0x256E: ("R", "D"),   # ╮
    0x2570: ("L", "U"),   # ╰
    0x256F: ("R", "U"),   # ╯
}
ROUND_R = 12              # 圆角半径（像素）
BOX_THICK = 3             # 线宽（像素）
SYM_CJK = "●○◆◇■□▲▼"
THRESHOLD = 110
STRETCH_CAP = 1.30      # 汉字纵向拉伸上限，避免变形过大
STRETCH_MAX = 1.25      # ASCII 横向拉伸上限（超过就居中留白，避免字形变形）
H_STRETCH = True        # ASCII 是否横向拉伸填满格子

# fbcon 只接受 charcount 为 256 或 512 的字体（见 fbcon_set_font）。
# 用 512 槽，并让「第 32 号位置 = 空格」以符合 kbd/console-setup 惯例
# （否则 setfont 会警告 "font position 32 is nonblank"）。
CHARS = 512
ASCII_BASE = 32          # 0x20 空格落在 512 槽里的下标
PAD_LO = 0xE000          # 填充槽用的私用区码点
BLANK_LO = 0xE100        # 前置空槽用的私用区码点
PUA_LO = 0xF000          # 内核「直接字形索引」区间起点（见下）
PUA_LIMIT = PUA_LO + 511

# ── 为什么要搞「直接槽位」别名 ────────────────────────────────────────
# 内核把 CJK 当「双宽」字符：光标前进 2 格，但字形只画在左边那 1 格里，
# 右边留空。实测 6 个汉字占 12 个 ASCII 数字的宽度，看起来又稀又像竖排。
#
# 内核 consolemap.c 里有两行关键定义：
#     #define UNI_DIRECT_BASE 0xF000   /* 私用区这段是「直接字形索引」 */
#     #define UNI_DIRECT_MASK 0x01FF   /* 掩码 9 位 -> 槽位 0..511 */
# 落在 U+F000..U+F1FF 的码点会绕过 unicode 映射表，直接拿
#     槽位号 = (码点 - 0xF000) & 0x1FF
# 当字形索引。所以只要给某个槽位配一个 0xF000+槽位号 的码点，
# 输出这个码点就能画出那个槽位的字形 —— 而它在宽度表里是「窄」，
# 内核只给它 1 格，汉字于是紧凑渲染。
#
# 做法：每个用到的汉字在原码点占 1 槽（保底），再在 PUA 区间占 1 槽，
# **别名码点 = 0xF000 + 别名槽位的真实下标**。
# 解析期（本脚本 gen_runtime）把面板源码里的汉字换成别名码点，
# 运行期直接打印，零转换开销。

EXTRA_SYMBOLS = (
    "─│┌┐└┘├┤╭╮╰╯━│●○◆◇■□▲▼"
    "°±×÷·§↑↓←→"
    "█░▓▒"
)

# 常用汉字/词，给"以后改面板文案"留余量，避免缺字变方块。
# 512 槽里除 ASCII + 空槽外只剩 385 格，超出的会被截掉。
COMMON_CJK = (
    "电池量充放压温度流健康上输限系统内存交换磁盘进程运行青龙服务端口网络"
    "正常异常连接失败等待错误成功启停负载使用剩余总共平均速度时间日期星期秒分小时天月年"
    "关闭开启设置配置检测完成正在加载中数据信息状态容量可用占比超过低于高低快慢涓流保护"
    "警告提示请稍等后更多详情重启打开删除添加修改保存退出返回确认取消是否无有则刚已未将要"
    "缓存线程队列任务日志版本升级备份恢复镜像容器地址掩码网关域名解析上传下载同步"
    "密码账号登出权限角色用户管理列表页图标选项切换刷新停止开始暂停继续循环间隔延迟"
    "功耗频率核心超频降频散热风扇屏幕亮度音量静音飞行模式省电性能均衡"
    "今日昨日本月今年上一下周报季度分钟毫秒微秒纳秒"
    "即时瞬时损耗设计规格快充标准专用下行配件输入截止恒流当前生效设定非值"
    "看板局域网内网穿透其他主板每核平均放电为正负极"
)


def _dedup(items, seen):
    out = []
    for ch in items:
        if ch not in seen:
            seen.add(ch)
            out.append(ch)
    return out


def split_comment(ln):
    """把一行拆成 (代码部分, 注释部分)。

    只按「整行注释」过滤是不够的：行尾注释（`TO_SYSFS=1  # 内核 sysfs 单值`）
    也会被算进字符集，实测这会把需要「额外槽位」的汉字从 243 个推到 263 个，
    名额用光后 EXTRA_SYMBOLS 被截掉，结果 `─┌┐├┤●○█░·` 全部掉成方块
    （屏幕上表现为内核回退成 `- + * #`）。
    所以这里连行尾注释一起去掉。带引号状态跟踪，避免把字符串里的 # 当注释。
    """
    out = []
    q = None
    for i, ch in enumerate(ln):
        if q:
            out.append(ch)
            if ch == q:
                q = None
        elif ch in ("'", '"'):
            q = ch
            out.append(ch)
        elif ch == "#" and (i == 0 or ln[i - 1] in " \t"):
            break
        else:
            out.append(ch)
    code = "".join(out)
    return code, ln[len(code):]


def code_only(text):
    """只保留代码行，丢掉整行注释**和行尾注释**。

    面板脚本里有大段中文注释；如果不剔除，字符集会被注释里的汉字撑爆
    （实测 battery-panel.sh 有 198 个汉字，而真正出现在输出里的只有 38 个），
    512 个槽位要同时放「原码点槽 + 别名槽」根本装不下。
    """
    out = []
    for ln in text.split("\n"):
        if ln.lstrip().startswith("#"):
            continue
        out.append(split_comment(ln)[0])
    return "\n".join(out)


def collect_alias(text):
    """返回需要「紧凑别名」的字符：面板里实际用到的汉字/全角字

    这些字符额外占一个 PUA 槽，渲染时用 PUA 码点换取 1 格宽的紧凑排版。
    """
    seen = set()
    out = []
    for ch in text:
        if ord(ch) > 0x7E and is_wide(ch) and ch not in seen:
            seen.add(ch)
            out.append(ch)
    return out


def collect_chars(text, reserve=0):
    """返回「扩展字符」有序列表（ASCII 由 layout 固定生成）

    ⚠ 顺序很重要：**常用符号必须排在最前面**。
    这里有个坑：名额定死（512 槽 - ASCII - PUA 别名 - 1），超出就从尾部截断。
    如果符号排在汉字后面，一旦汉字变多，`─┌┐├┤●○█░` 就会被截掉，
    屏幕上表现为内核回退成 `- + * #`（很难一眼看出是字体缺字）。
    """
    seen = set()
    extras = []
    extras += _dedup(EXTRA_SYMBOLS, seen)          # 先占位，保证不会被截掉
    extras += _dedup([c for c in text if ord(c) > 0x7E], seen)
    extras += _dedup(COMMON_CJK, seen)
    cap = CHARS - ASCII_BASE - 95 - reserve - 1
    if len(extras) > cap:
        extras = extras[:cap]
    return extras


def fit_by_width(draw, text, path, max_w, index=0, advance=False):
    """在宽度约束下找最大字号"""
    lo, hi, best = 6, 400, None
    while lo <= hi:
        mid = (lo + hi) // 2
        try:
            f = ImageFont.truetype(path, mid, index=index)
        except Exception:
            break
        bb = draw.textbbox((0, 0), text, font=f)
        w = round(f.getlength(text)) if advance else bb[2] - bb[0]
        if w <= max_w:
            best = (mid, f, bb)
            lo = mid + 1
        else:
            hi = mid - 1
    return best


def fit_by_height(draw, text, path, max_h, index=0):
    """在高度约束下找最大字号"""
    lo, hi, best = 6, 400, None
    while lo <= hi:
        mid = (lo + hi) // 2
        try:
            f = ImageFont.truetype(path, mid, index=index)
        except Exception:
            break
        bb = draw.textbbox((0, 0), text, font=f)
        if bb[3] - bb[1] <= max_h:
            best = (mid, f, bb)
            lo = mid + 1
        else:
            hi = mid - 1
    return best


def to_bit(gray):
    return gray.point(lambda v: 255 if v >= THRESHOLD else 0, "1")


def is_wide(ch):
    """全角/东亚宽字符 -> 需要按汉字方式处理"""
    return unicodedata.east_asian_width(ch) in ("W", "F")


def render_latin(ch, size, W, H, adv):
    """拉丁/符号：统一基线排版，保证小数点、冒号不被居中到格子中间

    adv = 该字号下等宽字体的步进宽度。整块画布 (adv x H) 再等比拉伸到 W，
    这样等宽间距保持不变，同时横向填满格子（否则 24~30 宽的格子里
    只有 ~21px 有墨迹，字符之间会空一大块）。
    """
    f = ImageFont.truetype(CODE_FONT, size)
    ascent, descent = f.getmetrics()
    y_base = (H - (ascent + descent)) // 2 + ascent
    cw = max(1, int(round(adv)))
    tmp = Image.new("L", (cw, H), 0)
    ImageDraw.Draw(tmp).text((0, y_base), ch, font=f, fill=255, anchor="ls")

    if not H_STRETCH:
        out = Image.new("L", (W, H), 0)
        out.paste(tmp, ((W - cw) // 2, 0))
        return to_bit(out)

    tw = min(W, max(cw, int(round(cw * STRETCH_MAX))))
    tmp = tmp.resize((tw, H), Image.LANCZOS)
    if tw != W:
        out = Image.new("L", (W, H), 0)
        out.paste(tmp, ((W - tw) // 2, 0))
        tmp = out
    return to_bit(tmp)


def render_cjk(ch, size, W, H):
    """汉字：按格子宽度定字号，再纵向拉伸，但限制拉伸倍数避免变形过大"""
    tmp = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(tmp)
    f = ImageFont.truetype(CJK_FONT, size)
    bb = d.textbbox((0, 0), ch, font=f)
    x = (W - (bb[2] - bb[0])) // 2 - bb[0]
    d.text((x, 0), ch, font=f, fill=255)
    ink = tmp.crop(tmp.getbbox())
    if not ink.width or not ink.height:
        return to_bit(tmp)

    # 目标：尽量填满格子，但纵向拉伸不超过 STRETCH_CAP 倍
    factor = min(float(H - 2) / ink.height, STRETCH_CAP)
    tw = max(1, ink.width)
    th = max(1, int(round(ink.height * factor)))
    ink = ink.resize((tw, th), Image.LANCZOS)

    out = Image.new("L", (W, H), 0)
    out.paste(ink, ((W - tw) // 2, (H - th) // 2))
    return to_bit(out)


def render_symbol(ch, size, W, H):
    """图形符号（●○▲✓ 等）：居中绘制，等比缩放，不做纵向拉伸"""
    f = ImageFont.truetype(CJK_FONT, size)
    tmp = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(tmp)
    bb = d.textbbox((0, 0), ch, font=f)
    x = (W - (bb[2] - bb[0])) // 2 - bb[0]
    y = (H - (bb[3] - bb[1])) // 2 - bb[1]
    d.text((x, y), ch, font=f, fill=255)
    return to_bit(tmp)


def _arc(d, cx, cy, r, a0, a1, t):
    """用短线段近似一段圆弧（避免依赖 Pillow 的 arc(width=) 版本差异）"""
    n = 28
    pts = []
    for k in range(n + 1):
        a = math.radians(a0 + (a1 - a0) * k / n)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    for k in range(len(pts) - 1):
        d.line([pts[k], pts[k + 1]], fill=1, width=t, joint="curve")


def render_round(cp, W, H):
    """圆角外框 ╭ ╮ ╰ ╯：四分之一圆弧 + 两根短直线

    弧心取 (水平线 y 内缩 R, 垂直线 x 内缩 R)，使弧与直线相切；
    直线段只画「弧端点到格子边缘」那一小截，剩下的交给相邻格子的 ─ / │，
    这样一拼起来完全无缝。
    """
    img = Image.new("1", (W, H), 0)
    d = ImageDraw.Draw(img)
    cx, cy = W // 2, H // 2                  # 框线的位置（格子中线）
    t = BOX_THICK
    r = min(ROUND_R, W, H // 2)
    hdir, vdir = ROUND_DRAW[cp]
    acx = cx + r if hdir == "L" else cx - r  # 弧心 x
    acy = cy + r if vdir == "D" else cy - r  # 弧心 y

    # 四分之一弧：按「弧心在格子的哪一侧」决定角度区间
    if hdir == "L" and vdir == "D":          # ╭
        _arc(d, acx, acy, r, 180, 270, t)
    elif hdir == "R" and vdir == "D":        # ╮
        _arc(d, acx, acy, r, 270, 360, t)
    elif hdir == "R" and vdir == "U":        # ╯
        _arc(d, acx, acy, r, 0, 90, t)
    else:                                    # ╰
        _arc(d, acx, acy, r, 90, 180, t)

    # 短直线段：垂直方向接到本格的上/下边缘，水平方向接到左/右边缘
    vx0, vx1 = cx - t // 2, cx - t // 2 + t - 1
    hy0, hy1 = cy - t // 2, cy - t // 2 + t - 1
    if vdir == "D":
        d.rectangle([vx0, acy, vx1, H - 1], fill=1)
    else:
        d.rectangle([vx0, 0, vx1, acy], fill=1)
    if hdir == "L":
        d.rectangle([acx, hy0, W - 1, hy1], fill=1)
    else:
        d.rectangle([0, hy0, acx, hy1], fill=1)
    return img


def render_box(cp, W, H):
    """制表符程序化绘制：保证相邻格子拼起来严丝合缝"""
    img = Image.new("1", (W, H), 0)
    d = ImageDraw.Draw(img)
    cx, cy = W // 2, H // 2
    t = BOX_THICK
    hx0, hx1 = 0, W - 1                       # 水平线贯穿整格
    vy0, vy1 = 0, H - 1                       # 垂直线贯穿整格
    hy0, hy1 = cy - t // 2, cy - t // 2 + t - 1
    vx0, vx1 = cx - t // 2, cx - t // 2 + t - 1

    if cp == H_LINE:                          # ─
        d.rectangle([hx0, hy0, hx1, hy1], fill=1)
    elif cp == V_LINE:                        # │
        d.rectangle([vx0, vy0, vx1, vy1], fill=1)
    else:
        hdir, vdir = BOX_DRAW[cp]
        hx0 = 0 if hdir == "L" else vx0
        hx1 = vx1 if hdir == "L" else W - 1
        vy0 = 0 if vdir == "U" else hy0
        vy1 = hy1 if vdir == "U" else H - 1
        d.rectangle([vx0, vy0, vx1, vy1], fill=1)
        d.rectangle([hx0, hy0, hx1, hy1], fill=1)
    return img


def render(ch, W, H, ascii_size, cjk_size, adv, sym_size=None):
    ensure_fonts()          # 见 ensure_fonts 的说明（term.py 不经过 main）
    cp = ord(ch)
    if cp == FULL_BLOCK:
        img = Image.new("1", (W, H), 0)
        ImageDraw.Draw(img).rectangle([0, 0, W - 1, H - 1], fill=1)
        return img
    if cp == LIGHT_SHADE:
        img = Image.new("1", (W, H), 0)
        px = img.load()
        for y in range(H):
            for x in range(W):
                if (x + y) % 2 == 0:
                    px[x, y] = 1
        return img
    if cp == H_LINE or cp == V_LINE or cp in BOX_DRAW:
        return render_box(cp, W, H)
    if cp in ROUND_DRAW:
        return render_round(cp, W, H)
    if ch in SYM_CJK:
        return render_symbol(ch, sym_size or cjk_size, W, H)
    if is_wide(ch):
        return render_cjk(ch, cjk_size, W, H)
    return render_latin(ch, ascii_size, W, H, adv)


def verify_slots(slots, alias_map, text):
    """自查：面板要用的每个非 ASCII 字符，字体里到底有没有？

    漏字的症状很隐蔽 —— 内核会回退成别的字形（`─` 变 `-`、`●` 变 `*`），
    看上去像「渲染风格不同」而不像缺字，很容易被忽略。所以这里硬检查。
    """
    have = set(cp for c, cp in slots if c is not None)
    missing = []
    seen = set()
    for ch in list(EXTRA_SYMBOLS) + list(text):
        if ord(ch) <= 0x7E or ch in seen:
            continue
        seen.add(ch)
        if ord(ch) in have or ch in alias_map:
            continue
        missing.append(ch)
    return missing


def layout(extras, alias):
    """把字符排进 512 槽：
    前置空槽 -> ASCII(0x20..0x7E) -> 扩展字 -> 汉字 PUA 别名 -> 尾部填充

    返回 (slots, alias_map)，slots 长度固定 CHARS。
    空槽(blank) 也给它一个私用区码点，避免 unicode 表里出现空条目。
    """
    slots = []
    for i in range(ASCII_BASE):
        slots.append((None, BLANK_LO + i))
    for cp in range(0x20, 0x7F):
        slots.append((chr(cp), cp))
    for c in extras:
        slots.append((c, ord(c)))
    # 汉字「直接槽位」别名：别名码点 = PUA_LO + 该字形的真实槽位下标
    # （内核会把它当成直接字形索引，所以码点必须跟着槽位号走）
    alias_map = {}
    for c in alias:
        idx = len(slots)
        cp = PUA_LO + idx
        if cp > PUA_LIMIT:
            raise SystemExit("别名槽位越界：槽位 %d 超出 U+F1FF 能表达的范围" % idx)
        slots.append((c, cp))
        alias_map[c] = cp
    if len(slots) > CHARS:
        raise SystemExit("字符太多，%d 个放不进 %d 槽" % (len(slots), CHARS))
    i = 0
    while len(slots) < CHARS:
        slots.append((None, PAD_LO + i))
        i += 1
    return slots, alias_map


def to_psf2(imgs, codepoints, W, H):
    stride = (W + 7) // 8
    charsize = stride * H
    out = bytearray()
    # magic 是字节序列 72 B5 4A 86，不能用小端 u32 打包（会变成 86 4A B5 72）
    out += struct.pack("<4B", 0x72, 0xB5, 0x4A, 0x86)
    out += struct.pack("<7I", 0, 32, 1, len(imgs), charsize, H, W)
    for img in imgs:
        px = img.load()
        for y in range(H):
            bits = [1 if px[x, y] else 0 for x in range(W)]
            for b in range(stride):
                val = 0
                for k in range(8):
                    i = b * 8 + k
                    if i < W and bits[i]:
                        val |= 1 << (7 - k)
                out.append(val)
    # kbd 的 psf2 unicode 表是「UTF-8 编码的码点 + 0xFF 终止符」，
    # 不是 UTF-16。多字节码点（如汉字 e5 9b bd）整体写完再补一个 0xFF。
    for cp in codepoints:
        if cp == 0:
            out += b"\xff"
            continue
        out += chr(cp).encode("utf-8")
        out += b"\xff"
    return bytes(out)


def ensure_fonts():
    """字体还没解析过就按默认优先级解析一次。

    为什么需要它：字体解析被挪到了 main()（这样 `--font-mono` 才救得回
    「本机一款开源字体都没有」的情况），但 term.py 是 `import mkfont` 后直接
    调 metrics()/render() 的 —— 它不走 main()，全局字体就会是 None，
    报一个 `'NoneType' object has no attribute 'read'` 的怪错。
    """
    if CODE_FONT is None or CJK_FONT is None:
        resolve_fonts()


def metrics(W, H):
    """算出该尺寸下的三个字号（ASCII / 汉字 / 图形符号）"""
    ensure_fonts()
    probe = Image.new("L", (W, H), 0)
    pd = ImageDraw.Draw(probe)
    h_lim = fit_by_height(pd, "Wgj|", CODE_FONT, H - 1)
    ascii_size = h_lim[0] if h_lim else 8
    c_lim = fit_by_width(pd, "国", CJK_FONT, W)
    cjk_size = c_lim[0] if c_lim else 8
    s_lim = fit_by_width(pd, "●", CJK_FONT, min(W, H) - 4)
    sym_size = s_lim[0] if s_lim else cjk_size
    adv = ImageFont.truetype(CODE_FONT, ascii_size).getlength("M")
    return ascii_size, cjk_size, sym_size, adv


def build(chars, alias, W, H, out_path):
    ascii_size, cjk_size, sym_size, adv = metrics(W, H)
    slots, alias_map = layout(chars, alias)
    imgs = []
    for ch, _cp in slots:
        if ch is None:
            imgs.append(Image.new("1", (W, H), 0))
        else:
            imgs.append(render(ch, W, H, ascii_size, cjk_size, adv, sym_size))
    data = to_psf2(imgs, [cp for _ch, cp in slots], W, H)
    with open(out_path, "wb") as fh:
        fh.write(data)

    cols, rows = 1080 // W, 1920 // H
    ratio = W / adv if adv else 0
    print(
        "%-18s 槽位%-4d 格子%dx%d ascii%d(步进%.1f 横拉%.2f) 汉字%d 符号%d 别名%d -> %dx%d格 %.1fKB"
        % (os.path.basename(out_path), len(imgs), W, H, ascii_size, adv, ratio,
           cjk_size, sym_size, len(alias_map), cols, rows, len(data) / 1024.0)
    )
    return alias_map, slots


def write_alias_map(alias_map, path):
    """生成 sed 脚本：把面板源码里的汉字换成 1 格宽的 PUA 码点

    输出形如  s/电/<U+F000>/g   —— 左侧是源码里的汉字（UTF-8），
    右侧是 PUA 字符本身（UTF-8 字节），逐字节替换，C locale 下也安全。

    注意两点：
      * 必须用 LF 换行（Windows 默认的 CRLF 会让 sed 把 \\r 当成命令的一部分而报错）
      * 不写注释行（POSIX sed 不支持 # 注释，某些发行版会直接报错）
    """
    lines = []
    for ch, cp in sorted(alias_map.items(), key=lambda kv: kv[1]):
        lines.append("s/%s/%s/g" % (ch, chr(cp)))
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    return path


RUNTIME_HEADER = """#!/bin/bash
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
"""


def gen_runtime(src_path, out_path, alias_map):
    """把面板源码「预编译」成 PUA 码点版：去掉运行期的 sed 过滤

    细节：**整行注释保持原样**（注释不会被打印），所以部署后的脚本
    大体上仍然可读，只有真正会输出的中文字面量变成了 PUA。
    """
    with open(src_path, "r", encoding="utf-8") as fh:
        text = fh.read()

    out = []
    missing = set()
    for ln in text.split("\n"):
        if ln.lstrip().startswith("#"):
            out.append(ln)               # 整行注释原样保留，便于人读
            continue
        code, cmt = split_comment(ln)    # 行尾注释也原样保留
        buf = []
        for ch in code:
            cp = ord(ch)
            if cp <= 0x7E:
                buf.append(ch)
            elif ch in alias_map:
                buf.append(chr(alias_map[ch]))
            else:
                if is_wide(ch):
                    missing.add(ch)
                buf.append(ch)           # 符号（─ █ ° 等）保持原码点
        out.append("".join(buf) + cmt)

    body = "\n".join(out)
    if body.startswith("#!"):
        body = body.split("\n", 1)[1]
    # 关键一步：把运行期的 sed 过滤关掉（屏幕上的汉字已经是紧凑码点了）
    if "PUA_SED=" in body:
        body = body.replace(
            "PUA_SED=/usr/local/share/consolefonts/pua.sed",
            'PUA_SED=""  # cleared by generator: precompiled, no runtime filter')
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(RUNTIME_HEADER + body.lstrip("\n"))
    return sorted(missing)


def main():
    args = sys.argv[1:]
    runtime = None
    if "--runtime" in args:
        i = args.index("--runtime")
        runtime = (args[i + 1], args[i + 2])
        del args[i:i + 3]

    # --extra FILE：额外的字符来源（设置页的文案在 mido_ui.py 里，不在面板源码里）。
    #   直接拼进来参与「选字」，这样 UI 用到的汉字也会有字形 + PUA 别名。
    extra_text = ""
    if "--extra" in args:
        i = args.index("--extra")
        p = args[i + 1]
        del args[i:i + 2]
        try:
            with open(p, encoding="utf-8") as fh:
                extra_text = fh.read()
        except Exception as e:
            print("✗ --extra 读不了 %s: %s" % (p, e))
            return 2

    # --map-json PATH：把 PUA 映射另存成 JSON，给 mido_ui.py 用
    #   （面板走 sed，设置页是 Python，两边必须是同一份映射，否则会出现
    #    「看板正常、设置页字体错位」这种两套字的事故）。
    map_json = ""
    if "--map-json" in args:
        i = args.index("--map-json")
        map_json = args[i + 1]
        del args[i:i + 2]

    # 字体可以在命令行覆盖（优先级最高），方便在别的机器上指定自己的开源字体。
    # 注意顺序：先解析参数、再解析字体 —— 否则「本机一款开源字体都没有」时，
    # 提示用户加 --font-mono 也没用（那时代码已经在 import 阶段退出了）。
    global H_STRETCH
    mono = cjk = ""
    for flag in ("--font-mono", "--font-cjk"):
        if flag in args:
            i = args.index(flag)
            path = args[i + 1]
            del args[i:i + 2]
            if not os.path.isfile(path):
                print("✗ %s 指定的字体不存在: %s" % (flag, path))
                return 2
            if flag == "--font-mono":
                mono = path
            else:
                cjk = path

    m_font, c_font = resolve_fonts(mono, cjk)
    print("等宽字体: %s" % m_font)
    print("中文字体: %s" % c_font)

    src, outdir = args[0], args[1]

    if len(args) > 2 and args[2] == "natural":
        H_STRETCH = False

    with open(src, "r", encoding="utf-8") as fh:
        raw = fh.read()
    text = code_only(raw)
    if extra_text:
        # 额外来源不做注释剔除（它是生成好的纯字表，不是源码）
        text = text + "\n" + extra_text
    alias = collect_alias(text)
    chars = collect_chars(text, reserve=len(alias))
    print("需要生成的字形数: %d（其中 %d 个汉字额外带 PUA 别名）H_STRETCH=%s"
          % (len(chars), len(alias), H_STRETCH))
    os.makedirs(outdir, exist_ok=True)
    suffix = "" if H_STRETCH else "ns"
    amap = None
    for W, H in CANDIDATES:
        amap, slots = build(chars, alias, W, H,
                            os.path.join(outdir, "mido-%dx%d%s.psf" % (W, H, suffix)))
    write_alias_map(amap, os.path.join(outdir, "pua.sed"))
    print("已写出 %s（%d 条映射）" % (os.path.join(outdir, "pua.sed"), len(amap)))
    if map_json:
        # 给 mido_ui.py 用的同一份映射（Python 侧直接把汉字换成 PUA 码点）。
        # 用 ensure_ascii=False + UTF-8：装到设备后 os 直接读，不做转义。
        with open(map_json, "w", encoding="utf-8", newline="\n") as fh:
            json.dump({ch: chr(cp) for ch, cp in sorted(amap.items(), key=lambda kv: kv[1])},
                      fh, ensure_ascii=False)
        print("已写出 %s（%d 条映射，供设置页使用）" % (map_json, len(amap)))

    # ⚠ 硬自查：缺字时内核会静默回退成别的字形（─ 变 -、● 变 *），
    #   不查的话很难发现。有缺失就直接失败，别把坏字体部署上去。
    miss = verify_slots(slots, amap, text)
    if miss:
        print("✗ 字体缺字 %d 个（会渲染成方块或被内核替换）: %s"
              % (len(miss), "".join(miss)))
        return 2
    print("✓ 面板用到的非 ASCII 字符全部在字体里")

    if runtime:
        miss2 = gen_runtime(runtime[0], runtime[1], amap)
        print("已写出预编译脚本 %s" % runtime[1])
        if miss2:
            print("⚠ 源码里有 %d 个汉字没进字体（会变方块）: %s"
                  % (len(miss2), "".join(miss2)))
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
