import math
import os
from PIL import Image, ImageDraw, ImageFilter

def create_app_icon():
    size = (1024, 1024)
    # 1. 底图：深邃科技午夜蓝深色渐变
    img = Image.new("RGBA", size, (10, 15, 30, 255))
    draw = ImageDraw.Draw(img)

    for y in range(1024):
        t = y / 1024.0
        # 从顶部的优雅深蓝紫到下方的午夜深黑
        r = int(15 * (1 - t) + 4 * t)
        g = int(28 * (1 - t) + 8 * t)
        b = int(58 * (1 - t) + 16 * t)
        draw.line([(0, y), (1024, y)], fill=(r, g, b, 255))

    # 2. 中心发光扩散光晕 (声场能量)
    glow = Image.new("RGBA", size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse([260, 260, 764, 764], fill=(30, 110, 255, 90))
    glow = glow.filter(ImageFilter.GaussianBlur(70))
    img = Image.alpha_composite(img, glow)
    draw = ImageDraw.Draw(img)

    # 3. 绘制 2x, 3x, 4x 环形突破声浪弧线
    # 弧度中心位于扬声器号角出口前偏左位置
    center_x, center_y = 520, 512

    def draw_curved_wave(r, width, color):
        box = [center_x - r, center_y - r, center_x + r, center_y + r]
        draw.arc(box, start=-50, end=50, fill=color, width=width)

    # 1x/2x 科技炫蓝
    draw_curved_wave(r=170, width=28, color=(40, 150, 255, 240))
    # 3x 强力橙黄
    draw_curved_wave(r=260, width=32, color=(255, 160, 20, 240))
    # 4x 极限猩红突破
    draw_curved_wave(r=350, width=36, color=(255, 50, 70, 240))

    # 4. 绘制质感扬声器主体 (白色极简现代设计)
    # 扬声器后座方块
    draw.rounded_rectangle([200, 390, 360, 634], radius=24, fill=(245, 248, 255, 255))

    # 扬声器扩散锥体 (扩音号角)
    cone_points = [
        (360, 390),
        (540, 250),
        (540, 774),
        (360, 634)
    ]
    draw.polygon(cone_points, fill=(255, 255, 255, 255))
    # 号角口微弧立体边缘
    draw.ellipse([518, 250, 562, 774], fill=(235, 242, 255, 255))

    # 5. 扬声器内部嵌入金色增益突破闪电 (Boost Lightning Bolt)
    bolt_points = [
        (380, 365),
        (300, 505),
        (365, 505),
        (320, 660),
        (455, 485),
        (385, 485)
    ]
    draw.polygon(bolt_points, fill=(255, 205, 0, 255))

    # 6. 转为标准 24-bit RGB (符合苹果规范，无透明通道)
    final_img = img.convert("RGB")

    os.makedirs("AudioBooster/Assets.xcassets/AppIcon.appiconset", exist_ok=True)
    out_path = "AudioBooster/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    final_img.save(out_path, "PNG")
    print(f"成功生成高清 App 图标: {out_path} ({os.path.getsize(out_path)} 字节)")

if __name__ == "__main__":
    create_app_icon()
