# Cloudflare One-Click Install Design

## 目标

让用户可以通过 `curl -fsSL https://nft.hide.ss | sudo bash` 一键运行当前脚本，同时保持 systemd timer 使用稳定的 `/usr/local/sbin/nft.sh` 路径。

## 范围

- 新增 Cloudflare Worker 静态资源分发骨架。
- 新增安装入口脚本 `install.sh`。
- 修正 `nft.sh` 在 pipe / process substitution 入口下的自安装逻辑。
- 更新 README 中的一键安装与 Cloudflare 部署说明。

## 不做什么

- 不引入 WebUI。
- 不引入 R2、数据库、账号系统、下载统计。
- 不改变 nftables NAT / domain NAT 规则生成逻辑。
- 不做自动升级器或签名体系；本次只做 `sha256` 校验。

## 架构

Cloudflare Worker 只负责分发静态文件，`/` 与 `/install.sh` 返回同一个 installer，`/nft.sh` 返回主脚本，`/version` 和 `/sha256.txt` 作为版本与校验辅助文件。这样让 Cloudflare 侧职责单一，避免把部署平台逻辑塞进 nftables 管理脚本。

`install.sh` 负责下载 `/nft.sh` 到临时文件、执行 `bash -n` 语法检查、校验可选的 `sha256.txt`、备份旧 `/usr/local/sbin/nft.sh`，然后以 `0755` 安装并执行它。`nft.sh` 自身保留现有本地文件复制逻辑；当 `${BASH_SOURCE[0]}` 不是普通可读文件时，才从 `NFT_FORWARD_SCRIPT_URL` 下载自身到 `SCRIPT_PATH`。

## 错误处理

- installer 下载失败、语法检查失败、hash 不匹配、安装失败均直接退出非零。
- `nft.sh` 自安装 fallback 下载失败时只告警并让 timer 安装失败，不阻塞用户看到明确错误。
- `sha256.txt` 不可用时 installer 允许继续，但会提示跳过校验，避免单点元数据故障让安装完全不可用。

## 测试

- `bash -n nft.sh`、`bash -n deploy/cloudflare/public/install.sh`。
- shell focused tests 覆盖：
  - `install.sh` 使用固定 base URL 下载、校验、安装并执行主脚本。
  - `nft.sh` 在无法从本地普通文件复制时，从 `NFT_FORWARD_SCRIPT_URL` 下载并安装到 `SCRIPT_PATH`。
  - Cloudflare Worker 资源路径存在，根路径语义由静态资源目录承载。

## 原则落地

- KISS：Worker + 静态文件，不做后台服务。
- YAGNI：不做 R2、统计、升级器和 WebUI。
- DRY：`/` 与 `/install.sh` 共用一个 installer 文件。
- SOLID：分发、安装、nftables 管理三块职责分离，后续替换 Cloudflare 不影响 NAT 逻辑。
