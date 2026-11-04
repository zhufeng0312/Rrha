"""图标预览：模拟启动器各种形状的裁剪结果。

**核心概念（容易搞错的地方）**：自适应图标的前景/背景都是 108dp 画布，
但启动器只显示中间 72dp —— 即会先放大约 1.5 倍再裁。所以看前景图时
必须按「放大 108/72 后取中央」来还原，否则会误以为主体太小。

产物在 `tools/shots/icon-preview/`：
- launcher-square / circle / squircle / teardrop  各形状实际观感
- adaptive-safe-area  前景 + 安全区红框 + 越界检测
- legacy-square       传统方形图标（Android 7 及以下 / 部分启动器回退）
"""
from pathlib import Path

from PIL import Image, ImageDraw

RES = Path(r"D:\Rrha\android\app\src\main\res")
OUT = Path(r"D:\Rrha\tools\shots\icon-preview")
OUT.mkdir(parents=True, exist_ok=True)

SIZE = 512
ADAPTIVE_DP = 108
SAFE_DP = 72
BG = (255, 255, 255, 255)   # 与 values/colors.xml 的 ic_launcher_background 一致


def load(path: Path, size: int) -> Image.Image:
    return Image.open(path).convert("RGBA").resize((size, size), Image.LANCZOS)


def mask_shape(size: int, kind: str) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    if kind == "circle":
        d.ellipse((0, 0, size - 1, size - 1), fill=255)
    elif kind == "squircle":
        d.rounded_rectangle((0, 0, size - 1, size - 1),
                            radius=int(size * 0.28), fill=255)
    elif kind == "teardrop":
        d.ellipse((0, 0, size - 1, size - 1), fill=255)
        d.rectangle((size - 1 - size // 7, size - 1 - size // 7, size, size), fill=0)
    else:
        d.rectangle((0, 0, size - 1, size - 1), fill=255)
    return m


def launcher_view() -> Image.Image:
    """还原启动器实际看到的画面。

    ⚠️ 真机实测（荣耀 MagicOS 10）：该启动器**不**按「只显示中间 72dp、
    放大 1.5 倍」处理，而是把 108dp 前景原样铺开再套圆角矩形。
    所以这里也不再缩放，直接按 1:1 还原 —— 早先的 1.5 倍放大让预览
    比真机偏大，掩盖了「图标显得比邻座小」的问题。
    """
    fg = load(RES / "mipmap-xxxhdpi" / "ic_launcher_foreground.png", SIZE)
    base = Image.new("RGBA", (SIZE, SIZE), BG)
    base.alpha_composite(fg)
    return base


def main() -> None:
    # 传统方形图标
    load(RES / "mipmap-xxxhdpi" / "ic_launcher.png", SIZE).save(
        OUT / "legacy-square.png"
    )

    view = launcher_view()
    for kind in ("square", "circle", "squircle", "teardrop"):
        c = view.copy()
        c.putalpha(mask_shape(SIZE, kind))
        c.save(OUT / f"launcher-{kind}.png")
        print("shape", kind)

    # 安全区检查：直接用前景原图坐标（108dp 画布），标出 18..90 的红框
    fg = load(RES / "mipmap-xxxhdpi" / "ic_launcher_foreground.png", SIZE)
    canvas = Image.new("RGBA", (SIZE, SIZE), BG)
    canvas.alpha_composite(fg)
    d = ImageDraw.Draw(canvas)
    m18 = round(SIZE * 18 / ADAPTIVE_DP)
    d.rectangle((m18, m18, SIZE - m18 - 1, SIZE - m18 - 1),
                outline=(255, 0, 0, 255), width=3)
    d.text((m18 + 10, m18 + 8), "SAFE 72/108", fill=(255, 0, 0, 255))
    canvas.save(OUT / "adaptive-safe-area.png")
    print(f"safe-area done, red frame inset {m18}px of {SIZE}")


if __name__ == "__main__":
    main()
