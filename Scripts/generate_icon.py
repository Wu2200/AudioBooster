import os
import sys
from PIL import Image

def process_app_icon():
    out_dir = "AudioBooster/Assets.xcassets/AppIcon.appiconset"
    out_path = os.path.join(out_dir, "icon-1024.png")
    os.makedirs(out_dir, exist_ok=True)

    # 1. 查找用户上传的图片文件（按优先级）
    candidates = [
        "Scripts/IMG_1783.png",
        "Scripts/icon.png",
        "Scripts/custom_icon.png",
        "Scripts/app_icon.png"
    ]

    source_path = None
    for p in candidates:
        if os.path.exists(p) and os.path.getsize(p) > 1000:
            source_path = p
            break

    if not source_path:
        print("未在 Scripts/ 目录下检测到用户自定义图片，保持现有图标。")
        return

    print("==========================================")
    print(f"🎨 正在将用户上传的原图转为 iOS 官方 1024x1024 App 图标: {source_path}")
    print("==========================================")

    img = Image.open(source_path)
    print(f"原始图片信息: 尺寸={img.size}, 色彩模式={img.mode}, 格式={img.format}")

    # 2. 如果包含透明通道，在纯白底图上合成转为 RGB
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        rgba = img.convert("RGBA")
        white_bg = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        img = Image.alpha_composite(white_bg, rgba).convert("RGB")
    else:
        img = img.convert("RGB")

    w, h = img.size

    # 3. 智能检测四角外框与圆角展示背景
    c_tl = img.getpixel((0, 0))
    c_tr = img.getpixel((w - 1, 0))
    c_bl = img.getpixel((0, h - 1))
    c_br = img.getpixel((w - 1, h - 1))

    e_top = img.getpixel((w // 2, 0))
    e_bottom = img.getpixel((w // 2, h - 1))
    e_left = img.getpixel((0, h // 2))
    e_right = img.getpixel((w - 1, h // 2))

    corner_lum = sum(sum(c) for c in [c_tl, c_tr, c_bl, c_br]) / 12.0
    edge_lum = sum(sum(e) for e in [e_top, e_bottom, e_left, e_right]) / 12.0

    print(f"角点平均亮度: {corner_lum:.1f}, 边缘平均亮度: {edge_lum:.1f}")

    # 如果角点明显暗于内部（差值 > 6），说明外部有灰框背景
    # 智能裁切掉外部展示卡片的浅灰留白（约 4.5%），使白色底板完美延伸到边缘，让 iOS 系统原生圆角裁剪最自然
    if corner_lum < 250 and edge_lum >= 250 and (edge_lum - corner_lum) > 6:
        margin = int(min(w, h) * 0.046)
        print(f"检测到展示画框外围浅灰底色，智能裁切外圈 {margin}px 消除多余画框与双重圆角...")
        img = img.crop((margin, margin, w - margin, h - margin))
    elif abs(w - h) > 0:
        # 正方形裁切
        dim = min(w, h)
        l = (w - dim) // 2
        t = (h - dim) // 2
        img = img.crop((l, t, l + dim, t + dim))

    # 4. 高保真 LANCZOS 重采样至 iOS 标准 1024x1024
    final_icon = img.resize((1024, 1024), Image.Resampling.LANCZOS)

    # 5. 保存
    final_icon.save(out_path, "PNG", optimize=True)
    size_bytes = os.path.getsize(out_path)
    print(f"✅ 官方 App 图标转换完成: {out_path} ({size_bytes} 字节)")

if __name__ == "__main__":
    process_app_icon()
