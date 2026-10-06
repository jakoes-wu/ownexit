"""ownexit：把租来的 VPS 变成自己的固定出口（直连或经中转）。

本包只提供 `ownexit` 命令入口，实际工作由包内自带的 bash 脚本完成（见 ownexit.cli）。
版本号唯一来源：发布时改这里，pypi.yml 会核对 wheel 版本与 tag 一致。
"""

__version__ = "1.0.0"
