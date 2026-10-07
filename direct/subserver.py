#!/usr/bin/env python3
"""ownexit 直连订阅服务（在 VPS 上以 nobody 运行，替代 `python3 -m http.server`）。

只响应 `GET` / `HEAD` `/<32 位十六进制 TOKEN>/<clash.yaml|shadowrocket.txt|sing-box.json|node.txt|sub>`：
前四个原样返回订阅目录里的文件；`sub` 按客户端 User-Agent 返回其中一个（Clash 系 → clash.yaml，
sing-box 系 → sing-box.json，其余 → shadowrocket.txt），让用户只需要一条地址。
其它任何路径（根、目录、本文件、index.html）一律 404 空体：TOKEN 是唯一的访问凭据，不能被列出。
不记录请求日志：`http.server` 默认会把带 TOKEN 的请求路径写进 journal。

只用标准库；由 direct/setup_direct.sh 随订阅目录一起同步到 /opt/ownexit-subscription/ 并写进 systemd 单元。
用法：subserver.py --port <端口> --root <订阅目录>
"""

import argparse
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 路径白名单：TOKEN 与文件名都被正则限定，拼出来的路径不可能越出订阅目录。
PATH_RE = re.compile(r"^/([0-9a-f]{32})/(clash\.yaml|shadowrocket\.txt|sing-box\.json|node\.txt|sub)$")

CONTENT_TYPES = {
    "clash.yaml": "text/yaml; charset=utf-8",
    "sing-box.json": "application/json",
    "shadowrocket.txt": "text/plain; charset=utf-8",
    "node.txt": "text/plain; charset=utf-8",
}

ROOT = ""


def pick_by_user_agent(user_agent):
    """按 User-Agent 选订阅格式。认不出的客户端给 base64 节点列表（绝大多数 V2Ray 系客户端都能导）。"""
    ua = (user_agent or "").lower()
    if any(word in ua for word in ("clash", "mihomo", "stash", "verge")):
        return "clash.yaml"
    if "sing-box" in ua or "singbox" in ua or ua.startswith(("sfa/", "sfi/", "sfm/")):
        return "sing-box.json"
    return "shadowrocket.txt"


class Handler(BaseHTTPRequestHandler):
    server_version = "ownexit-subscription"
    sys_version = ""

    def log_message(self, fmt, *args):  # noqa: D401 - 覆盖基类：不记请求（路径里带 TOKEN）
        return

    def _resolve(self):
        """返回 (文件路径, 文件名, 是否自适应)；路径不在白名单时返回 (None, None, False)。"""
        match = PATH_RE.match(self.path.split("?", 1)[0])
        if not match:
            return None, None, False
        token, name = match.group(1), match.group(2)
        adaptive = name == "sub"
        if adaptive:
            name = pick_by_user_agent(self.headers.get("User-Agent"))
        return os.path.join(ROOT, token, name), name, adaptive

    def _serve(self, send_body):
        path, name, adaptive = self._resolve()
        if path is None:
            self._not_found()
            return
        try:
            with open(path, "rb") as handle:
                body = handle.read()
        except OSError:
            self._not_found()
            return
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPES[name])
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if adaptive and name == "clash.yaml":
            # Clash Verge 用它给导入的订阅取名。
            self.send_header("Content-Disposition", 'attachment; filename="ownexit.yaml"')
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def _not_found(self):
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._serve(True)

    def do_HEAD(self):
        self._serve(False)


def main():
    global ROOT
    parser = argparse.ArgumentParser(description="ownexit 直连订阅服务")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--root", required=True, help="订阅目录（每个 TOKEN 一个子目录）")
    args = parser.parse_args()
    if not (1 <= args.port <= 65535):
        sys.stderr.write("subserver: --port 必须是 1-65535\n")
        return 2
    if not os.path.isdir(args.root):
        sys.stderr.write("subserver: --root 不是目录：{}\n".format(args.root))
        return 2
    ROOT = os.path.abspath(args.root)
    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
