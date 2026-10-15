import os
import sys
import glob
from PIL import Image

def process_app_icon():
    out_dir = "AudioBooster/Assets.xcassets/AppIcon.appiconset"
    out_path = os.path.join(out_dir, "icon-1024.png")
    os.makedirs(out_dir, exist_ok=True)

    # 1. 查找用户上传的图片文件（优先支持 Scripts/IMG_1783.jpeg 各种常见命名）
    candidates = [
        "Scripts/IMG_1783.jpeg",
        "Scripts/IMG_1783.jpg",
        "Scripts/IMG_1783.png",
        "Scripts/icon.jpeg",
        "Scripts/icon.jpg",
        "Scripts/icon.png",
        "Scripts/custom_icon.jpeg",
        "Scripts/custom_icon.jpg",
        "Scripts/custom_icon.png",
        "Scripts/app_icon.jpeg",
        "Scripts/app_icon.jpg",
        "Scripts/app_icon.png"
    ]

    source_path = None
    for p in candidates:
        if os.path.exists(p) and os.path.getsize(p) > 1000:
            source_path = p
            break

    # 如果特定名称未命中，自动检索 Scripts 目录下所有图片
    if not source_path and os.path.exists("Scripts"):
        for ext in ("*.jpeg", "*.jpg", "*.png", "*.webp", "*.JPEG", "*.JPG", "*.PNG"):
            matches = glob.glob(os.path.join("Scripts", ext))
            valid = [m for m in matches if os.path.getsize(m) > 1000]
            if valid:
                source_path = valid[0]
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

    # 3. 确保为正方形裁切
    if w != h:
        dim = min(w, h)
        l = (w - dim) // 2
        t = (h - dim) // 2
        img = img.crop((l, t, l + dim, t + dim))
        w = h = dim

    # 4. 智能检测四角外框与自带圆角展示背景
    corners = [
        img.getpixel((0, 0)),
        img.getpixel((w - 1, 0)),
        img.getpixel((0, h - 1)),
        img.getpixel((w - 1, h - 1)),
        img.getpixel((2, 2)),
        img.getpixel((w - 3, 2)),
        img.getpixel((2, h - 3)),
        img.getpixel((w - 3, h - 3)),
    ]
    corner_lum = sum(sum(c) for c in corners) / (len(corners) * 3.0)

    inner_samples = [
        img.getpixel((int(w * 0.15), int(h * 0.15))),
        img.getpixel((int(w * 0.85), int(h * 0.15))),
        img.getpixel((int(w * 0.15), int(h * 0.85))),
        img.getpixel((int(w * 0.85), int(h * 0.85)))
    ]
    inner_lum = sum(sum(c) for c in inner_samples) / (len(inner_samples) * 3.0)

    print(f"角点平均亮度: {corner_lum:.1f}, 内部卡片平均亮度: {inner_lum:.1f}")

    # 如果角点暗于内部（用户上传了带展示灰底的卡片图），裁切掉多余的灰框与双重圆角
    # 让纯白底板完全铺满 1024x1024，交给 iOS 官方系统去裁剪出标准 Squircle 圆角
    if corner_lum < 250 and inner_lum >= 245:
        margin = int(w * 0.055)
        print(f"检测到外部展示底色与卡片自带圆角，智能裁切四周各 {margin}px ({margin/w*100:.1f}%)...")
        img = img.crop((margin, margin, w - margin, h - margin))
    elif corner_lum < 240:
        margin = int(w * 0.05)
        print(f"检测到边角杂色，裁切四周 {margin}px...")
        img = img.crop((margin, margin, w - margin, h - margin))

    # 5. 高保真 LANCZOS 重采样至 iOS 标准 1024x1024
    final_icon = img.resize((1024, 1024), Image.Resampling.LANCZOS)

    # 6. 保存
    final_icon.save(out_path, "PNG", optimize=True)
    size_bytes = os.path.getsize(out_path)
    print(f"✅ 官方 App 图标转换完成: {out_path} ({size_bytes} 字节)")

if __name__ == "__main__":
    process_app_icon()
