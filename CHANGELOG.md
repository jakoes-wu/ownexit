# 更新日志

本项目的所有重要变更都记录在这里。格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.1.0] - 2026-10-04

### 新增

- 直连：`direct/setup_direct.sh --host <ip>` 一条命令把一台 Debian / Ubuntu VPS 部署成固定出口（VLESS-Reality，sing-box 由 233boy/sing-box 安装），生成 Clash、Shadowrocket 订阅和 `vless://` 节点链接，并逐层验证。
- 直连：第一次部署时自动配好免密；成功后记住这台 VPS，之后 `setup_direct.sh`、`subctl` 不带参数也能用。
- 直连：`direct/subctl` 开关订阅服务（`start` / `stop` / `status`）或免密登录 VPS。
- 链式：`chain/setup_chain.sh init --relay <ip> --exit <ip>` 只问两个 IP，自动配免密、探测出口 IP 与中转现状并生成配置；`--id <名字>` 作为 `--config` 的简写；新增配置键 `EXIT_SOURCE_FILTER=provider|none`，普通 VPS 无外部白名单时（`none`，默认）出口机拒绝侧检查只记 WARN。
- 链式：`preflight` / `deploy` / `verify` / `status` / `rollback` 事务化部署与拆除，中转机只做 TCP 透传、不放密钥；`conns` / `kick` / `ban` / `unban` / `banlist` 管理中转连接；`rehost-exit` 在出口机同机换 IP 时原地迁移。
- 链式：`chain/multi_chain_client.sh` 把多条链聚合成带 `fallback` 自动组的客户端配置和逐链二维码。
- 密码只交互输入（或经环境变量 `OWNEXIT_SSH_PASSWORD`），每次只向服务器提交一次，交互最多 3 次；登录失败区分 `bad-password` / `password-disabled` / `unreachable`。
