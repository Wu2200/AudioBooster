import math
import os
from PIL import Image, ImageDraw, ImageFilter

def create_minimal_app_icon():
    size = (1024, 1024)
    # 1. 底图：极简纯净的深空黑微质感微渐变 (Apple 风格暗色调)
    img = Image.new("RGBA", size, (18, 19, 23, 255))
    draw = ImageDraw.Draw(img)

    for y in range(1024):
        t = y / 1024.0
        # 从顶部的优雅深空墨黑微蓝到下方的深邃曜石黑
        r = int(24 * (1 - t) + 12 * t)
        g = int(26 * (1 - t) + 14 * t)
        b = int(32 * (1 - t) + 18 * t)
        draw.line([(0, y), (1024, y)], fill=(r, g, b, 255))

    # 2. 居中微弱柔和环境光 (仅营造层次感，不刺眼)
    glow = Image.new("RGBA", size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse([300, 300, 724, 724], fill=(0, 122, 255, 30))
    glow = glow.filter(ImageFilter.GaussianBlur(80))
    img = Image.alpha_composite(img, glow)
    draw = ImageDraw.Draw(img)

    # 3. 极简现代几何主体：纯白极简扬声器 (Minimalist Speaker)
    # 极简扬声器后座 (圆角矩形)
    draw.rounded_rectangle([250, 412, 380, 612], radius=28, fill=(255, 255, 255, 255))

    # 极简扬声器喇叭口 (规整梯形几何体)
    cone_points = [
        (380, 412),
        (540, 292),
        (540, 732),
        (380, 612)
    ]
    draw.polygon(cone_points, fill=(255, 255, 255, 255))
    # 扬声器前缘微圆角修饰
    draw.rounded_rectangle([520, 292, 544, 732], radius=12, fill=(255, 255, 255, 255))

    # 4. 纯净极简声波弧线 (两道优雅平滑圆弧，纯白半透明层次)
    center_x, center_y = 480, 512

    def draw_minimal_wave(r, stroke, alpha):
        wave_layer = Image.new("RGBA", size, (0, 0, 0, 0))
        w_draw = ImageDraw.Draw(wave_layer)
        box = [center_x - r, center_y - r, center_x + r, center_y + r]
        w_draw.arc(box, start=-40, end=40, fill=(255, 255, 255, alpha), width=stroke)
        return wave_layer

    # 第一道轻量内弧
    wave1 = draw_minimal_wave(r=180, stroke=26, alpha=235)
    img = Image.alpha_composite(img, wave1)

    # 第二道扩散外弧
    wave2 = draw_minimal_wave(r=275, stroke=24, alpha=170)
    img = Image.alpha_composite(img, wave2)

    # 第三道点睛轻波 (代表突破增益)
    wave3 = draw_minimal_wave(r=370, stroke=22, alpha=100)
    img = Image.alpha_composite(img, wave3)

    # 5. 转为标准 24-bit RGB (符合苹果规范，无透明通道)
    final_img = img.convert("RGB")

    os.makedirs("AudioBooster/Assets.xcassets/AppIcon.appiconset", exist_ok=True)
    out_path = "AudioBooster/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    final_img.save(out_path, "PNG")
    print(f"成功生成极简风 App 图标: {out_path} ({os.path.getsize(out_path)} 字节)")

if __name__ == "__main__":
    create_minimal_app_icon()
