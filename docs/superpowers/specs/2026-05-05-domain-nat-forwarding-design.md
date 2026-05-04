# nft.sh 域名 NAT 转发设计

## 背景

`nft.sh` 是一个单文件 Bash 工具，用于在 Linux 服务器上交互式管理 nftables DNAT 端口转发规则。当前脚本只支持把本机端口转发到固定 IPv4 地址和目标端口，不支持把目标写成域名。

本次需求是参考 `nftables-nat-rust` 的 NAT 转发能力，把“目标域名解析后生成 nftables NAT 规则”的能力集成进当前脚本，但不引入它的 WebUI，也不改变当前脚本的交互风格。

## 已确认需求

- 第一版只做单端口域名 NAT 转发。
- 只支持 IPv4。
- 协议仍固定为 `tcp+udp`，不新增协议选择。
- 继续支持现有 IP + 端口转发。
- 继续支持备注、月流量限制、查看、删除、清空和重置流量。
- 域名解析刷新周期默认改为 2 分钟。
- 域名解析刷新复用现有 `--traffic-check` systemd timer，不新增守护进程。
- 不需要 `nftables-nat-rust` 的 WebUI。
- 不把 `nftables-nat-rust` 作为外部服务或编译产物引入。

这些边界体现 YAGNI，直接收益是第一版只交付当前明确需要的能力，避免把脚本扩成完整 NAT 平台。

## 本次范围

本次实现包含：

- 扩展规则元数据，让每条规则能保存用户输入的目标主机名和当前解析 IPv4。
- 新增域名/IPv4 输入校验。
- 新增 IPv4 解析逻辑。
- 新增规则时允许填写 IPv4 或域名。
- 生成 nftables 配置时使用当前解析 IPv4。
- `--traffic-check` 同步流量状态后刷新域名解析。
- 解析 IP 变化时重写规则元数据、重写 nftables 配置并 reload。
- timer 默认周期从约 5 分钟调整为 2 分钟。
- 查看、删除、清空、重置流量兼容域名规则。
- 旧版规则元数据自动迁移到新格式。
- README 更新域名 NAT、2 分钟刷新周期和限制说明。

本次不做：

- 不做端口段转发。
- 不做 IPv6。
- 不做 `redirect`。
- 不做 `drop` 黑名单过滤。
- 不做 WebUI。
- 不做每条规则独立 DNS 刷新周期。
- 不做外部数据库或常驻 daemon。
- 不做目标域名、端口、协议的就地编辑；如需修改目标，仍然删除后新增。

该范围符合 KISS：只沿现有单端口转发模型扩展目标类型，直接收益是实现路径短、验证面集中、回滚风险低。

## 推荐方案

采用“脚本内扩展规则模型 + 定时解析刷新”的方案。

规则配置仍由 `nft.sh` 自己维护，nftables 配置仍由 `write_conf_file` 生成，周期触发仍由现有 `nft-forward-traffic-check.timer` 执行。域名解析结果变化时，脚本更新规则元数据中的 `resolved_ip`，然后复用现有 reload 流程更新 nftables。

不采用直接调用 `nftables-nat-rust` CLI 的方案，因为那会引入第二套配置文件、第二套 systemd 服务、第二套 nftables 表和 reload 逻辑，并且无法自然复用当前脚本的流量限制状态。

不采用移植 Rust 项目二进制/模块的方案，因为当前仓库是单脚本工具，第一版为域名 NAT 引入编译、安装、版本和依赖管理会超出当前需求。

该方案符合 DRY 和 SOLID 的单一职责：交互仍由菜单负责，规则配置仍由元数据文件负责，nftables 生成仍由一个函数负责，周期任务仍由一个 CLI 入口负责。直接收益是没有平行实现，维护成本最低。

## 规则元数据模型

新格式：

```text
rule_id|local_port|target_host|resolved_ip|dest_port|quota_gb|remark
```

字段语义：

- `rule_id`：规则稳定 ID，不再依赖目标 IP 或域名。
- `local_port`：本机监听端口。
- `target_host`：用户输入的目标，可以是 IPv4 或域名。
- `resolved_ip`：当前用于生成 nftables 规则的 IPv4。
- `dest_port`：目标端口。
- `quota_gb`：月流量上限，`0` 表示不限制。
- `remark`：备注。

旧格式：

```text
rule_id|local_port|dest_ip|dest_port|quota_gb|remark
```

读取旧格式时自动迁移为：

```text
rule_id|local_port|dest_ip|dest_ip|dest_port|quota_gb|remark
```

旧格式里的原 `rule_id` 保留，`dest_ip` 同时作为 `target_host` 和 `resolved_ip`。保留旧 `rule_id` 可以延续现有流量状态；新建域名规则再使用目标地址无关的新 ID 格式。

`rule_id` 使用不依赖目标地址的稳定格式，例如：

```text
pf_<epoch>_<local_port>_<dest_port>
```

这样域名解析 IP 变化时不改变 `rule_id`，流量状态文件中的 counter 状态可以延续。这个设计符合 OCP：扩展目标类型时不破坏流量统计契约，直接收益是域名变更不会造成状态丢失。

## 域名解析策略

新增解析函数，输入 `target_host`，输出 IPv4：

1. 如果 `target_host` 是合法 IPv4，直接返回原值。
2. 如果是域名，解析 A 记录或解析结果里的 IPv4。
3. 优先使用系统基础工具，建议顺序为：
   - `getent ahostsv4 <domain>`
   - `dig +short A <domain>`，如果系统存在 `dig`
   - `host <domain>`，如果系统存在 `host`
4. 只接受合法 IPv4，拒绝 IPv6 和空结果。

新增规则时，域名必须解析成功才能保存。这样符合稳定性要求，直接收益是不会把无法生效的规则写入配置。

周期刷新时，如果域名解析失败：

- 保留上一次成功解析的 `resolved_ip`。
- 不 reload 规则。
- 写日志或告警信息。
- 下一次 timer 继续尝试解析。

该策略符合 KISS 和稳定性优先：DNS 短暂失败不会中断已有转发，直接收益是线上转发不会因为一次解析失败被清空。

## 定时刷新流程

现有非交互命令：

```bash
nft.sh --traffic-check
```

继续作为唯一周期入口。timer 默认改为 2 分钟执行一次。

每次执行流程：

1. 读取规则元数据。
2. 读取流量状态。
3. 同步 nftables counter 到流量状态。
4. 判断月流量是否超额。
5. 对每条域名规则解析当前 IPv4。
6. 如果解析失败，保留旧 `resolved_ip` 并继续处理其它规则。
7. 如果解析结果变化，更新规则元数据中的 `resolved_ip`。
8. 如果阻断状态、周期状态或解析 IP 发生变化，重写 nftables 配置并 reload。
9. reload 成功后同步 counter baseline，避免 nft counter 重建导致误计流量。

域名解析刷新和流量限制共用一个 timer，符合 DRY。直接收益是系统中只有一个周期任务，安装、诊断和故障排查都更简单。

## nftables 规则生成

`write_conf_file` 继续生成现有 `table ip ${TABLE_NAME}`。

域名规则和 IP 规则在生成阶段统一使用 `resolved_ip`：

- PREROUTING：`fib daddr type local tcp/udp dport <local_port> dnat to <resolved_ip>:<dest_port>`
- FORWARD 请求方向：匹配 `ip daddr <resolved_ip>` 和 `dport <dest_port>`
- FORWARD 回程统计：匹配 `ip saddr <resolved_ip>` 和 `sport <dest_port>`，挂命名 counter
- POSTROUTING：使用 `get_snat_ip_for_dest "$resolved_ip"` 获取 SNAT 源地址

展示注释里保留用户输入目标：

```nft
# 转发: 本机:10443 -> example.com(93.184.216.34):443
```

已阻断规则也使用当前 `resolved_ip` 生成请求和回程 drop 规则。这样符合 SRP：规则生成只关心“当前 nftables 应该使用哪个 IP”，域名解析由刷新逻辑负责。直接收益是 IP 规则和域名规则共用同一条规则生成路径。

## 菜单交互

主菜单保持不变。

`新增端口转发` 中把目标输入提示改为：

```text
请输入目标 IP 或域名:
```

输入 IPv4 时，行为与现在一致。

输入域名时：

1. 校验域名格式。
2. 解析当前 IPv4。
3. 如果解析失败，提示错误并要求重新输入。
4. 确认页展示域名和当前解析 IP。

确认页示例：

```text
即将添加转发规则:
 - 本机端口 10443 (tcp+udp) -> example.com:443
 - 当前解析 IP: 93.184.216.34
 - 月流量上限: 200G
 - 备注: example https
```

查看列表中，目标地址展示为：

- IP 规则：`192.0.2.10:443`
- 域名规则：`example.com(93.184.216.34):443`

编辑仍只允许修改月流量上限和备注。目标主机、端口、协议不做就地编辑。这个设计符合 KISS，直接收益是交互仍沿用当前脚本，不增加复杂编辑路径。

## 防火墙联动

第一版采用保守策略：

- 新增规则时，对当前 `resolved_ip` 调用现有 `firewall_open_port`。
- 删除规则时，对当前 `resolved_ip` 调用现有 `firewall_close_port`。
- 域名解析 IP 变化时，对新 `resolved_ip` 调用 `firewall_open_port`，尽量确保新目标可转发。
- 域名解析 IP 变化时不主动删除旧 IP 的 FORWARD 放行规则。

不自动删除旧 IP 放行规则的原因是，脚本目前只能按目标 IP 和端口判断共享情况，域名变化场景下旧 IP 可能仍被其它规则、外部规则或管理员手工规则使用。第一版优先保证新 IP 可用，避免误删共享规则。

该策略符合 YAGNI 和稳定性优先，直接收益是新规则可用性高，且不会为了清理旧规则引入误删风险。旧 IP 放行规则可在后续单独设计“域名解析历史 IP 状态”后再安全清理。

## 安装与 timer

`install_traffic_timer` 生成的 timer 周期改为 2 分钟。

如果机器上已经安装过旧 timer，`timer_unit_needs_install` 必须能检测 timer 内容变化，并触发重新安装。

安装后流程：

```bash
systemctl daemon-reload
systemctl enable --now nft-forward-traffic-check.timer
```

诊断页中流量限制检查继续检测 service/timer 是否存在、是否 enabled、是否 active。

README 中把“约每 5 分钟”改为“约每 2 分钟”。

该设计符合 DRY：仍然只有一个周期任务。直接收益是域名 IP 漂移后的最大响应窗口从约 5 分钟降到约 2 分钟，同时不会新增 systemd 单元。

## 兼容迁移

兼容目标：

- 已有旧 `port-forward.rules` 可以读取。
- 已有旧 `port-forward.conf` 迁移逻辑仍可工作。
- 旧规则的流量状态尽量保留。

迁移策略：

1. `parse_rule_metadata_line` 同时接受旧格式和新格式。
2. 旧格式读取后转换为内存新格式。
3. 下一次写入 `RULES_FILE` 时写成新格式。
4. 旧 `rule_id` 如果符合当前状态文件引用，可以保留；新建域名规则使用新 `rule_id` 格式。
5. 如果旧 `rule_id` 依赖 IP，IP 规则无需重写 ID；域名规则不会使用旧 ID 格式。

这样符合 OCP：新格式扩展旧格式，而不是让旧配置失效。直接收益是升级后不需要管理员手工迁移现有规则。

## 错误处理

新增规则时：

- 目标既不是合法 IPv4，也不是合法域名：拒绝输入。
- 域名解析不到 IPv4：拒绝保存。
- `resolved_ip` 无法推导 SNAT 源地址：拒绝写入 nftables 配置。

周期刷新时：

- 单条域名解析失败：保留旧 IP，记录告警，继续其它规则。
- 某条规则解析到新 IP 但 reload 失败：回滚规则元数据和配置文件到 reload 前状态。
- counter 读取失败：沿用现有修复逻辑，必要时重写 nftables 配置。

该设计符合稳定性目标：交互入口快速失败，周期入口保守不中断。直接收益是管理员新增时能及时发现错误，运行时不会因短暂 DNS 或 reload 异常破坏现有转发。

## 验证计划

实现后至少执行：

```bash
bash -n nft.sh
```

使用临时目录环境变量做离线验证：

- `NFT_FORWARD_CONF_DIR`
- `NFT_FORWARD_RULES_FILE`
- `NFT_FORWARD_CONF_FILE`
- `NFT_FORWARD_STATE_DIR`
- `NFT_FORWARD_STATE_FILE`

重点测试点：

- 旧格式规则可以加载并写回新格式。
- IPv4 规则行为与现有版本一致。
- 域名规则新增时保存 `target_host` 和 `resolved_ip`。
- 域名规则生成的 nftables 配置使用 `resolved_ip`。
- 模拟域名解析 IP 变化时，`RULES_FILE` 和 `CONF_FILE` 更新，`rule_id` 不变。
- 模拟域名解析失败时，保留旧 `resolved_ip`，不清空规则。
- 月流量限制仍能统计域名规则回程流量。
- 超额阻断规则使用当前 `resolved_ip`。
- 删除域名规则能移除对应元数据和流量状态。
- timer 文件内容包含 2 分钟周期，旧 timer 内容变化能被检测并重装。

验证计划符合 SOLID/SRP：每个测试点对应一个明确行为边界。直接收益是能区分域名解析、规则生成、流量统计和 systemd timer 的回归风险。

## 原则落地

- KISS：第一版只做单端口 IPv4 域名 NAT，复用现有菜单、配置文件、timer 和 nftables 生成流程。收益是改动面小，容易验证。
- YAGNI：不做 WebUI、端口段、IPv6、redirect、drop、自定义刷新周期和 Rust 服务集成。收益是避免当前需求之外的复杂度。
- DRY：域名规则和 IP 规则共用同一套规则生成、reload、流量统计、删除和清空逻辑。收益是减少平行实现。
- SRP：域名解析、元数据读写、nftables 配置生成、流量状态同步、交互输入各自有清晰职责。收益是后续排查和测试更直接。
- OCP：通过扩展元数据字段支持域名，不破坏现有 IP 转发契约。收益是旧规则可兼容升级。

## 下一步

设计确认后，进入实现计划阶段。实现计划应按以下顺序拆分：

1. 扩展元数据解析和格式化，完成旧格式兼容。
2. 新增目标主机校验和 IPv4 解析函数。
3. 扩展新增规则交互和列表展示。
4. 改造 nftables 配置生成使用 `resolved_ip`。
5. 在 `--traffic-check` 中加入域名刷新和 2 分钟 timer。
6. 更新诊断、README 和回归测试/离线验证脚本。
