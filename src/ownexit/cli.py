"""`ownexit` 命令入口：把子命令原样转发给包内自带的 bash 脚本。

职责边界：这里只做子命令到脚本的映射与转发，不解析、不改写脚本参数；所有校验、交互、
退出码都由脚本自己负责（包括脚本自己的 -h / --help）。脚本用 `bash <路径>` 执行，
因为 pip 安装不保证保留可执行位。
"""

import os
import shutil
import sys

from . import __version__

_PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))

# 子命令 → (相对包目录的脚本路径, 一句话说明)。脚本目录 direct/、chain/ 与 git clone 时的仓库布局相同，
# 脚本之间按相对路径互相调用（如 chain/setup_chain.sh 调 ../direct/connect_to.sh），不要改目录结构。
COMMANDS = {
    "direct": (os.path.join("direct", "setup_direct.sh"), "deploy a VPS as your direct exit (setup_direct.sh)"),
    "subctl": (os.path.join("direct", "subctl"), "subscription service start / stop / status, service log, node QR code, or log in (subctl)"),
    "connect": (os.path.join("direct", "connect_to.sh"), "set up key-based SSH login to a server (connect_to.sh)"),
    "chain": (os.path.join("chain", "setup_chain.sh"), "relay + exit chain: init / deploy / verify / rollback ... (setup_chain.sh)"),
    "multi": (os.path.join("chain", "multi_chain_client.sh"), "combine several chains into one client config (multi_chain_client.sh)"),
}


def _usage():
    lines = [
        "usage: ownexit <command> [arguments...]",
        "",
        "commands:",
    ]
    for name, (_, summary) in COMMANDS.items():
        lines.append("  {:<9}{}".format(name, summary))
    lines += [
        "",
        "Arguments after the command go to the script unchanged; use `ownexit <command> --help` for its options.",
        "",
        "examples:",
        "  ownexit direct --host 203.0.113.7",
        "  ownexit chain init --relay 203.0.113.10 --exit 203.0.113.20",
        "  ownexit chain --id main deploy",
        "",
        "  ownexit --version",
    ]
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
