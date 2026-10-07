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
# subctl（已并入 direct）与 connect（direct / chain init 自动调用）从 1.5.0 起不在帮助里列出，但照常可以转发。
_GROUPS = (("common", ("direct", "chain", "doctor")), ("other", ("multi",)))

_TEXT = {
    "zh": {
        "usage": "用法: ownexit <命令> [参数...]",
        "common": "常用:",
        "other": "其它:",
        "direct": "直连出口：up 部署 / sub start|stop / status / rotate-keys ...（第一次问一次 root 密码）",
        "chain": "中转 + 出口链：up 一步部署 / status / qr / verify / rollback ...",
        "doctor": "检查本机、服务器和链；--ip-check 体检出口 IP",
        "multi": "把多条链合成一份客户端配置",
        "tail": "命令后面的参数原样交给对应脚本；用 `ownexit <命令> --help` 看它的参数。\n在终端里只敲 `ownexit`（不带参数）进入向导：先选语言，再一步步问清楚后部署。",
        "examples": "示例:",
    },
    "en": {
        "usage": "usage: ownexit <command> [arguments...]",
        "common": "common:",
        "other": "other:",
        "direct": "direct exit: up (deploy) / sub start|stop / status / rotate-keys ... (asks the root password once)",
        "chain": "relay + exit chain: up (one-step deploy) / status / qr / verify / rollback ...",
        "doctor": "check this computer, your servers and chains; --ip-check tests the exit IP",
        "multi": "combine several chains into one client config",
        "tail": "Arguments after the command go to the script unchanged; use `ownexit <command> --help` for its options.\nRun `ownexit` with no arguments in a terminal for a guided setup (it asks for a language first).",
        "examples": "examples:",
    },
}

_EXAMPLES = (
    "ownexit direct up --host 203.0.113.7",
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


# 向导文案（中 / 英）。向导只负责问清楚“直连还是链式、IP 和端口”，然后转给 direct / chain up 执行，
# 不做任何部署逻辑；所以它问错了也只影响传给脚本的参数，脚本自己仍会逐项校验。
_WIZARD = {
    "zh": {
        "title": "ownexit 向导（随时 Ctrl+C 退出）",
        "mode": "在你这里能直接连上这台 VPS 吗？（大多数海外 VPS 在国内连不上或很慢，就选 2）\n"
                "  1) 能 —— 直连，1 台 VPS\n"
                "  2) 不能 —— 链式，前面加一台中转机，共 2 台\n"
                "请选择 [1/2]: ",
        "vps": "VPS 的公网 IPv4: ",
        "relay": "中转机的公网 IPv4: ",
        "exit": "出口机（最终出网的那台）的公网 IPv4: ",
        "port": "{} 的 SSH 端口 [22]: ",
        "bad_ip": "不是有效的 IPv4，请重输。",
        "bad_port": "端口要是 1-65535 的数字，请重输。",
        "same": "中转机和出口机必须是两台不同的机器，请重输出口机。",
        "run": "即将运行：ownexit {}",
        "scripts_zh": "",
        "cancel": "已取消",
    },
    "en": {
        "title": "ownexit guided setup (Ctrl+C to quit at any time)",
        "mode": "Can you reach this VPS directly from where you are? (Many VPSes abroad are unreachable or slow from mainland China; pick 2 then.)\n"
                "  1) Yes - direct, one VPS\n"
                "  2) No  - relay chain, add a relay in front, two servers\n"
                "Choose [1/2]: ",
        "vps": "Public IPv4 of the VPS: ",
        "relay": "Public IPv4 of the relay: ",
        "exit": "Public IPv4 of the exit (where traffic finally leaves): ",
        "port": "SSH port of {} [22]: ",
        "bad_ip": "Not a valid IPv4 address, try again.",
        "bad_port": "The port must be a number from 1 to 65535, try again.",
        "same": "The relay and the exit must be two different servers; enter the exit again.",
        "run": "About to run: ownexit {}",
        "scripts_zh": "Note: the setup scripts print their progress in Chinese for now; the commands and results are the same.",
        "cancel": "Cancelled",
    },
}

# 语言还没选定时只能中英并列显示（这两条之后才按所选语言走 _WIZARD）。
_LANG_PROMPT = "ownexit\n  1) 中文\n  2) English\n请选择 / Choose [1/2] (Enter = {}; set OWNEXIT_LANG=zh|en to skip): "
_LANG_CANCEL = "已取消 / Cancelled"


def _is_ipv4(value):
    """与脚本同一口径：四段十进制、每段 0-255、不带前导零。"""
    parts = value.split(".")
    if len(parts) != 4:
        return False
    for part in parts:
        if not part.isdigit() or (len(part) > 1 and part[0] == "0") or int(part) > 255:
            return False
    return True


def _ask(text, check, error):
    while True:
        value = input(text).strip()
        if check(value):
            return value
        print(error)


def _ask_port(text, error):
    value = _ask(text, lambda v: v == "" or (v.isdigit() and v[0] != "0" and int(v) <= 65535), error)
    return value or "22"


def _choose_lang():
    """向导第一步：选语言，返回 "zh" / "en"。

    OWNEXIT_LANG 为 zh / en 时直接用它、不问（可脚本化，也给嫌多按一次回车的人一个跳过办法）；
    其它值等同未设。回车取 _lang() 按 locale 的判断结果，所以只按回车的人得到的仍是 1.5.0 的语言。
    """
    forced = os.environ.get("OWNEXIT_LANG", "").strip().lower()
    if forced in ("zh", "en"):
        return forced
    default = _lang()
    prompt = _LANG_PROMPT.format("中文" if default == "zh" else "English")
    choice = _ask(prompt, lambda v: v in ("", "1", "2"), "1 / 2")
    if choice == "":
        return default
    return "zh" if choice == "1" else "en"


def _wizard(lang):
    """交互式问清部署方式与地址，返回要转发的参数列表（如 ["direct", "up", "--host", "203.0.113.7"]）。

    lang 由 _choose_lang() 决定，之后的提问、报错都用这种语言。
    """
    t = _WIZARD[lang]
    print(t["title"])
    print()
    mode = _ask(t["mode"], lambda v: v in ("1", "2"), "1 / 2")
    if mode == "1":
        host = _ask(t["vps"], _is_ipv4, t["bad_ip"])
        port = _ask_port(t["port"].format(host), t["bad_port"])
        args = ["direct", "up", "--host", host]
        if port != "22":
            args += ["--port", port]
        return args
    relay = _ask(t["relay"], _is_ipv4, t["bad_ip"])
    relay_port = _ask_port(t["port"].format(relay), t["bad_port"])
    while True:
        exit_host = _ask(t["exit"], _is_ipv4, t["bad_ip"])
        if exit_host != relay:
            break
        print(t["same"])
    exit_port = _ask_port(t["port"].format(exit_host), t["bad_port"])
    args = ["chain", "up", "--relay", relay, "--exit", exit_host]
    if relay_port != "22":
        args += ["--relay-port", relay_port]
    if exit_port != "22":
        args += ["--exit-port", exit_port]
    return args


def main(argv=None):
    args = sys.argv[1:] if argv is None else list(argv)
    if not args and sys.stdin.isatty() and sys.stdout.isatty():
        # 只有在交互终端里不带参数才进向导；脚本、管道、CI 里照旧打印帮助，行为与 1.3.0 相同。
        # 语言选定之前取消只能打印中英并列的文字，选定之后用所选语言；退出码两种情况都一样。
        t = None
        try:
            lang = _choose_lang()
            t = _WIZARD[lang]
            args = _wizard(lang)
        except KeyboardInterrupt:
            print()
            print(t["cancel"] if t else _LANG_CANCEL)
            return 130
        except EOFError:
            print()
            print(t["cancel"] if t else _LANG_CANCEL)
            return 1
        print(t["run"].format(" ".join(args)))
        if t["scripts_zh"]:
            print(t["scripts_zh"])
        if os.environ.get("OWNEXIT_TEST_WIZARD_PRINT") == "1":
            # 测试钩子：只打印将要转发的参数，不执行（OWNEXIT_TEST_ 前缀不属于公开接口）。
            for arg in args:
                print(arg)
            return 0
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
    # 把入口自己的解释器告诉脚本：pipx 的 venv 里装着 pexpect，connect_to.sh 用它自动输入密码，
    # 不必再依赖系统的 expect；用户已自己设置时不覆盖。
    env = dict(os.environ)
    env.setdefault("OWNEXIT_PYTHON", sys.executable)
    # execve 替换当前进程：退出码、信号与交互式终端都直接属于脚本，不经过 Python。
    os.execve(bash, [bash, script] + args[1:], env)


if __name__ == "__main__":
    sys.exit(main())
