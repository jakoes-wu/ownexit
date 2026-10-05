#!/usr/bin/env python3
"""生成 README 演示 GIF 与 GitHub 社交预览图（docs/feature/feature-pypi-dist.md §5.1.4）。

前置条件：
  - 在 macOS 上运行：字体固定用 /System/Library/Fonts/Menlo.ttc（等宽，ASCII）、Hiragino Sans GB.ttc（中文）与
    Helvetica.ttc（标题），找不到就报错退出，不回落到其它字体——换字体会让图片尺寸和排版悄悄变化。
  - Python 3.8+，已安装 Pillow（pip install Pillow）；不需要网络，不连接任何服务器。
  - 从仓库任意目录运行均可，输出默认写到仓库的 docs/assets/。

做法：SESSION 是一段取自真实运行的终端会话（ownexit chain init / deploy / status 的关键输出行），
IP 一律换成文档专用地址（203.0.113.x），不含 UUID、密钥、节点链接；本脚本只负责按终端样式逐帧绘制。
修改 SESSION 时只能删减或替换为同一次真实运行的输出，不要编造脚本不会打印的内容。
"""

import argparse
import os
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MONO_FONT = "/System/Library/Fonts/Menlo.ttc"
CJK_FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
SANS_FONT = "/System/Library/Fonts/Helvetica.ttc"

# 终端配色：深色背景，提示符绿色、注释灰色、输出浅色。
BG = (30, 30, 46)
FG = (205, 214, 244)
PROMPT = (166, 227, 161)
COMMENT = (127, 132, 156)
TITLE_BAR = (49, 50, 68)

RELAY = "203.0.113.10"
EXIT = "203.0.113.20"

# (命令或注释, 输出行列表)。注释以 # 开头，整行出现；命令逐字打出。
SESSION = [
    ("# relay + exit: give it two IPs", []),
    ("ownexit chain init --relay {} --exit {}".format(RELAY, EXIT), [
        "[chain][init] INFO 中转机 {}:22 配置免密".format(RELAY),
        "VPS 密码（root@{}:22）:".format(RELAY),
        "[+] 免密配置完成：root@{}:22".format(RELAY),
        "[chain][init] INFO 出口机 {}:22 配置免密".format(EXIT),
        "VPS 密码（root@{}:22）:".format(EXIT),
        "[+] 免密配置完成：root@{}:22".format(EXIT),
        "[chain][init] INFO 出口机公网 IP：{}".format(EXIT),
        "确认客户端经这条链出去的 IP 应当是 {}？[y/N] y".format(EXIT),
        "[chain][init] INFO EXIT_SOURCE_FILTER=managed：部署时会在出口机加 nft 白名单，Reality 端口只放行中转机",
        "[chain][init] INFO 已生成 ~/.config/ownexit/chains/main.env",
    ]),
    ("ownexit chain --id main deploy", [
        "[chain][deploy] INFO relay binary 来源=remote-download arch=amd64",
        "[chain][deploy] INFO exit binary 来源=remote-download arch=amd64",
        "[chain][deploy] INFO 出口机白名单放行来源={}（EXIT_SOURCE_FILTER=managed）".format(RELAY),
        "[chain][deploy] INFO 出口机 Reality 端口的本机直连拒绝侧通过",
        "[chain][deploy] INFO deploy 完成；chain=main deployment=4b147d577007 elapsed=540s",
    ]),
    ("ownexit chain --id main status", [
        "status=deployed health=healthy deployment=4b147d577007",
    ]),
    ("# import ~/.local/state/ownexit/chains/main/client/node.txt into your client, then:", []),
    ("curl -s https://api.ipify.org", [
        EXIT,
    ]),
]

EXAMPLES = """examples:
  make-assets.py                         write docs/assets/demo.gif and social-preview.png
  make-assets.py --out /tmp/assets       write the two images to another directory
  make-assets.py --print                 only print the session text
"""


def load_fonts():
    for path in (MONO_FONT, CJK_FONT, SANS_FONT):
        if not os.path.exists(path):
            sys.exit("font not found: {} (this script runs on macOS only, see -h)".format(path))
    from PIL import ImageFont
    return {
        "mono": ImageFont.truetype(MONO_FONT, 15),
        "cjk": ImageFont.truetype(CJK_FONT, 15),
        "title": ImageFont.truetype(SANS_FONT, 64),
        "tagline": ImageFont.truetype(SANS_FONT, 30),
        "social_mono": ImageFont.truetype(MONO_FONT, 22),
        "social_cjk": ImageFont.truetype(CJK_FONT, 22),
    }


def is_wide(char):
    return unicodedata.east_asian_width(char) in ("W", "F")


def draw_mixed(draw, xy, text, mono, cjk, fill):
    """逐字选字体绘制：Menlo 没有中文字形，中文与全角标点改用 Hiragino Sans GB，其余用 Menlo。返回绘制后的 x。"""
    x, y = xy
    for char in text:
        font = cjk if is_wide(char) else mono
        draw.text((x, y), char, font=font, fill=fill)
        x += font.getlength(char)
    return x


def text_width(text, mono, cjk):
    return sum((cjk if is_wide(c) else mono).getlength(c) for c in text)


def make_gif(out_path, fonts):
    from PIL import Image, ImageDraw

    mono, cjk = fonts["mono"], fonts["cjk"]
    line_h, pad, top = 22, 18, 34
    widest = max(text_width(t, mono, cjk) for command, output in SESSION for t in [command] + output)
    width = int(widest) + pad * 2 + 30
    rows = sum(1 + len(output) for _, output in SESSION)
    height = top + pad * 2 + rows * line_h
    lines = []  # 已经显示的 (颜色, 文本)
    frames, durations = [], []

    def render(cursor_text=None):
        image = Image.new("RGB", (width, height), BG)
        draw = ImageDraw.Draw(image)
        draw.rectangle([0, 0, width, top - 8], fill=TITLE_BAR)
        for i, color in enumerate(((243, 139, 168), (249, 226, 175), (166, 227, 161))):
            draw.ellipse([14 + i * 20, 9, 26 + i * 20, 21], fill=color)
        y = top + pad
        shown = lines + ([cursor_text] if cursor_text else [])
        for color, text in shown:
            if color == PROMPT:
                draw.text((pad, y), "$", font=mono, fill=PROMPT)
                draw_mixed(draw, (pad + 18, y), text, mono, cjk, FG)
            else:
                draw_mixed(draw, (pad, y), text, mono, cjk, color)
            y += line_h
        return image

    def add(image, ms):
        frames.append(image)
        durations.append(ms)

    add(render(), 600)
    for command, output in SESSION:
        is_comment = command.startswith("#")
        color = COMMENT if is_comment else PROMPT
        # 命令逐字出现，每 2 个字符一帧；注释整行出现。
        if not is_comment:
            for end in range(2, len(command) + 2, 2):
                add(render((color, command[:end] + "_")), 40)
        lines.append((color, command))
        add(render(), 500 if not is_comment else 1200)
        # 输出逐行出现，模拟部署过程；最后一行停留更久。
        for index, line in enumerate(output):
            lines.append((FG, line))
            add(render(), 1600 if index == len(output) - 1 else 350)
    add(render(), 4000)
    # 64 色：32 色时窗口按钮的红黄绿会被量化成灰色。
    palette_frames = [frame.convert("P", palette=Image.ADAPTIVE, colors=64) for frame in frames]
    palette_frames[0].save(out_path, save_all=True, append_images=palette_frames[1:], duration=durations,
                           loop=0, optimize=True, disposal=1)


def make_social(out_path, fonts):
    """社交预览图：链接被分享时显示的缩略图。只放 init 与 status 两条命令，字号要大到缩略图里也看得清。"""
    from PIL import Image, ImageDraw

    mono, cjk = fonts["social_mono"], fonts["social_cjk"]
    image = Image.new("RGB", (1280, 640), BG)
    draw = ImageDraw.Draw(image)
    draw.text((80, 70), "ownexit", font=fonts["title"], fill=FG)
    draw.text((82, 155), "Your own fixed exit IP: direct or via a relay, one command", font=fonts["tagline"], fill=COMMENT)
    box = [80, 240, 1200, 510]
    draw.rounded_rectangle(box, radius=14, fill=(24, 24, 37), outline=TITLE_BAR, width=2)
    x0, y = box[0] + 32, box[1] + 34
    rows = [
        (PROMPT, "ownexit chain init --relay {} --exit {}".format(RELAY, EXIT)),
        (PROMPT, "ownexit chain --id main deploy"),
        (PROMPT, "ownexit chain --id main status"),
        (FG, "status=deployed health=healthy"),
    ]
    for color, text in rows:
        if color == PROMPT:
            draw.text((x0, y), "$", font=mono, fill=PROMPT)
            draw_mixed(draw, (x0 + 28, y), text, mono, cjk, FG)
        else:
            draw_mixed(draw, (x0, y), text, mono, cjk, color)
        y += 52
    draw.text((82, 550), "pipx install ownexit", font=fonts["tagline"], fill=PROMPT)
    draw.text((720, 550), "github.com/jakoes-wu/ownexit", font=fonts["tagline"], fill=COMMENT)
    image.save(out_path, optimize=True)


def main():
    parser = argparse.ArgumentParser(
        description="Generate docs/assets/demo.gif and docs/assets/social-preview.png from a recorded "
                    "ownexit session with example IPs (macOS, needs Pillow, no network).",
        epilog=EXAMPLES, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=os.path.join(ROOT, "docs", "assets"),
                        help="output directory (default: docs/assets in this repository)")
    parser.add_argument("--print", dest="print_only", action="store_true",
                        help="print the session text and exit without drawing")
    args = parser.parse_args()

    if args.print_only:
        for command, output in SESSION:
            print(command if command.startswith("#") else "$ " + command)
            for line in output:
                print(line)
        return 0
    import importlib.util
    if importlib.util.find_spec("PIL") is None:
        sys.exit("Pillow is required: pip install Pillow")
    fonts = load_fonts()
    os.makedirs(args.out, exist_ok=True)
    gif = os.path.join(args.out, "demo.gif")
    png = os.path.join(args.out, "social-preview.png")
    make_gif(gif, fonts)
    make_social(png, fonts)
    print("wrote {} ({} KB)".format(gif, os.path.getsize(gif) // 1024))
    print("wrote {} ({} KB)".format(png, os.path.getsize(png) // 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
