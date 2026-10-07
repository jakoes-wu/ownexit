"""`ownexit` 命令入口：把子命令原样转发给包内自带的 bash 脚本。

职责边界：这里只做子命令到脚本的映射与转发，不解析、不改写脚本参数；所有校验、交互、
退出码都由脚本自己负责（包括脚本自己的 -h / --help）。脚本用 `bash <路径>` 执行，
因为 pip 安装不保证保留可执行位。

帮助文字按语言切换：OWNEXIT_LANG=zh|en 强制；否则看 LC_ALL / LC_MESSAGES / LANG 第一个非空值是否以 zh 开头。
只影响这里的 --help；各脚本的 --help 仍是中文。
"""

import os
import shutil
import sys

from . import __version__

_PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))

# 子命令 → (相对包目录的脚本路径, 一句话说明)。脚本目录 direct/、chain/ 与 git clone 时的仓库布局相同，
# 脚本之间按相对路径互相调用（如 chain/setup_chain.sh 调 ../direct/connect_to.sh），不要改目录结构。
# 每行必须保持 `    "<name>": (` 形态：scripts/check_interface.sh 按这个形态提取子命令表。
COMMANDS = {
    "direct": (os.path.join("direct", "setup_direct.sh"), "deploy a VPS as your direct exit (setup_direct.sh)"),
    "subctl": (os.path.join("direct", "subctl"), "subscription service start / stop / status, service log, node QR code, or log in (subctl)"),
    "connect": (os.path.join("direct", "connect_to.sh"), "set up key-based SSH login to a server (connect_to.sh)"),
    "chain": (os.path.join("chain", "setup_chain.sh"), "relay + exit chain: up / status / qr / verify / rollback ... (setup_chain.sh)"),
    "multi": (os.path.join("chain", "multi_chain_client.sh"), "combine several chains into one client config (multi_chain_client.sh)"),
    "doctor": (os.path.join("direct", "doctor.sh"), "check this computer, your servers and chains; --ip-check tests the exit IP (doctor.sh)"),
}

# 帮助里的分组：新用户只需要认识“常用”三个；其余按需查。
_GROUPS = (("common", ("direct", "chain", "doctor")), ("other", ("subctl", "multi", "connect")))

_TEXT = {
    "zh": {
        "usage": "用法: ownexit <命令> [参数...]",
        "common": "常用:",
        "other": "其它:",
        "direct": "把一台 VPS 部署成直连出口（第一次问一次 root 密码）",
        "chain": "中转 + 出口链：up 一步部署 / status / qr / verify / rollback ...",
        "doctor": "检查本机、服务器和链；--ip-check 体检出口 IP",
        "subctl": "直连订阅服务的开关、状态、日志、二维码，或免密登录 VPS",
        "multi": "把多条链合成一份客户端配置",
        "connect": "给一台服务器配免密 SSH（direct / chain 会自动调用）",
        "tail": "命令后面的参数原样交给对应脚本；用 `ownexit <命令> --help` 看它的参数。",
        "examples": "示例:",
    },
    "en": {
        "usage": "usage: ownexit <command> [arguments...]",
        "common": "common:",
        "other": "other:",
        "direct": "deploy a VPS as your direct exit (asks the root password once)",
        "chain": "relay + exit chain: up (one-step deploy) / status / qr / verify / rollback ...",
        "doctor": "check this computer, your servers and chains; --ip-check tests the exit IP",
        "subctl": "subscription service start / stop / status, service log, node QR code, or log in",
        "multi": "combine several chains into one client config",
        "connect": "set up key-based SSH login to a server (called by direct / chain automatically)",
        "tail": "Arguments after the command go to the script unchanged; use `ownexit <command> --help` for its options.",
        "examples": "examples:",
    },
}

_EXAMPLES = (
    "ownexit direct --host 203.0.113.7",
    "ownexit chain up --relay 203.0.113.10 --exit 203.0.113.20",
    "ownexit chain status",
    "ownexit doctor --ip-check",
    "",
    "ownexit --version",
)


def _lang():
    forced = os.environ.get("OWNEXIT_LANG", "").strip().lower()
    if forced in ("zh", "en"):
        return forced
    for name in ("LC_ALL", "LC_MESSAGES", "LANG"):
        value = os.environ.get(name, "")
        if value:
            return "zh" if value.lower().startswith("zh") else "en"
    return "en"


def _usage():
    text = _TEXT[_lang()]
    lines = [text["usage"], ""]
    for group, names in _GROUPS:
        lines.append(text[group])
        for name in names:
            lines.append("  {:<9}{}".format(name, text[name]))
        lines.append("")
    lines.append(text["tail"])
    lines.append("")
    lines.append(text["examples"])
    for example in _EXAMPLES:
        lines.append("  " + example if example else "")
    return "\n".join(lines)


def main(argv=None):
    args = sys.argv[1:] if argv is None else list(argv)
    if not args or args[0] in ("-h", "--help", "help"):
        print(_usage())
        return 0
    if args[0] in ("-V", "--version"):
        print("ownexit {}".format(__version__))
        return 0
    name = args[0]
    if name not in COMMANDS:
        sys.stderr.write("ownexit: unknown command: {}\n\n{}\n".format(name, _usage()))
        return 2
    script = os.path.join(_PACKAGE_DIR, COMMANDS[name][0])
    if not os.path.isfile(script):
        sys.stderr.write("ownexit: bundled script is missing: {}\n".format(script))
        return 1
    bash = shutil.which("bash")
    if bash is None:
        sys.stderr.write("ownexit: bash is required but was not found in PATH\n")
        return 1
    # execv 替换当前进程：退出码、信号与交互式终端都直接属于脚本，不经过 Python。
    os.execv(bash, [bash, script] + args[1:])


if __name__ == "__main__":
    sys.exit(main())
