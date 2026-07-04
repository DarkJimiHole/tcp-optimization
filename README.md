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
TCP 队列： fq / fq_codel / cake / pfifo_fast / 未知
适用延迟： 80 ms
带宽大小： 100 Mbps

-----------------------------------------------
  1. 开启调优
  2. 关闭调优
  3. 开启 BBR
  4. 关闭 BBR
  5. 修改延迟和带宽
  6. 卸载脚本
  0. 退出
-----------------------------------------------

请输入选项 [0-6]:
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

脚本会把 TCP 收发缓冲上限设置为 `BDP × 4`，并限制在 `64 MiB` 到 `512 MiB` 之间。这个值是自动调节的上限，不代表每条连接都会立即占用这么多内存。

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
```

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
6. 卸载脚本
```

或运行：

```bash
tcp-tuning uninstall
```

卸载时会删除脚本管理的文件，并尝试恢复开启调优前备份的 sysctl 值。
