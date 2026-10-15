import math
import os
from PIL import Image, ImageDraw, ImageFilter

def create_apple_music_style_icon():
    out_dir = "AudioBooster/Assets.xcassets/AppIcon.appiconset"
    out_path = os.path.join(out_dir, "icon-1024.png")

    # 如果存在用户自己上传的图标标记文件，或者显式指定不覆盖，则跳过
    if os.path.exists(os.path.join(out_dir, ".user_custom_icon")):
        print("检测到用户自定义图标标记，跳过自动生成，保留用户上传的图标。")
        return

    size = (1024, 1024)
    # 1. 底图：极简纯净的浅灰白优雅微渐变 (Apple 极简浅色风格)
    img = Image.new("RGBA", size, (248, 249, 252, 255))
    draw = ImageDraw.Draw(img)

    for y in range(1024):
        t = y / 1024.0
        # 从顶部的纯白优雅过渡到微灰白
        r = int(255 * (1 - t) + 245 * t)
        g = int(255 * (1 - t) + 247 * t)
        b = int(255 * (1 - t) + 252 * t)
        draw.line([(0, y), (1024, y)], fill=(r, g, b, 255))

    # 2. 背景飘逸柔和丝带波浪 (浅蓝青 + 浅粉紫)
    waves_layer = Image.new("RGBA", size, (0, 0, 0, 0))
    w_draw = ImageDraw.Draw(waves_layer)

    # 绘制蓝色柔和波浪
    blue_wave_pts = []
    for x in range(0, 1025, 10):
        wy = 520 + 75 * math.sin((x / 1024.0) * 1.5 * math.pi + 0.3)
        blue_wave_pts.append((x, wy))
    # 闭合形成多边形丝带
    poly_blue = [(0, 1024)] + blue_wave_pts + [(1024, 1024)]
    w_draw.polygon(poly_blue, fill=(0, 160, 255, 26))

    # 绘制粉紫柔和波浪
    purple_wave_pts = []
    for x in range(0, 1025, 10):
        wy = 550 + 80 * math.sin((x / 1024.0) * 1.8 * math.pi + 1.8)
        purple_wave_pts.append((x, wy))
    poly_purple = [(0, 1024)] + purple_wave_pts + [(1024, 1024)]
    w_draw.polygon(poly_purple, fill=(210, 60, 255, 20))

    waves_layer = waves_layer.filter(ImageFilter.GaussianBlur(30))
    img = Image.alpha_composite(img, waves_layer)

    # 3. 构建现代经典 Apple Music 风格渐变双音符 (Beam Note)
    # 采用高精度超采样绘制 (2x 尺寸抗锯齿)
    scale = 2
    render_size = (1024 * scale, 1024 * scale)
    mask = Image.new("L", render_size, 0)
    m_draw = ImageDraw.Draw(mask)

    # 坐标定义 (以 1024 为基准，乘以 scale)
    # 左音符头：倾斜椭圆
    left_cx, left_cy = 345 * scale, 695 * scale
    left_rx, left_ry = 125 * scale, 95 * scale

    # 右音符头：倾斜椭圆
    right_cx, right_cy = 685 * scale, 635 * scale
    right_rx, right_ry = 125 * scale, 95 * scale

    stem_width = 54 * scale
    left_stem_right = 445 * scale
    left_stem_left = left_stem_right - stem_width
    left_stem_top = 370 * scale

    right_stem_right = 785 * scale
    right_stem_left = right_stem_right - stem_width
    right_stem_top = 285 * scale

    beam_height = 110 * scale

    # 绘制音符头 (使用旋转椭圆)
    def draw_tilted_ellipse(draw_target, cx, cy, rx, ry, angle_deg, fill_val):
        temp = Image.new("L", (rx * 4, ry * 4), 0)
        t_draw = ImageDraw.Draw(temp)
        t_draw.ellipse([rx, ry, rx * 3, ry * 3], fill=fill_val)
        rotated = temp.rotate(angle_deg, resample=Image.Resampling.BICUBIC)
        box = (int(cx - rx * 2), int(cy - ry * 2))
        draw_target.bitmap(box, rotated, fill=fill_val)

    draw_tilted_ellipse(m_draw, left_cx, left_cy, left_rx, left_ry, -24, 255)
    draw_tilted_ellipse(m_draw, right_cx, right_cy, right_rx, right_ry, -24, 255)

    # 绘制左竖杆
    m_draw.rounded_rectangle([left_stem_left, left_stem_top, left_stem_right, left_cy], radius=int(stem_width // 2), fill=255)

    # 绘制右竖杆
    m_draw.rounded_rectangle([right_stem_left, right_stem_top, right_stem_right, right_cy], radius=int(stem_width // 2), fill=255)

    # 绘制顶部倾斜横梁 (平滑梯形连接，两端圆角)
    beam_polygon = [
        (left_stem_left, left_stem_top + beam_height),
        (left_stem_left, left_stem_top),
        (right_stem_right, right_stem_top),
        (right_stem_right, right_stem_top + beam_height)
    ]
    m_draw.polygon(beam_polygon, fill=255)
    m_draw.ellipse([left_stem_left - 10, left_stem_top, left_stem_left + stem_width * 2, left_stem_top + beam_height], fill=255)
    m_draw.ellipse([right_stem_right - stem_width * 2, right_stem_top, right_stem_right + 10, right_stem_top + beam_height], fill=255)

    # 降采样回 1024x1024 获得超高质量平滑抗锯齿边缘
    note_mask = mask.resize(size, Image.Resampling.LANCZOS)

    # 4. 生成音符渐变填充层 (左下亮天蓝 -> 中间亮紫罗兰 -> 右上魅惑玫粉红)
    grad_layer = Image.new("RGBA", size, (0, 0, 0, 0))
    g_draw = ImageDraw.Draw(grad_layer)

    # 对角线丰富渐变
    for y in range(1024):
        for x in range(1024):
            # 计算从左下 (x=200, y=800) 到 右上 (x=800, y=250) 的投影位置
            tx = (x - 200) / 600.0
            ty = (800 - y) / 550.0
            t = max(0.0, min(1.0, (tx + ty) / 2.0))

            if t < 0.5:
                # 阶段 1: 纯白天蓝 (0, 150, 255) -> 霓虹紫罗兰 (138, 75, 255)
                sub_t = t / 0.5
                r = int(0 * (1 - sub_t) + 138 * sub_t)
                g = int(150 * (1 - sub_t) + 75 * sub_t)
                b = int(255 * (1 - sub_t) + 255 * sub_t)
            else:
                # 阶段 2: 霓虹紫罗兰 (138, 75, 255) -> 绝美玫红粉 (255, 64, 160)
                sub_t = (t - 0.5) / 0.5
                r = int(138 * (1 - sub_t) + 255 * sub_t)
                g = int(75 * (1 - sub_t) + 64 * sub_t)
                b = int(255 * (1 - sub_t) + 160 * sub_t)

            grad_layer.putpixel((x, y), (r, g, b, 255))

    # 5. 音符环境漫反射柔和投影 (Drop Shadow)
    shadow_layer = Image.new("RGBA", size, (0, 0, 0, 0))
    s_draw = ImageDraw.Draw(shadow_layer)
    # 用蓝紫色填充阴影
    shadow_fill = Image.new("RGBA", size, (120, 50, 200, 110))
    shadow_layer = Image.composite(shadow_fill, shadow_layer, note_mask)
    # 模糊并向下偏移
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(38))
    # 偏移投影
    offset_shadow = Image.new("RGBA", size, (0, 0, 0, 0))
    offset_shadow.paste(shadow_layer, (0, 28))

    # 叠合阴影
    img = Image.alpha_composite(img, offset_shadow)

    # 6. 将渐变音符通过 mask 贴入主图
    colored_note = Image.new("RGBA", size, (0, 0, 0, 0))
    colored_note = Image.composite(grad_layer, colored_note, note_mask)
    img = Image.alpha_composite(img, colored_note)

    # 7. 导出为标准 24-bit RGB PNG (iOS 严格规范)
    final_img = img.convert("RGB")
    os.makedirs(out_dir, exist_ok=True)
    final_img.save(out_path, "PNG")
    print(f"成功生成 Apple Music 质感渐变双音符 App 图标: {out_path} ({os.path.getsize(out_path)} 字节)")

if __name__ == "__main__":
    create_apple_music_style_icon()
