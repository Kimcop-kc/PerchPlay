"""PerchPlay 图标生成
设计：深色底 + 一根「栖木」横线 + 停在横线上的播放三角
强调色：青绿(teal) / 琥珀(amber) / 蓝紫(blue-purple)
形状粗壮，小尺寸不糊。
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

REPO = r"C:\Users\86177\Documents\deepseek-harness\default-workspace\video_player_app"
ANDROID_RES = os.path.join(REPO, "android", "app", "src", "main", "res")
IOS_APPICON = os.path.join(
    REPO, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset"
)

BG_TOP = (16, 19, 26)
BG_BOTTOM = (28, 34, 50)
BAR_LEFT = (34, 227, 200)     # 青绿
BAR_RIGHT = (123, 108, 246)   # 蓝紫
TRI_TOP = (255, 203, 92)      # 亮琥珀
TRI_BOTTOM = (255, 157, 46)   # 琥珀

SS = 2048  # 超采样画布


def vgrad(size, top, bottom):
    w, h = size
    grad = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        grad.putpixel((0, y), tuple(
            int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return grad.resize((w, h))


def hgrad(size, left, right):
    w, h = size
    grad = Image.new("RGB", (w, 1))
    for x in range(w):
        t = x / max(1, w - 1)
        grad.putpixel((x, 0), tuple(
            int(left[i] + (right[i] - left[i]) * t) for i in range(3)))
    return grad.resize((w, h))


def rounded_polygon_mask(size, pts, radius):
    """带圆角的多边形遮罩（多边形 + 顶点圆，小图标也不糊）"""
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    d.polygon(pts, fill=255)
    for (x, y) in pts:
        d.ellipse([x - radius, y - radius, x + radius, y + radius], fill=255)
    return m


def rounded_rect_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def build_artwork(size):
    """返回 RGBA 的艺术层（横线 + 播放三角 + 高光），画在透明画布上"""
    W = H = size
    art = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    # ── 栖木横线 ──
    bar_top = 0.600 * H
    bar_h = 0.152 * H
    bar_box = [0.150 * W, bar_top, 0.850 * W, bar_top + bar_h]
    bar_mask = rounded_rect_mask((W, H), bar_box, radius=bar_h / 2)
    bar_fill = hgrad((W, H), BAR_LEFT, BAR_RIGHT).convert("RGBA")
    art.paste(bar_fill, (0, 0), bar_mask)

    # 横线顶部高光（玻璃质感）
    hl = Image.new("L", (W, H), 0)
    ImageDraw.Draw(hl).rounded_rectangle(
        [bar_box[0] + bar_h * 0.18, bar_top + bar_h * 0.14,
         bar_box[2] - bar_h * 0.18, bar_top + bar_h * 0.42],
        radius=bar_h * 0.16, fill=110)
    art.paste(Image.new("RGBA", (W, H), (255, 255, 255, 255)), (0, 0), hl)

    # ── 播放三角（坐在横线上）──
    tri_base_y = bar_top + bar_h * 0.10     # 略微压进横线，看起来是「停」在上面
    tri_h = 0.325 * H
    half_base = 0.200 * W
    cx = 0.5 * W
    pts = [
        (cx, tri_base_y - tri_h),            # 顶点
        (cx + half_base, tri_base_y),        # 右下
        (cx - half_base, tri_base_y),        # 左下
    ]
    tri_mask = rounded_polygon_mask((W, H), pts, radius=0.052 * W)

    # 三角投影，增强「停住」的立体感
    shadow = tri_mask.filter(ImageFilter.GaussianBlur(0.018 * W))
    shadow = shadow.point(lambda v: int(v * 0.42))
    art.paste(Image.new("RGBA", (W, H), (0, 0, 0, 255)), (0, int(0.012 * H)),
              shadow)

    tri_fill = vgrad((W, H), TRI_TOP, TRI_BOTTOM).convert("RGBA")
    art.paste(tri_fill, (0, 0), tri_mask)
    return art


def render(size, with_background=True, content_scale=1.0):
    """渲染目标尺寸图标"""
    art = build_artwork(SS)
    if content_scale != 1.0:
        s = max(1, int(SS * content_scale))
        art = art.resize((s, s), Image.LANCZOS)
        canvas = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
        off = (SS - s) // 2
        canvas.paste(art, (off, off), art)
        art = canvas

    if with_background:
        bg = vgrad((SS, SS), BG_TOP, BG_BOTTOM).convert("RGBA")

        # 横线后方柔和光晕
        glow = Image.new("L", (SS, SS), 0)
        gd = ImageDraw.Draw(glow)
        cx, cy = SS * 0.5, SS * 0.60
        rx, ry = SS * 0.42, SS * 0.26
        gd.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=64)
        glow = glow.filter(ImageFilter.GaussianBlur(SS * 0.11))
        bg.paste(Image.new("RGBA", (SS, SS), (58, 96, 168, 255)), (0, 0), glow)

        out = Image.alpha_composite(bg, art)
    else:
        out = art

    return out.convert("RGBA").resize((size, size), Image.LANCZOS)


def save(img, path, keep_alpha=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if keep_alpha:
        img.save(path, "PNG")
    else:
        # Android/iOS 启动图标不要透明
        if img.mode == "RGBA":
            bg = Image.new("RGB", img.size, BG_TOP)
            bg.paste(img, mask=img.split()[3])
            img = bg
        img.convert("RGB").save(path, "PNG")
    return path


# ───────────── Android 传统图标 ─────────────
LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
for d, px in LEGACY.items():
    save(render(px, True),
         os.path.join(ANDROID_RES, f"mipmap-{d}", "ic_launcher.png"))

# ───────────── Android 自适应图标前景（108dp，内容缩到安全区）─────────────
FG = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
for d, px in FG.items():
    save(render(px, False, content_scale=0.60),
         os.path.join(ANDROID_RES, f"mipmap-{d}", "ic_launcher_foreground.png"),
         keep_alpha=True)

# ───────────── Android 资源文件 ─────────────
os.makedirs(os.path.join(ANDROID_RES, "values"), exist_ok=True)
with open(os.path.join(ANDROID_RES, "values", "colors.xml"), "w",
          encoding="utf-8") as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n'
            "<resources>\n"
            '    <color name="ic_launcher_background">#FF10131A</color>\n'
            '    <color name="launch_background">#FF10131A</color>\n'
            "</resources>\n")

os.makedirs(os.path.join(ANDROID_RES, "mipmap-anydpi-v26"), exist_ok=True)
with open(os.path.join(ANDROID_RES, "mipmap-anydpi-v26", "ic_launcher.xml"),
          "w", encoding="utf-8") as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android='
            '"http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@color/ic_launcher_background"/>\n'
            '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
            "</adaptive-icon>\n")

# 启动图：深色底 + 居中图标
for folder in ("drawable", "drawable-v21"):
    p = os.path.join(ANDROID_RES, folder, "launch_background.xml")
    with open(p, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<layer-list xmlns:android='
                '"http://schemas.android.com/apk/res/android">\n'
                '    <item android:drawable="@color/launch_background" />\n'
                "    <item>\n"
                "        <bitmap\n"
                '            android:gravity="center"\n'
                '            android:src="@mipmap/ic_launcher" />\n'
                "    </item>\n"
                "</layer-list>\n")

# ───────────── iOS AppIcon ─────────────
IOS_SIZES = [
    ("20x20", 1, 20), ("20x20", 2, 40), ("20x20", 3, 60),
    ("29x29", 1, 29), ("29x29", 2, 58), ("29x29", 3, 87),
    ("40x40", 1, 40), ("40x40", 2, 80), ("40x40", 3, 120),
    ("60x60", 2, 120), ("60x60", 3, 180),
    ("76x76", 1, 76), ("76x76", 2, 152),
    ("83.5x83.5", 2, 167),
    ("1024x1024", 1, 1024),
]
images = []
for base, scale, px in IOS_SIZES:
    name = f"Icon-App-{base}@{scale}x.png"
    save(render(px, True), os.path.join(IOS_APPICON, name))
    images.append({
        "size": base,
        "idiom": "ipad" if base in ("76x76", "83.5x83.5") else "iphone",
        "filename": name,
        "scale": f"{scale}x",
    })
# 1024 图标 idiom 为 ios-marketing
for item in images:
    if item["size"] == "1024x1024":
        item["idiom"] = "ios-marketing"
os.makedirs(IOS_APPICON, exist_ok=True)
with open(os.path.join(IOS_APPICON, "Contents.json"), "w", encoding="utf-8") as f:
    json.dump({"images": images,
               "info": {"version": 1, "author": "xcode"}}, f, indent=2,
              ensure_ascii=False)
with open(os.path.join(os.path.dirname(IOS_APPICON), "Contents.json"), "w",
          encoding="utf-8") as f:
    json.dump({"info": {"version": 1, "author": "xcode"}}, f, indent=2)

# 预览图（1024，供人工查看）
preview = os.path.join(
    r"C:\Users\86177\Documents\deepseek-harness\default-workspace",
    "perchplay_icon_preview.png")
render(1024, True).convert("RGB").save(preview, "PNG")
print("preview:", preview)
print("done")
