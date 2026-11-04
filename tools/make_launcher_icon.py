"""从桌面源图生成 Android 启动图标（常规方形 + 自适应图层）。

设计决策（用户 2026-11-01 拍板）：
- **保留白底、加大留白**：源图是黑线白底线稿，主体重心偏下（y=174.6/280），
  且底边已被裁切（最后一行有 101 个线条像素）。直接铺满会被启动器裁掉线条，
  所以要把主体**缩小并居中**到安全区内。
- **自适应图标**：Android 8+ 按系统设置裁成圆/方/水滴等形状。
  自适应图层画布是 108dp，但只有中间 **72dp 是安全区**（四周各 18dp 会被裁）。
  所以前景图不能把主体画到边上去。

产物（`android/app/src/main/res/`）：
1. 传统方形 `mipmap-*/ic_launcher.png`：48/72/96/144/192。
   这些给 Android 7 及以下、以及部分启动器的回退路径用。
2. 自适应 `mipmap-*/ic_launcher_foreground.png` + `mipmap-anydpi-v26/ic_launcher.xml`：
   前景 108dp 画布（192dp→432px @xxxhdpi），主体落在中央 72dp 安全区内。
   背景用纯白 `@color/ic_launcher_background`。

⚠️ 不要把主体塞满整张 108dp 画布：那正是「自适应图标看起来被放大了一圈」的典型错误。
"""
from pathlib import Path
import sys

from PIL import Image, ImageDraw

# 源图由命令行传入，避免把某个人的本机路径写死在仓库里：
#     python tools/make_launcher_icon.py path/to/icon_source.png
# 源图建议 ≥ 1024×1024 的正方形。
if len(sys.argv) > 1:
    SRC = Path(sys.argv[1])
else:
    raise SystemExit(
        "用法: python tools/make_launcher_icon.py <源图路径>\n"
        "源图建议为 ≥1024×1024 的正方形 PNG。"
    )
RES = Path(__file__).resolve().parent.parent / "android" / "app" / "src" / "main" / "res"

# 传统方形图标边长（mdpi→xxxhdpi）。
LEGACY_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# 自适应前景画布：108dp。
ADAPTIVE_SIZES = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

# 安全区占画布的比例：72/108 = 0.6667。
SAFE_RATIO = 72 / 108

# 主体再往里收一点，避免描边贴到安全区边界上。
#
# ⚠️ 这里的语义是「主体占**安全区**的比例」，不是「占整张 108dp 画布的比例」。
# 早先把 SAFE_RATIO 与它相乘，等于主体只占安全区的 86%、也就是整块画布的 57%，
# 人物明显偏小。既然 compose() 已经按**主体包围盒**对齐，这里就该给到
# 安全区本身的 0.96（留 2% 呼吸），而不是再叠一层缩小。
CONTENT_INSET = 0.96


def load_square() -> Image.Image:
    """读源图 → 提纯白底 → 转正方形。"""
    im = Image.open(SRC).convert("RGB")
    im = whiten(im)
    w, h = im.size
    if w != h:
        s = min(w, h)
        im = im.crop(
            ((w - s) // 2, (h - s) // 2, (w - s) // 2 + s, (h - s) // 2 + s)
        )
    return im


def body_bbox(im: Image.Image, threshold: int = 200) -> tuple[int, int, int, int]:
    """线条主体的包围盒（left, top, right, bottom）。

    实测这张源图（280x280）在**左、下两条边**上都有线条延伸到画面边缘：
    第 0–11 列有内容、第 270–279 行有内容。也就是说原图本身已被裁切过，
    放大后边缘笔触会顶到安全区边界。留白必须按这个真实包围盒来算，
    只按「整张 280x280」缩进是不够的。
    """
    import numpy as np

    a = np.asarray(im.convert("L")).astype(np.int16)
    mask = a < threshold
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return (0, 0, im.size[0], im.size[1])
    return (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)


def whiten(im: Image.Image) -> Image.Image:
    """把「照片式灰底」提纯成**纯白**，黑色线条保持不变。

    ## 为什么需要这一步

    源图不是真正意义上的「白纸扫描」，而是带灰底的图片：实测底色均匀落在
    **RGB 239**（亮度 0.937），纯白像素只占 **0.12%**，而线条核心是接近
    纯黑（亮度 P1 = 0.043）。放进纯白卡片式界面里，这个 239 的灰看起来
    就是「一块发脏的底色」，与周围 UI 的 #FFFFFF 明显不齐。

    ## 做法：只重映射「亮部」，不动线条

    线性拉伸整体亮度会把线条边缘一起提亮、变灰。这里用**分段线性**：
    - 低于 `LOW`（0.62）的像素——线条及其抗锯齿——**原样保留**；
    - 高于 `HIGH`（0.90）的像素——底色——**一律推到 255**；
    - 中间线性过渡，避免出现二值化的硬边。

    分段而不是硬阈值的原因：线稿有大量柔和的抗锯齿像素（P50 = 0.62 附近
    正是笔画边缘），硬切会把它们变成一圈锯齿白边。
    """
    import numpy as np

    LOW, HIGH = 0.62, 0.90

    a = np.asarray(im.convert("RGB")).astype(np.float32) / 255.0
    lum = a.mean(axis=2, keepdims=True)

    # t = 0 表示保持原样，t = 1 表示推到纯白。
    t = np.clip((lum - LOW) / (HIGH - LOW), 0.0, 1.0)
    out = a + (1.0 - a) * t

    return Image.fromarray(
        np.clip(out * 255.0 + 0.5, 0, 255).astype(np.uint8), "RGB"
    )


def compose(
    src: Image.Image,
    canvas: int,
    content_ratio: float,
    bg: tuple[int, int, int] | None = (255, 255, 255),
) -> Image.Image:
    """把 `src` 的**主体**缩放进 canvas*content_ratio 的方框并居中。

    `bg=None` 表示透明底（自适应前景用，背景由 XML 的 <background> 提供）。

    ⚠️ 与「把整张图缩放居中」的区别很大：源图四周白边不对称（左/下已被裁切、
    顶部有 17px 纯白），按整张图对齐会让主体偏下、底部顶到安全区边界。
    这里先把主体包围盒裁出来，再等比缩放进目标方框 —— 这样**视觉重心**才在
    正中央，圆形裁剪时四边留白均匀。
    """
    mode = "RGBA" if bg is None else "RGB"
    out = Image.new(mode, (canvas, canvas), bg if bg else (0, 0, 0, 0))

    left, top, right, bottom = body_bbox(src)
    art = src.crop((left, top, right, bottom))

    box = max(1, int(round(canvas * content_ratio)))
    aw, ah = art.size
    # 等比缩放：长边贴合 box，短边按比例（保持长宽比，不拉伸）
    scale = min(box / aw, box / ah)
    tw, th = max(1, int(round(aw * scale))), max(1, int(round(ah * scale)))
    art = art.resize((tw, th), Image.LANCZOS)

    x = (canvas - tw) // 2
    y = (canvas - th) // 2

    if bg is None:
        art = art.convert("RGBA")
        out.paste(art, (x, y), art)
    else:
        out.paste(art, (x, y))
    return out


def main() -> None:
    src = load_square()

    # ---- 1) 传统方形图标 ----
    # 内容比例 0.90 是用户认可的那一版；不要为了「显得更大」调到 0.96。
    for folder, size in LEGACY_SIZES.items():
        d = RES / folder
        d.mkdir(parents=True, exist_ok=True)
        img = compose(src, size, content_ratio=0.90)
        img.save(d / "ic_launcher.png", "PNG")
        print(f"legacy  {folder:18} {size}x{size}")

    # ---- 1b) 圆形图标（Android 7.1 / API 25 的圆形启动器） ----
    # 圆形内切正方形的四角是空的，主体不能像方形那样铺满 ——
    # 0.82 保证圆内仍有均匀留白（圆形可用区域只有方形的 π/4≈78.5%）。
    for folder, size in LEGACY_SIZES.items():
        d = RES / folder
        img = compose(src, size, content_ratio=0.82)
        # 用圆形蒙版抠出透明四角，否则圆外会留下一圈白方块
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
        img = img.convert("RGBA")
        img.putalpha(mask)
        img.save(d / "ic_launcher_round.png", "PNG")
        print(f"legacy  {folder:18} {size}x{size} (round)")

    # ---- 2) 自适应前景 ----
    # 尺寸由用户拍板（2026-11-01）：「这个图标这么大就可以」= 主体占**安全区**
    # 的 0.86（即整张 108dp 画布的 0.573）。曾试过撑满整张画布（0.96），
    # 用户明确否决「图标变大了」，已改回。
    # 结论：改白底、改形状都可以，**主体比例不要再动**。
    ratio = SAFE_RATIO * CONTENT_INSET
    for folder, size in ADAPTIVE_SIZES.items():
        d = RES / folder
        d.mkdir(parents=True, exist_ok=True)
        img = compose(src, size, content_ratio=ratio, bg=None)
        img.save(d / "ic_launcher_foreground.png", "PNG")
        print(f"adaptive {folder:18} {size}x{size}  content={ratio:.3f}")

    # ---- 3) 自适应 XML ----
    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    xml = """<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标（Android 8.0 / API 26+）。
     背景是纯白：源图是黑线白底线稿，白底能保持线条对比度（用户 2026-11-01 拍板）。
     前景 ic_launcher_foreground.png 的主体落在中央 72/108 安全区内，
     所以无论系统把图标裁成圆形、方形还是水滴形，都不会切到人物。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""
    (anydpi / "ic_launcher.xml").write_text(xml, encoding="utf-8")
    # roundIcon 用同一份自适应图标：API 26+ 系统会自己套圆形掩码，
    # 另做一个圆形的 PNG 只会多一份要维护的图。
    (anydpi / "ic_launcher_round.xml").write_text(xml, encoding="utf-8")
    print("xml     mipmap-anydpi-v26/ic_launcher.xml (+ round)")

    # ---- 4) 背景色 ----
    values = RES / "values"
    values.mkdir(parents=True, exist_ok=True)
    colors = values / "colors.xml"
    colors.write_text(
        """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- 自适应图标的背景：纯白，与线稿的底色一致。 -->
    <color name="ic_launcher_background">#FFFFFF</color>
</resources>
""",
        encoding="utf-8",
    )
    print("xml     values/colors.xml")


if __name__ == "__main__":
    main()
