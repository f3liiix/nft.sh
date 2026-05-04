# nft.sh — nftables 端口转发管理工具

面向 Linux 服务器的交互式脚本，用于管理 **DNAT 端口转发**，并在每条规则上可选配置 **按月回程流量限额**。

## 功能概览

| 能力 | 说明 |
|------|------|
| **安装与接管 nftables** | 检测或安装 `nftables`，生成/修补主配置中的 `include`，启用服务；若系统已有 nftables，安装流程会 **备份并清空现有规则集** 后由本脚本统一接管（需谨慎）。 |
| **新增转发** | 将 **本机监听端口（TCP + UDP）** 转发到指定 **目标 IPv4/域名:端口**；域名会先解析为 IPv4 再写入 nftables；支持备注；可选 **月流量上限**。 |
| **查看 / 编辑** | 列表展示规则，可就地修改 **月流量额度与备注**（不改变转发三元组）。 |
| **删除 / 清空** | 单条删除或一键清空全部转发及相关防火墙放行（在有能力区分共享目标时尽量不误删）。 |
| **流量限额与阻断** | 按 **目标返回客户端的回程流量（egress 计数）** 统计用量；超额后阻断该规则；周期默认 **30 天**，到期自动滚动重置。 |
| **重置流量 / 恢复转发** | 交互式清零某条规则的用量状态并恢复转发。 |
| **诊断 / 自检** | 检查 IPv4 转发、`nftables` 服务、规则表加载、防火墙（firewalld / UFW / iptables）、配置持久化、流量定时任务等；可选 **TCP 连通性探测**。 |
| **内核与网络调优** | 安装流程中会尝试开启 **IPv4 转发** 并持久化到 `sysctl`；若内核支持则尝试启用 **BBR + fq**（失败则跳过并告警）。 |
| **防火墙联动** | 添加规则时：若 **firewalld** 运行则 `firewall-cmd` 放行；否则 **UFW** 活跃则 `ufw allow` / `ufw route allow`；否则尝试 **iptables** `INPUT`/`FORWARD` 规则（并尝试持久化）。 |

## 转发原理（简要）

脚本生成的 nftables 表名默认为 `port_forward`，主要包括：

- **PREROUTING**：对本机端口的 TCP/UDP 做 **DNAT**，并用 **ct mark**（值为监听端口）标记连接。
- **FORWARD**：放行转发路径；在回程路径上对匹配规则的包挂 **counter**，用于 **月流量统计**；限额用尽时在 PREROUTING/FORWARD 侧 **drop** 阻断。
- **POSTROUTING**：对已 DNAT 的流量做 **SNAT**，源地址取「到目标网段的路由」所决定的出站地址。

目标可以填写 **IPv4** 或 **域名**，但域名不会直接写进 nftables。脚本会在规则元数据中同时保存 `target_host` 与当前 `resolved_ip`，生成 nftables 规则时只使用 `resolved_ip`。`--traffic-check` 由 systemd timer 每 **2 分钟** 运行一次，会刷新域名解析；若 DNS 解析失败，则继续保留上一次成功解析到的 IPv4。

**说明**：额度统计的是 **单向回程字节量**（脚本内说明亦强调），**不是**带宽速率限制。

## 环境要求

- **root** 权限（脚本会校验）。
- **Bash**。
- 面向使用 **systemd** 的常见发行版（用于 `nftables` 服务与流量检查定时器）；无 systemctl 时部分自动化能力会降级。
- 可选：终端安装 **[gum](https://github.com/charmbracelet/gum)** 以获得更好的菜单与表格体验；缺失时使用纯文本交互。

## 用法

```bash
sudo bash nft.sh
```

无参数启动时会尝试确保 gum 可用（可按环境变量配置下载镜像）、初始化配置目录，并尽量安装/启用 **流量检查 systemd timer**。

### 主菜单项

1. **安装 nftables** — 安装或重装接管流程（已有 nft 时会警告并备份 `.bak.<时间戳>`）。
2. **查看/编辑现有端口转发** — 列表、用量、状态，并可编辑额度与备注。
3. **新增端口转发** — 本机端口 → 目标 IPv4/域名:端口；域名规则会显示当前解析 IPv4；冲突检测（`ss`）；选择月上限（不限制 / 50G～800G）。
4. **删除端口转发**。
5. **一键清空所有转发**。
6. **重置流量/恢复转发** — 针对超额被阻断的规则。
7. **诊断/自检**。
8. **退出**。

## 重要路径与文件（默认值）

可通过环境变量覆盖（见下一节），默认值一般为：

| 用途 | 默认路径 |
|------|-----------|
| 片段配置目录 | `/etc/nftables.d` |
| 生成的 nft 转发规则 | `/etc/nftables.d/port-forward.conf` |
| 规则元数据（含备注、限额等） | `/etc/nftables.d/port-forward.rules` |
| 配置备份目录 | `/etc/nftables.d/backups` |
| nftables 主配置 | `/etc/nftables.conf` |
| sysctl 片段（转发、BBR 等） | `/etc/sysctl.d/99-nft-forward.conf` |
| 操作日志 | `/var/log/nft-forward.log` |
| logrotate 配置 | `/etc/logrotate.d/nft-forward` |
| 流量状态目录 | `/var/lib/nft-forward` |
| 流量状态文件 | `/var/lib/nft-forward/traffic-state` |
| 脚本安装目标路径 | `/usr/local/sbin/nft.sh` |
| 流量检查单元 | `/etc/systemd/system/nft-forward-traffic-check.{service,timer}` |

主配置中需包含一行：`include "/etc/nftables.d/*.conf"`（具体字符串由变量 `CONF_INCLUDE_LINE` 派生），以便开机加载转发片段。

**定时任务**：`nft-forward-traffic-check.timer` 默认约 **每 2 分钟** 触发一次 `nft.sh --traffic-check`，用于更新用量、刷新域名解析，并在超限或域名当前解析 IPv4 发生变化时重写规则。

## 环境变量（常用）

所有变量均为可选；未设置时使用脚本内默认值。

| 变量 | 含义 |
|------|------|
| `NFT_FORWARD_CONF_DIR` | 配置目录 |
| `NFT_FORWARD_CONF_FILE` | 生成的 nft 转发文件路径 |
| `NFT_FORWARD_RULES_FILE` | 规则元数据路径 |
| `NFT_FORWARD_BACKUP_DIR` | 备份目录 |
| `NFT_FORWARD_MAIN_CONF` | nftables 主配置 |
| `NFT_FORWARD_SYSCTL_CONF` | sysctl drop-in 路径 |
| `NFT_FORWARD_LOG_FILE` / `NFT_FORWARD_LOGROTATE_CONF` | 日志与轮转配置 |
| `NFT_FORWARD_STATE_DIR` / `NFT_FORWARD_STATE_FILE` | 流量状态 |
| `NFT_FORWARD_SYSTEMD_DIR` | systemd 单元目录 |
| `NFT_FORWARD_SCRIPT_PATH` | 安装副本路径（timer 里 `ExecStart` 指向这里） |
| `NFT_FORWARD_TABLE_NAME` | nft 表名（默认 `port_forward`） |
| `NFT_FORWARD_QUOTA_PERIOD_SECONDS` | 限额统计周期秒数（默认 2592000 ≈ 30 天） |
| `NFT_FORWARD_GB_BYTES` | 「1GB」字节数（默认 10⁹） |
| `NFT_FORWARD_QUOTA_RESET_TZ` | 展示周期重置日与时区相关（默认 `Asia/Shanghai`） |
| `NFT_FORWARD_APP_TITLE` / `NFT_FORWARD_APP_VERSION` | 界面标题与版本文案 |
| `NFT_FORWARD_GUM_BIN` / `GUM_*` 系列 | gum 二进制名、超时、DEB 下载 URL、是否启用 Charm 仓库回退等 |
| `NFT_FORWARD_TABLE_HEADER_FG` | gum 表格表头前景色 |
| `NFT_FORWARD_TEST_MODE` | 非空时安装 timer 可能跳过 `systemctl enable`（用于测试） |

## 注意事项与风险

1. **已有 nftables 规则**：选择「安装 nftables」会 **flush 规则集** 并用脚本的 `include` 链路接管；请务必先 **备份**。
2. **本机端口占用**：添加转发前会用 `ss` 提示该端口是否已被其他进程监听；转发生效后，外部访问通常走 DNAT，可能影响「本机同一端口上的其它对外服务」的预期。
3. **UFW / 复杂防火墙**：脚本会尽力放行，但极端自定义规则仍可能需要手工调整。
4. **限额粒度**：依赖定时器周期与计数器更新，非实时毫秒级精度。
5. **双栈**：当前脚本生成的规则针对 **IPv4**（`table ip`）。
6. **域名 NAT 首版边界**：当前仅支持 **IPv4 A 记录** 与 `table ip`；**不支持 IPv6、端口范围、redirect、drop 目标**。若 DNS 解析失败，会继续保留上一次成功解析到的 IPv4。
