"""生成 DSH Remote（dsh-frp-pocket）的 Android 启动图标。

设计方向见 tool/icon/DIRECTION.md：石墨底 #111110 + 单一薄荷 accent #7FD3C0，
一个视觉元素（终端提示符），无渐变、无发光、无阴影。

用法（PowerShell，python 见 load_workspace_dependencies）：
    python packages/app/tool/icon/generate_icon.py preview
    python packages/app/tool/icon/generate_icon.py install [候选名]

预览写到 tool/icon/preview/。install 默认装 A-prompt-cursor。
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw

# ---------------------------------------------------------------- 基本参数

BG = (0x11, 0x11, 0x10, 255)  # 石墨（= ColorScheme.surface）
FG = (0x7F, 0xD3, 0xC0, 255)  # 薄荷（= ColorScheme.primary，深色主题）

BASE = 1024  # 设计坐标系边长
SS = 4  # 超采样倍率
CANVAS = BASE * SS

HERE = Path(__file__).resolve().parent
APP = HERE.parent.parent
RES = APP / "android" / "app" / "src" / "main" / "res"
PREVIEW = HERE / "preview"

DEFAULT = "A3-prompt-heavy"

# 自适应图标是一块 108dp 画布，但系统只会露出**中间 72dp**（外圈留给视差与
# 各家遮罩）。也就是说画布上画得再满，用户也只看得到 2/3 —— 图标显不显大，
# 取决于 ink 占那 72dp 的多少，不是占 108dp 的多少。
ADAPTIVE_CANVAS_DP = 108
ADAPTIVE_SAFE_DP = 72
# 图形宽度占可见区的比例。0.62 是照着一排真图标量出来的体量：四周都留气口，
# 和 48px 的相邻图标站在一起不挤。
ADAPTIVE_INK_FILL = 0.62


def px(v: float) -> int:
    """设计坐标 -> 画布坐标。"""
    return int(round(v * SS))


def box(x0: float, y0: float, x1: float, y1: float):
    return [px(x0), px(y0), px(x1), px(y1)]


class Mark:
    """在一块灰度遮罩上画图形，坐标一律用 0..1024 的设计坐标。"""

    def __init__(self) -> None:
        self.m = Image.new("L", (CANVAS, CANVAS), 0)
        self.d = ImageDraw.Draw(self.m)

    def rect(self, x0, y0, x1, y1, r, fill=255):
        self.d.rounded_rectangle(box(x0, y0, x1, y1), radius=px(r), fill=fill)

    def ring(self, x0, y0, x1, y1, stroke, r=None):
        outer = Image.new("L", (CANVAS, CANVAS), 0)
        ImageDraw.Draw(outer).rounded_rectangle(
            box(x0, y0, x1, y1), radius=px(r if r is not None else min(x1 - x0, y1 - y0) / 2), fill=255
        )
        inner = Image.new("L", (CANVAS, CANVAS), 0)
        ImageDraw.Draw(inner).rounded_rectangle(
            box(x0 + stroke, y0 + stroke, x1 - stroke, y1 - stroke),
            radius=px(max(4, (r if r is not None else min(x1 - x0, y1 - y0) / 2) - stroke)),
            fill=255,
        )
        self.m = Image.fromarray(
            __import__("numpy").clip(
                __import__("numpy").asarray(outer, dtype=int)
                - __import__("numpy").asarray(inner, dtype=int),
                0,
                255,
            ).astype("uint8")
        )
        self.d = ImageDraw.Draw(self.m)

    def line(self, pts, width, cap=True):
        w = px(width)
        for a, b in zip(pts, pts[1:]):
            self.d.line([px(a[0]), px(a[1]), px(b[0]), px(b[1])], fill=255, width=w)
        if cap:
            r = width / 2
            for x, y in pts:
                self.ellipse(x, y, r)

    def ellipse(self, cx, cy, r, fill=255):
        self.d.ellipse(box(cx - r, cy - r, cx + r, cy + r), fill=fill)

    def chevron(self, x, cy, w, h, stroke):
        """`›`：左开口的折角线，宽 w 高 h，圆头。"""
        self.line([(x, cy - h / 2), (x + w, cy), (x, cy + h / 2)], stroke)


def paint(m: Image.Image) -> Image.Image:
    layer = Image.new("RGBA", m.size, FG)
    layer.putalpha(m)
    return layer


def composite(m: Image.Image, radius_frac: float = 0.225) -> Image.Image:
    """叠到圆角石墨底上：方形、仅四角透明（传统 mipmap 用）。"""
    plate = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(plate).rounded_rectangle(
        [0, 0, CANVAS - 1, CANVAS - 1], radius=px(BASE * radius_frac), fill=255
    )
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    out.paste(Image.new("RGBA", (CANVAS, CANVAS), BG), (0, 0), plate)
    out.alpha_composite(paint(m))
    return out


def down(img: Image.Image, size: int) -> Image.Image:
    return img.resize((size, size), Image.LANCZOS)


# ---------------------------------------------------------------- 候选


def cand_prompt_cursor() -> Image.Image:
    """A：`›` + 方块光标（首版，留作对比）。"""
    k = Mark()
    k.chevron(232, 512, 300, 316, 100)
    k.rect(600, 512 - 110, 820, 512 + 110, 26)
    return k.m


def cand_prompt_tight() -> Image.Image:
    """A2：收紧间距、光学居中、光标略小于折角高度。"""
    k = Mark()
    k.chevron(248, 512, 272, 300, 104)
    k.rect(584, 512 - 96, 776, 512 + 96, 24)
    return k.m


def cand_prompt_heavy() -> Image.Image:
    """A3：厚笔画；折角 2:1 高于光标，光标缩到 176 并留出半笔画呼吸位。"""
    k = Mark()
    k.chevron(268, 512, 264, 300, 114)
    k.rect(637, 424, 813, 600, 22)
    return k.m


def cand_prompt_bar() -> Image.Image:
    """B：`›` + 下划宽条光标（经典 shell）。"""
    k = Mark()
    k.chevron(232, 476, 292, 312, 100)
    k.rect(556, 690, 820, 786, 48)
    return k.m


def cand_window() -> Image.Image:
    """C：终端窗口轮廓 + 内部 `›_`。"""
    k = Mark()
    k.ring(148, 208, 876, 816, 60, r=184)
    k.chevron(272, 512, 214, 232, 68)
    k.rect(536, 512 - 62, 700, 512 + 62, 18)
    return k.m


def cand_tunnel() -> Image.Image:
    """D：两端节点 + 连线（frp 隧道）。"""
    k = Mark()
    k.line([(276, 700), (748, 328)], 84)
    k.ellipse(268, 708, 132)
    k.d.ellipse(box(560, 140, 924, 504), fill=255)
    k.d.ellipse(box(632, 212, 852, 432), fill=0)
    return k.m


def cand_bubble() -> Image.Image:
    """E：气泡（圆角方 + 左下尾巴）+ `›` 与光标，把「对话」和「终端」并在一起。"""
    k = Mark()
    k.ring(140, 168, 884, 736, 62, r=196)
    # 尾巴：一条粗圆头短线从气泡底边斜出去
    k.line([(292, 720), (268, 866)], 62)
    k.chevron(262, 452, 216, 232, 64)
    k.rect(528, 452 - 58, 690, 452 + 58, 18)
    return k.m


CANDS = {
    "A-prompt-cursor": cand_prompt_cursor,
    "A2-prompt-tight": cand_prompt_tight,
    "A3-prompt-heavy": cand_prompt_heavy,
    "B-prompt-bar": cand_prompt_bar,
    "C-window": cand_window,
    "D-tunnel": cand_tunnel,
    "E-bubble": cand_bubble,
}


# ---------------------------------------------------------------- 输出


def preview() -> None:
    PREVIEW.mkdir(parents=True, exist_ok=True)
    n = len(CANDS)
    cell, pad = 1024, 96
    sheet = Image.new("RGBA", (n * (cell + pad) + pad, 1024 + pad + 300), (0xF5, 0xF5, 0xF3, 255))
    for i, (name, fn) in enumerate(CANDS.items()):
        icon = down(composite(fn()), 1024)
        icon.save(PREVIEW / f"{name}.png")
        x = pad + i * (cell + pad)
        sheet.alpha_composite(icon, (x, pad))
        for j, size in enumerate((48, 36, 32)):
            small = down(composite(fn()), size)
            sheet.alpha_composite(small, (x + 8 + j * 116, 1024 + pad + 24))
            light = Image.new("RGBA", (size, size), (0xFA, 0xFA, 0xF9, 255))
            light.alpha_composite(small)
            sheet.alpha_composite(light, (x + 28 + j * 116, 1024 + pad + 120))
    sheet.save(PREVIEW / "sheet.png")
    print(f"preview -> {PREVIEW / 'sheet.png'}")


def ink_fraction(m: Image.Image) -> float:
    """图形 ink 宽度占整块画布的比例（用遮罩的包围盒量，不靠手写常量）。"""
    left, _, right, _ = m.getbbox()
    return (right - left) / m.size[0]


def foreground(m: Image.Image) -> Image.Image:
    """108dp 前景层：把图形缩到「可见区宽度的 ADAPTIVE_INK_FILL」。"""
    scale = ADAPTIVE_INK_FILL * ADAPTIVE_SAFE_DP / (
        ADAPTIVE_CANVAS_DP * ink_fraction(m)
    )
    canvas = 1024
    inner = int(round(canvas * scale))
    fg = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    fg.alpha_composite(down(paint(m), inner), ((canvas - inner) // 2,) * 2)
    return fg


def adaptive_icon(m: Image.Image, size: int = 1024) -> Image.Image:
    """系统眼里的样子：前景取中间 72/108，压到石墨底上，再套圆角遮罩。

    预览必须走这条路，否则本地看到的（整块 108dp）永远比手机上（裁到 72dp）
    小一圈 —— 这是第一版预览骗过眼睛的原因。
    """
    fg = foreground(m)
    canvas = fg.size[0]
    visible = int(round(canvas * ADAPTIVE_SAFE_DP / ADAPTIVE_CANVAS_DP))
    off = (canvas - visible) // 2
    fg = fg.crop((off, off, off + visible, off + visible))

    plate = Image.new("RGBA", (visible, visible), BG)
    plate.alpha_composite(fg)
    mask = Image.new("L", (visible, visible), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, visible - 1, visible - 1], radius=int(visible * 0.225), fill=255
    )
    plate.putalpha(mask)
    return plate.resize((size, size), Image.LANCZOS)


def install(name: str = DEFAULT) -> None:
    if name not in CANDS:
        raise SystemExit(f"unknown candidate {name}; pick from {', '.join(CANDS)}")
    m = CANDS[name]()

    big = composite(m)
    for folder, size in (
        ("mipmap-mdpi", 48),
        ("mipmap-hdpi", 72),
        ("mipmap-xhdpi", 96),
        ("mipmap-xxhdpi", 144),
        ("mipmap-xxxhdpi", 192),
    ):
        target = RES / folder / "ic_launcher.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        down(big, size).save(target)
        print(f"wrote {target} ({size}px)")

    # 自适应图标：108dp 画布，图形缩到「可见区（72dp）的 62%」。这个比例是
    # foreground() 按 ink 实测算的，不再手写 0.94 那种拍脑袋系数。
    fg = foreground(m)
    for folder, size in (
        ("mipmap-mdpi", 108),
        ("mipmap-hdpi", 162),
        ("mipmap-xhdpi", 216),
        ("mipmap-xxhdpi", 324),
        ("mipmap-xxxhdpi", 432),
    ):
        target = RES / folder / "ic_launcher_foreground.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        fg.resize((size, size), Image.LANCZOS).save(target)
        print(f"wrote {target} ({size}px)")

    (RES / "values").mkdir(parents=True, exist_ok=True)
    (RES / "values" / "ic_launcher_colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '    <color name="ic_launcher_background">#111110</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )
    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n",
        encoding="utf-8",
    )
    print(f"wrote {anydpi / 'ic_launcher.xml'}")
    print("check AndroidManifest android:icon == @mipmap/ic_launcher")


def splash(name: str = DEFAULT) -> None:
    """启动屏：同款 mark 居中，浅色/深色各一个底色与笔画色。"""
    if name not in CANDS:
        raise SystemExit(f"unknown candidate {name}")
    m = CANDS[name]()
    # 深色主题=薄荷，浅色主题=深青（保证与底色的对比度）
    tint = {"": (0x1F, 0x6F, 0x63, 255), "-night": FG}
    sizes = {"mdpi": 96, "hdpi": 144, "xhdpi": 192, "xxhdpi": 288, "xxxhdpi": 384}
    for suffix, color in tint.items():
        mark = Image.new("RGBA", m.size, color)
        mark.putalpha(m)
        for bucket, size in sizes.items():
            folder = RES / f"drawable{suffix}-{bucket}" if suffix else RES / f"drawable-{bucket}"
            folder.mkdir(parents=True, exist_ok=True)
            mark.resize((size, size), Image.LANCZOS).save(folder / "launch_mark.png")

    for suffix in ("", "-night"):
        for base in (RES / f"drawable{suffix}", RES / f"drawable{suffix}-v21"):
            base.mkdir(parents=True, exist_ok=True)
            (base / "launch_background.xml").write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <item android:drawable="@color/launch_background" />\n'
                "    <item>\n"
                "        <bitmap\n"
                '            android:gravity="center"\n'
                '            android:src="@drawable/launch_mark" />\n'
                "    </item>\n"
                "</layer-list>\n",
                encoding="utf-8",
            )

    (RES / "values" / "colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '    <color name="launch_background">#FAFAF9</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )
    (RES / "values-night" / "colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '    <color name="launch_background">#111110</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )
    print(f"wrote splash layers under {RES}")


def mock(name: str = DEFAULT) -> None:
    """设备视角：桌面图标 + 启动屏各一张，用来判断「放在手机上好不好看」。"""
    from PIL import ImageFont

    if name not in CANDS:
        raise SystemExit(f"unknown candidate {name}")
    PREVIEW.mkdir(parents=True, exist_ok=True)
    # 桌面那枚必须按系统的裁切来画（中间 72/108），否则预览会系统性偏小
    icon = adaptive_icon(CANDS[name](), 1024)

    def font(size):
        for p in (
            r"C:\Windows\Fonts\msyh.ttc",
            r"C:\Windows\Fonts\msyhl.ttc",
        ):
            if Path(p).exists():
                return ImageFont.truetype(p, size)
        return ImageFont.load_default()

    # 桌面：深色壁纸上的一枚图标 + 名字，旁边放两个中性占位，模拟真实栅格
    home = Image.new("RGB", (1200, 700), (0x1B, 0x1B, 0x19))
    shade = Image.new("RGB", home.size, (0x24, 0x26, 0x22))
    home = Image.blend(home, shade, 0.6)
    d = ImageDraw.Draw(home)
    f = font(34)
    for i, (x, label, is_ours) in enumerate(
        ((190, "DSH 口袋隧道", True), (470, "其他应用", False), (750, "另一个", False))
    ):
        if is_ours:
            home.paste(icon.resize((200, 200), Image.LANCZOS), (x, 210), icon.resize((200, 200), Image.LANCZOS))
        else:
            plate = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
            ImageDraw.Draw(plate).rounded_rectangle([0, 0, 199, 199], radius=45, fill=(0x33, 0x33, 0x30, 255))
            home.paste(plate, (x, 210), plate)
        w = d.textlength(label, font=f)
        d.text((x + 100 - w / 2, 450), label, font=f, fill=(0xEC, 0xEC, 0xE8))
    home.save(PREVIEW / "mock-home.png")

    # 启动屏：1080x2340 手机比例，居中 mark
    splash = Image.new("RGB", (1080, 1600), (0x11, 0x11, 0x10))
    mark = paint(CANDS[name]())
    sized = down(mark, 420)
    splash.paste(sized, (330, 560), sized)
    splash.save(PREVIEW / "mock-splash.png")
    print(f"mock -> {PREVIEW}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "preview"
    if mode == "preview":
        preview()
    elif mode == "install":
        install(sys.argv[2] if len(sys.argv) > 2 else DEFAULT)
    elif mode == "splash":
        splash(sys.argv[2] if len(sys.argv) > 2 else DEFAULT)
    elif mode == "mock":
        mock(sys.argv[2] if len(sys.argv) > 2 else DEFAULT)
    else:
        raise SystemExit(f"unknown mode: {mode}")
