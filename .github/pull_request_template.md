## What changed / 改了什么

## Self-check / 自检

- [ ] `bash -n` and `shellcheck -S warning` pass; scripts under `chain/` parse with macOS `/bin/bash` 3.2 / `bash -n`、`shellcheck -S warning` 通过；`chain/` 下的脚本能被 macOS `/bin/bash` 3.2 解析
- [ ] `scripts/check_interface.sh` and `scripts/check_i18n.sh` pass / `scripts/check_interface.sh`、`scripts/check_i18n.sh` 通过
- [ ] `scripts/check_public.sh` passes: no real IPs, domains or credentials / `scripts/check_public.sh` 通过，没有真实 IP、域名或凭据
- [ ] Test environment stated (control machine OS, VPS distribution) / 写明了实测环境（控制端系统、VPS 发行版）
- [ ] User-visible changes are reflected in `README.md`, `README.zh-CN.md`, `docs/manual/`, `docs/reference/` (both languages) and `CHANGELOG.md` / 用户可见的变化已同步 `README.md`、`README.zh-CN.md`、`docs/manual/`、`docs/reference/`（中英两版）和 `CHANGELOG.md`
