# TCP Optimization

一个面向 VPS 的 TCP 网络调优管理脚本，提供 BBR、队列规则、TCP 收发窗口和 sysctl 配置的一键管理菜单。

脚本不会覆盖 `/etc/sysctl.conf`，只管理自己的配置文件：

- `/etc/sysctl.d/99-tcp-tuning.conf`
- `/usr/local/etc/tcp-tuning/config`
- `/etc/systemd/system/tcp-tuning.service`
- `/usr/local/bin/tcp-tuning`

## 快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DarkJimiHole/tcp-optimization/main/install.sh)
```

安装完成后运行：

```bash
tcp-tuning
```

如果系统不支持 process substitution，可以使用：

```bash
curl -fsSL https://raw.githubusercontent.com/DarkJimiHole/tcp-optimization/main/install.sh -o install.sh
bash install.sh install
tcp-tuning
```

## 主菜单

```text
        TCP 网络调优 管理脚本
===============================================

服务状态： 运行中 / 未运行 / 未安装
BBR 状态： 已开启 / 未开启
TCP 队列： fq / fq（HTB 出口整形） / fq_codel / cake / pfifo_fast / 未知
适用延迟： 80 ms
带宽大小： 100 Mbps
出口整形： 未开启 / 90 Mbps

-----------------------------------------------
  1. 开启调优
  2. 关闭调优
  3. 开启 BBR
  4. 关闭 BBR
  5. 修改延迟和带宽
  6. 设置出口整形（HTB）
  7. 卸载脚本
  0. 退出
-----------------------------------------------

请输入选项 [0-7]:
```

首次使用请先执行：

```text
5. 修改延迟和带宽
```

然后再执行：

```text
1. 开启调优
```

脚本会阻止在未设置延迟和带宽时直接开启调优。

## 参数怎么填

延迟填写 TCP 两端之间的实际 RTT，单位 `ms`。

带宽填写这条 TCP 路径上的实际瓶颈带宽，单位 `Mbps`。例如本地下载带宽 `500 Mbps`，VPS 端口 `1 Gbps`，则瓶颈通常按 `500 Mbps` 填。

窗口需求按 BDP 计算：

```text
BDP(bytes) = 带宽(Mbps) × RTT(ms) × 125
```

例如：

```text
500 Mbps × 149 ms × 125 ≈ 9.3 MB
```

脚本会把 TCP 收发缓冲上限设置为 `BDP × 3`，最小 `16 MiB`，最大取 `512 MiB` 与 `内存 / 8` 中的较小值。这个值是自动调节的上限，不代表每条连接都会立即占用这么多内存；按内存封顶是为了避免小内存 VPS 在慢客户端较多时触发 TCP 内存压力。

取 3 倍的原因：BBR 在途数据最多约 2 × BDP，而接收缓冲只有约 50%-75% 能作为通告窗口（其余是 skb 元数据开销）。

## 转发链路说明

如果链路是：

```text
本地客户端 -> VPS1 nftables 转发 -> VPS2 内核转发 -> VPS3 VLESS 服务
```

并且 VPS1、VPS2 只是内核转发，不终止 TCP，那么延迟应按：

```text
本地客户端 到 VPS3 的完整路径 RTT
```

TCP 窗口主要调本地客户端和 VPS3。VPS1、VPS2 更关注转发、NAT、conntrack、MTU/MSS 和队列性能。

## 脚本做了什么

开启调优时会写入：

```conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.rmem_max = <calculated>
net.core.wmem_max = <calculated>
net.ipv4.tcp_rmem = 4096 131072 <calculated>
net.ipv4.tcp_wmem = 4096 65536 <calculated>
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.netdev_max_backlog = 16384
```

- `tcp_notsent_lowat`：限制 socket 中未发送数据量，降低大发送缓冲下的内存占用和代理延迟抖动，也让 iperf3 发送端首秒速率不再虚高。
- `tcp_slow_start_after_idle = 0`：长连接（代理、mux、HTTP/2）空闲后不再重新慢启动。
- `tcp_mtu_probing = 1`：多层转发或隧道遇到 PMTU 黑洞时自动探测 MSS。
- `netdev_max_backlog`：避免高 pps 时在软中断层丢包。

队列：多队列网卡保留 `mq` 作为根，每个发送队列挂一个 `fq`，不会把所有队列合并成单个 `fq`。

## 出口整形（可选）

菜单 `6. 设置出口整形（HTB）` 用 HTB 把本机出口总速率压到设定值，叶子队列仍是 `fq`，BBR 继续使用 fq pacing。排队发生在本机，而不是在上游限速器（policer）处被直接丢包。

实测（300M 端口、RTT 156ms、BBR）：不整形 249 Mbps / 重传约 3%；HTB 270M 251 Mbps / 重传约 0.3%。同一台 1 vCPU VPS 上 cake 270M 只有约 110 Mbps，因此不使用 cake。

- 只在 BBR 稳定阶段重传仍然偏高、或实际使用卡顿时开启；只有启动阶段重传高属于 BBR 正常探测，不必处理。
- 适合 VPS 端口有限速器的情况：用 `iperf3 -R --fq-rate` 逐档测试，重传在某个速率以上突然升高，即为限速点。
- 通常取端口带宽的 90% 左右，留空回车会按 90% 给出建议值；输入 `0` 关闭。
- 整形只降低重传、不会提升速率；开启后请与不整形时对比，确认有收益再保留。
- 只作用于出口方向（VPS -> 客户端），开启调优后才生效。整形时根队列为单个 HTB，不再使用多队列 `mq`。

脚本不会无脑开启：

- `ip_forward`
- `rp_filter=0`
- `route_localnet=1`
- `tcp_abort_on_overflow=1`
- `tcp_tw_reuse=1`
- `tcp_adv_win_scale`

这些参数和普通 TCP 吞吐调优不是一回事，应根据具体转发、代理或路由场景单独配置。

## 常用命令

```bash
tcp-tuning              # 打开菜单
tcp-tuning install      # 安装管理命令
tcp-tuning config       # 修改延迟和带宽
tcp-tuning shape        # 设置出口整形（HTB）
tcp-tuning enable       # 开启调优
tcp-tuning disable      # 关闭调优
tcp-tuning bbr-on       # 开启 BBR
tcp-tuning bbr-off      # 关闭 BBR
tcp-tuning uninstall    # 卸载脚本
```

## 检查状态

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.ipv4.tcp_available_congestion_control
sysctl net.core.default_qdisc
lsmod | grep bbr
tc qdisc show
```

`tcp_bbr` 模块仍然加载不代表 BBR 正在使用。真正判断默认拥塞控制请看：

```bash
sysctl net.ipv4.tcp_congestion_control
```

## 卸载

在菜单中执行：

```text
7. 卸载脚本
```

或运行：

```bash
tcp-tuning uninstall
```

卸载时会删除脚本管理的文件，并尝试恢复开启调优前备份的 sysctl 值。
