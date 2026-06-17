---
title: "Istio iptables 规则对比：Sidecar 模式 vs Ambient 模式"
date: 2026-06-17T10:00:00+08:00
draft: false
tags: [Istio, Ambient Mesh, Service Mesh, iptables]
categories: [Istio]
---

> 把 Sidecar 与 Ambient (INPOD) 两种模式的 iptables 规则摊开，看清楚一个 UID 1337、一个 mark 0x539，背后差异到底在哪。

## 架构差异

| 对比项 | Sidecar 模式 | Ambient (INPOD) 模式 |
|--------|-------------|---------------------|
| 代理位置 | pod 内 envoy sidecar 容器 | 节点级 ztunnel，通过 veth 进入 pod netns |
| 规则写入时机 | pod 创建时由 `istio-init` init container 写入 | pod 运行时由 CNI node agent 动态写入 |
| 规则写入者 | `istio-iptables` 二进制 | CNI node agent (`install-cni`) |
| 防循环机制 | UID/GID 匹配 (`-m owner --uid-owner 1337`) | packet mark `0x539` + connmark `0x111` |
| 代理标识 IP | `127.0.0.6` (inbound passthrough) | `169.254.7.127` (ztunnel link-local) |
| 健康检查处理 | 重写 podSpec，探针指向 envoy 15021 | 宿主机 SNAT `169.254.7.127` + pod 内 ACCEPT |

## 端口对比

| 用途 | Sidecar | Ambient |
|------|---------|---------|
| Outbound 代理 | 15001 | 15001 |
| Inbound 代理 | 15006 | 15006 (plaintext) / 15008 (HBONE) |
| DNS 捕获 | 15053 | 15053 |
| Inbound tunnel | 15008 | 15008 |
| 状态端口 | 15020 | 15020 |

## Sidecar 模式 iptables 规则

规则由 `tools/istio-iptables/pkg/capture/run.go` 中的 `Run()` 方法生成。

### nat 表

```
*nat

# 自定义链
-N ISTIO_INBOUND
-N ISTIO_IN_REDIRECT
-N ISTIO_OUTPUT
-N ISTIO_REDIRECT

# ---- Inbound ----

# 跳转到 ISTIO_INBOUND
-A PREROUTING -p tcp -j ISTIO_INBOUND

# 15008 (HBONE tunnel) 直接放行，不经过 inbound 重定向
-A ISTIO_INBOUND -p tcp --dport 15008 -j RETURN

# 所有 inbound TCP → REDIRECT 到 envoy 15006
-A ISTIO_IN_REDIRECT -p tcp -j REDIRECT --to-ports 15006

# includeInboundPorts=* 时，排除特定端口后全部重定向
-A ISTIO_INBOUND -p tcp --dport 15090 -j RETURN       # prometheus
-A ISTIO_INBOUND -p tcp --dport 15021 -j RETURN       # health check
-A ISTIO_INBOUND -p tcp --dport 15020 -j RETURN       # status
-A ISTIO_INBOUND -p tcp -j ISTIO_IN_REDIRECT           # 其余全部重定向

# ---- Outbound ----

# 所有 outbound TCP → REDIRECT 到 envoy 15001
-A ISTIO_REDIRECT -p tcp -j REDIRECT --to-ports 15001

# OUTPUT 链跳转
-A OUTPUT -j ISTIO_OUTPUT

# 排除指定出站端口
# -A ISTIO_OUTPUT -p tcp --dport <excluded_port> -j RETURN

# 127.0.0.6 (envoy inbound passthrough 回程) → 放行
-A ISTIO_OUTPUT -o lo -s 127.0.0.6/32 -j RETURN

# ★ 防循环核心：envoy 自身 (UID 1337) 发出的流量经 lo 回到 app → 重定向到 inbound
-A ISTIO_OUTPUT -o lo ! -d 127.0.0.1/32 -p tcp ! --dport 15008 \
    -m owner --uid-owner 1337 -j ISTIO_IN_REDIRECT

# 非 envoy 进程经 lo 发出 → 放行 (app 到 app 本地通信)
-A ISTIO_OUTPUT -o lo -m owner ! --uid-owner 1337 -j RETURN

# ★ 防循环核心：envoy 自身 (UID 1337) 的非 lo 流量 → 放行 (envoy → 外部)
-A ISTIO_OUTPUT -m owner --uid-owner 1337 -j RETURN

# GID 1337 同理（同样的规则对 GID）
-A ISTIO_OUTPUT -o lo ! -d 127.0.0.1/32 -p tcp ! --dport 15008 \
    -m owner --gid-owner 1337 -j ISTIO_IN_REDIRECT
-A ISTIO_OUTPUT -o lo -m owner ! --gid-owner 1337 -j RETURN
-A ISTIO_OUTPUT -m owner --gid-owner 1337 -j RETURN

# localhost 目标 → 放行
-A ISTIO_OUTPUT -d 127.0.0.1/32 -j RETURN

# 其余所有 outbound → REDIRECT 到 envoy 15001
-A ISTIO_OUTPUT -j ISTIO_REDIRECT

COMMIT
```

### mangle 表（仅 TPROXY 模式）

TPROXY 模式下使用 mangle 表替代 nat 表做 inbound 重定向：

```
*mangle
-N ISTIO_DIVERT
-N ISTIO_INBOUND
-N ISTIO_TPROXY

-A PREROUTING -p tcp -j ISTIO_INBOUND

# DIVERT: 已有连接的包标记后 ACCEPT
-A ISTIO_DIVERT -j MARK --set-mark 1337
-A ISTIO_DIVERT -j ACCEPT

# TPROXY: 新连接的包 → TPROXY 到 envoy 15006
-A ISTIO_TPROXY ! -d 127.0.0.1/32 -p tcp -j TPROXY \
    --tproxy-mark 1337/0xffffffff --on-port 15006

# 已建立连接 → DIVERT
-A ISTIO_INBOUND -p tcp -m conntrack --ctstate RELATED,ESTABLISHED -j ISTIO_DIVERT
# 新连接 → TPROXY
-A ISTIO_INBOUND -p tcp -j ISTIO_TPROXY

# OUTPUT 链：envoy 标记传播
-A PREROUTING -p tcp -m mark --mark 1337 -j CONNMARK --save-mark
-A OUTPUT -p tcp -o lo -m mark --mark 1337 -j RETURN
-A OUTPUT ! -d 127.0.0.1/32 -p tcp -o lo -m owner --uid-owner 1337 \
    -j MARK --set-mark 1338
-A OUTPUT -p tcp -m connmark --mark 1337 -j CONNMARK --restore-mark
COMMIT
```

## Ambient (INPOD) 模式 iptables 规则

规则由 `cni/pkg/iptables/iptables.go` 中的 `AppendInpodRules()` 方法生成。

对应 golden test: `cni/pkg/iptables/testdata/default.golden`

### mangle 表

```
*mangle
-N ISTIO_PRERT
-N ISTIO_OUTPUT

-A PREROUTING -j ISTIO_PRERT
-A OUTPUT -j ISTIO_OUTPUT

# ★ inbound: ztunnel 发出的包 (mark 0x539) → 设置 connmark 0x111
-A ISTIO_PRERT -m mark --mark 0x539/0xfff -j CONNMARK --set-xmark 0x111/0xfff

# ★ outbound: 连接有 connmark 0x111 → 恢复到包 mark (回程包跳过重定向)
-A ISTIO_OUTPUT -m connmark --mark 0x111/0xfff -j CONNMARK --restore-mark \
    --nfmask 0xffffffff --ctmask 0xffffffff

COMMIT
```

### nat 表

```
*nat
-N ISTIO_PRERT
-N ISTIO_OUTPUT

-A OUTPUT -j ISTIO_OUTPUT
-A PREROUTING -j ISTIO_PRERT

# 来自 ztunnel (169.254.7.127) 的 inbound 流量 → 放行
-A ISTIO_PRERT -s 169.254.7.127 -p tcp -m tcp -j ACCEPT

# 发往 ztunnel (169.254.7.127) 的 outbound 流量 → 放行
-A ISTIO_OUTPUT -d 169.254.7.127 -p tcp -m tcp -j ACCEPT

# ★ INBOUND 核心: 非 localhost、非 15008、无 mark 0x539 → REDIRECT 到 ztunnel 15006
-A ISTIO_PRERT ! -d 127.0.0.1/32 -p tcp ! --dport 15008 \
    -m mark ! --mark 0x539/0xfff -j REDIRECT --to-ports 15006

# DNS 捕获 (AMBIENT_DNS_CAPTURE=true 时)
-A ISTIO_OUTPUT ! -o lo -p udp -m mark ! --mark 0x539/0xfff \
    -m udp --dport 53 -j REDIRECT --to-port 15053
-A ISTIO_OUTPUT ! -d 127.0.0.1/32 -p tcp --dport 53 \
    -m mark ! --mark 0x539/0xfff -j REDIRECT --to-ports 15053

# 已代理流量 (connmark 0x111) → 放行
-A ISTIO_OUTPUT -p tcp -m mark --mark 0x111/0xfff -j ACCEPT

# app 经 lo 访问自身 endpoint IP → 放行
-A ISTIO_OUTPUT ! -d 127.0.0.1/32 -o lo -j ACCEPT

# ★ OUTBOUND 核心: 非 localhost、无 mark 0x539 → REDIRECT 到 ztunnel 15001
-A ISTIO_OUTPUT ! -d 127.0.0.1/32 -p tcp \
    -m mark ! --mark 0x539/0xfff -j REDIRECT --to-ports 15001

COMMIT
```

### raw 表（DNS conntrack zone 隔离）

```
*raw
-N ISTIO_OUTPUT
-N ISTIO_PRERT

-A PREROUTING -j ISTIO_PRERT
-A OUTPUT -j ISTIO_OUTPUT

# ztunnel → 上游 DNS: 分配到 conntrack zone 1
-A ISTIO_OUTPUT -p udp -m mark --mark 0x539/0xfff -m udp --dport 53 -j CT --zone 1

# 上游 DNS → ztunnel 回程: 同一 zone
-A ISTIO_PRERT -p udp -m mark ! --mark 0x539/0xfff -m udp --sport 53 -j CT --zone 1

COMMIT
```

### 宿主机规则 (host netns)

对应 golden test: `cni/pkg/iptables/testdata/hostprobe.golden`

```
*nat
-N ISTIO_POSTRT

-I POSTROUTING 1 -j ISTIO_POSTRT

# kubelet 健康检查 → SNAT 源为 169.254.7.127
# --socket-exists 匹配本地 socket 发出的包 (区分 kubelet vs kube-proxy 转发)
-A ISTIO_POSTRT -m owner --socket-exists -p tcp \
    -m set --match-set istio-inpod-probes-v4 dst \
    -j SNAT --to-source 169.254.7.127

COMMIT
```

## 核心机制对比

### 1. 防循环重定向

**Sidecar**: 使用 UID/GID 匹配

```
# envoy (UID 1337) 发出的包 → 跳过重定向
-A ISTIO_OUTPUT -m owner --uid-owner 1337 -j RETURN
```

envoy 以 UID 1337 运行，所有 UID 1337 发出的包直接放行，不会被再次重定向。

**Ambient**: 使用 packet mark + connmark

```
# ztunnel 发出的包带 mark 0x539
# PREROUTING: mark 0x539 → 设置 connmark 0x111
-A ISTIO_PRERT -m mark --mark 0x539/0xfff -j CONNMARK --set-xmark 0x111/0xfff

# 重定向规则排除 mark 0x539
-A ISTIO_OUTPUT ... -m mark ! --mark 0x539/0xfff -j REDIRECT ...

# 回程: connmark 0x111 → 恢复 mark → 跳过重定向
-A ISTIO_OUTPUT -m connmark --mark 0x111/0xfff -j CONNMARK --restore-mark ...
-A ISTIO_OUTPUT -p tcp -m mark --mark 0x111/0xfff -j ACCEPT
```

ztunnel 不在 pod 内运行，无法用 UID 区分，改用 packet mark。

### 2. 健康检查处理

**Sidecar**: 重写 pod spec

```yaml
# istio-agent 在 podSpec 注入时，将原始 probe 端口改写为 envoy 15021
# envoy 转发到实际 app 端口，实现探针透传
readinessProbe:
  httpGet:
    path: /healthz/ready
    port: 15021    # 原本是 app 端口，被重写
```

**Ambient**: 宿主机 SNAT + pod 内 IP 匹配

```
# 宿主机 (host netns): kubelet 探针 → SNAT 为 169.254.7.127
-A ISTIO_POSTRT -m owner --socket-exists -p tcp \
    -m set --match-set istio-inpod-probes-v4 dst \
    -j SNAT --to-source 169.254.7.127

# Pod 内: 源 IP 169.254.7.127 → 直接 ACCEPT，跳过 ztunnel
-A ISTIO_PRERT -s 169.254.7.127 -p tcp -m tcp -j ACCEPT
```

### 3. DNS 捕获

**Sidecar**: 按 DNS 服务器 IP 精确匹配

```
# 仅重定向 resolv.conf 中列出的 DNS 服务器 IP
-A ISTIO_OUTPUT_DNS -p udp --dport 53 -d <dns_server_ip>/32 \
    -j REDIRECT --to-port 15053

# conntrack zone 按 UID/GID 区分方向
-A ISTIO_OUTPUT_DNS -p udp --dport 53 -m owner --uid-owner 1337 -j CT --zone 1
-A ISTIO_OUTPUT_DNS -p udp --sport 15053 -m owner --uid-owner 1337 -j CT --zone 2
```

**Ambient**: 全局捕获（非 lo 的 UDP 53）

```
# 所有非 loopback 的 UDP DNS 请求都重定向
-A ISTIO_OUTPUT ! -o lo -p udp -m mark ! --mark 0x539/0xfff \
    -m udp --dport 53 -j REDIRECT --to-port 15053

# conntrack zone 按 mark 区分方向
-A ISTIO_OUTPUT -p udp -m mark --mark 0x539/0xfff --dport 53 -j CT --zone 1
-A ISTIO_PRERT -p udp -m mark ! --mark 0x539/0xfff --sport 53 -j CT --zone 1
```

### 4. 使用的 iptables 表

| 表 | Sidecar (REDIRECT) | Sidecar (TPROXY) | Ambient |
|---|---|---|---|
| nat | Inbound + Outbound 重定向 | 仅 Outbound 重定向 | Inbound + Outbound 重定向 |
| mangle | 不使用 | Inbound TPROXY + mark 传播 | connmark 设置/恢复 |
| raw | DNS conntrack zone | DNS conntrack zone | DNS conntrack zone |

### 5. 自定义链名

| 用途 | Sidecar | Ambient |
|------|---------|---------|
| Inbound 入口 | `ISTIO_INBOUND` | `ISTIO_PRERT` |
| Inbound 重定向 | `ISTIO_IN_REDIRECT` | (直接 REDIRECT，无独立链) |
| Outbound 入口 | `ISTIO_OUTPUT` | `ISTIO_OUTPUT` |
| Outbound 重定向 | `ISTIO_REDIRECT` | (直接 REDIRECT，无独立链) |
| TPROXY 重定向 | `ISTIO_TPROXY` | 不使用 |
| TPROXY 已有连接 | `ISTIO_DIVERT` | 不使用 |
| 宿主机健康检查 | 不需要 | `ISTIO_POSTRT` |
| DNS 专用 | `ISTIO_OUTPUT_DNS` | (内联在 ISTIO_OUTPUT 中) |

## 流量路径对比

### Outbound (app → 外部)

**Sidecar**:

```
app 发包 → OUTPUT → nat/ISTIO_OUTPUT
  → 非 UID 1337, 非 localhost → REDIRECT 到 127.0.0.1:15001 (envoy outbound)
  → envoy 处理后发出 (UID 1337)
  → 再次经 OUTPUT → UID 1337 → RETURN → 直接出去
```

**Ambient**:

```
app 发包 → OUTPUT → nat/ISTIO_OUTPUT
  → 非 localhost, 无 mark 0x539 → REDIRECT 到 127.0.0.1:15001 (ztunnel outbound)
  → ztunnel 处理后发出 (带 mark 0x539)
  → 再次经 OUTPUT → mark 0x539 → 不匹配重定向 → 放行
```

### Inbound (外部 → app)

**Sidecar**:

```
外部包到达 → PREROUTING → nat/ISTIO_INBOUND
  → 非排除端口 → REDIRECT 到 127.0.0.1:15006 (envoy inbound)
  → envoy 处理后转发给 app (经 lo, UID 1337)
  → 直达 app
```

**Ambient**:

```
外部包到达 → PREROUTING → nat/ISTIO_PRERT
  → 非 localhost, 非 15008, 无 mark → REDIRECT 到 127.0.0.1:15006 (ztunnel inbound)
  → ztunnel 处理后转发 (带 mark 0x539, 源 IP 169.254.7.127)
  → 再次经 PREROUTING → 源 IP 169.254.7.127 → ACCEPT → 直达 app
```

## 源码位置

| 内容 | 路径 |
|------|------|
| Sidecar iptables 生成 | `tools/istio-iptables/pkg/capture/run.go` |
| Ambient iptables 生成 | `cni/pkg/iptables/iptables.go` |
| Ambient 常量定义 | `cni/pkg/config/config.go` |
| Ambient golden test | `cni/pkg/iptables/testdata/default.golden` |
| Ambient 宿主机规则 golden | `cni/pkg/iptables/testdata/hostprobe.golden` |
| Ambient 流量管理接口 | `cni/pkg/trafficmanager/interface.go` |
| Sidecar 常量定义 | `tools/istio-iptables/pkg/constants/constants.go` |
