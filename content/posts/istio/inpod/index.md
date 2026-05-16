---
title: "Ztunnel Inpod 模式"
date: 2026-05-17T16:00:00+08:00
draft: false
tags: [Istio, Ambient Mesh, Service Mesh]
categories: [Istio]
---

> Istio ambient 模式用一个 `setns` 系统调用 + Unix socket 的 FD 传递，让一个集中式代理（ztunnel）动态接管 Pod 的流量，彻底告别 sidecar 注入。

## 📋 概述

在传统的 Istio 部署中，每个 Pod 都会被注入一个 Envoy sidecar 容器。这带来了几个问题：

- **资源开销随 Pod 数量线性增长** — 1000 个 Pod = 1000 个 Envoy
- **升级必须滚动重启** — 更新 Envoy 版本需要重启所有 Pod
- **注入有副作用** — sidecar 和应用共享网络栈，调试困难

Ambient mesh 的思路是：**把 sidecar 从 Pod 中抽出来，变成节点级别的一个统一代理服务——ztunnel**。一个 ztunnel 实例处理整台机器上所有 Pod 的流量。

但这就带来一个核心问题：**ztunnel 不在 Pod 的网络命名空间里，它怎么监听 Pod 的端口、怎么以 Pod 的 IP 发起连接？**

答案就在 ztunnel 的 `inpod` 模块里。

---

## 🏗️ 架构背景

### Node Agent 与 ztunnel 的通信

Ambient 模式下，kubelet 的 CNI 插件（即 Istio 的 node agent）负责为 Pod 配置网络。配置完成后，它会通过一条 Unix Domain Socket 把 Pod 的信息发给 ztunnel：

```
┌─────────────┐                          ┌─────────────┐
│ node agent  │── UDS (Unix Domain ──────│  ztunnel    │
│ (CNI 插件)  │   Socket)                │             │
│             │   ┌──────────────────┐   │  inpod 模块 │
│  1. 发现新 Pod│   │ SCM_RIGHTS 传递   │   │   等待连接   │
│  2. 打开      │   │ netns FD        │   │             │
│     /proc/pid │   │ + 工作负载 UID   │   │             │
│     /ns/net   │   │ + 元信息         │   │             │
│  3. sendmsg   │──→│ AddWorkload 消息 │──→│ 接收并处理  │
└─────────────┘   └──────────────────┘   └─────────────┘
```

关键代码在 `workloadmanager.rs`：ztunnel 主动连接到 node agent 的 UDS 地址，然后循环读取消息：

```rust
// workloadmanager.rs:112 - 连接 node agent
super::packet::connect(&self.uds).await
```

消息有四种类型：

| 消息 | 含义 |
|------|------|
| `AddWorkload` | 新 Pod 来了，需要接管 |
| `DelWorkload` | Pod 被删除，清理 proxy |
| `KeepWorkload` | 保留这个 Pod（快照重连时不删除） |
| `WorkloadSnapshotSent` | 初始全量同步完成 |

其中 `AddWorkload` 是最核心的——它携带了三个关键数据：

```rust
pub struct WorkloadData {
    netns: OwnedFd,           // Pod 的网络命名空间 FD
    workload_uid: WorkloadUid, // Pod 的唯一标识
    workload_info: Option<WorkloadInfo>, // name, namespace, service_account
}
```

**这个 `netns: OwnedFd` 就是整个魔法的起点。** 它是 node agent 通过 `SCM_RIGHTS`（Unix socket 的 FD 传递机制）从 `/proc/<pod_pid>/ns/net` 打开并发送给 ztunnel 的。

---

## 🔍 核心组件详解

### 1. 进入 Pod 的网络命名空间

Linux 的网络命名空间隔离了网络资源（网卡、路由表、iptables、端口等）。Pod A 的 8080 端口和 Pod B 的 8080 端口之所以不冲突，就是因为它们在不同的网络命名空间里。

ztunnel 拿到 Pod 的 netns FD 后，要做的第一件事就是——**进去**。

```rust
// netns.rs:77-86
pub fn run<F, T>(&self, f: F) -> std::io::Result<T>
where
    F: FnOnce() -> T,
{
    setns(&self.inner.netns, CloneFlags::CLONE_NEWNET)?;  // 进入 Pod netns
    let ret = f();                                        // 执行操作
    setns(&self.inner.cur_netns, CloneFlags::CLONE_NEWNET).expect("must never fail"); // 切回
    Ok(ret)
}
```

`setns` 是 Linux 系统调用，把**当前线程**的网络命名空间切换到目标 FD 指向的空间。注意是线程级别的——ztunnel 的其他 worker 线程不受影响。

但这里有个关键细节：**ztunnel 并不"住"在 Pod 的 netns 里**。它只是临时进去，做完事情就回来。就像你去邻居家借个东西，借完就回自己家。

### 2. SocketFactory 的巧妙设计

ztunnel 需要为每个 Pod 创建多个 socket（入站监听 15008 端口、出站连接等）。如果每次手动调用 `netns.run()` 再做 socket 操作，代码会很繁琐。

`InPodSocketFactory` 做了一个优雅的设计：**把 netns 切换封装进 SocketFactory trait**。

```rust
// config.rs:85-95
fn configure<S: AsFd, F: FnOnce() -> io::Result<S>>(&self, f: F) -> io::Result<S> {
    let socket = self.netns.run(f)??;  // 进入 Pod netns 创建 socket
    if let Some(mark) = self.mark {
        crate::socket::set_mark(&socket, mark.into())?;  // 打 mark 标记
    }
    Ok(socket)
}

impl SocketFactory for InPodSocketFactory {
    fn new_tcp_v4(&self) -> io::Result<TcpSocket> {
        self.configure(|| self.inner.new_tcp_v4())  // 自动进入 Pod netns
    }
    fn tcp_bind(&self, addr: SocketAddr) -> io::Result<Listener> {
        let std_sock = self.configure(|| std::net::TcpListener::bind(addr))?;
        // ...
    }
    fn udp_bind(&self, addr: SocketAddr) -> io::Result<UdpSocket> { ... }
    fn ipv6_enabled_localhost(&self) -> io::Result<bool> {
        self.run_in_ns(|| self.inner.ipv6_enabled_localhost())  // 查 netns 配置也要进去
    }
}
```

**每个 socket 操作都会自动：**

1. `setns` 进入 Pod 的网络命名空间
2. 执行 socket 创建/绑定
3. 给 socket 打上 `SO_MARK`（值 1337），iptables 据此重定向流量
4. `setns` 切回 ztunnel 自己的 netns

### 3. 为什么 socket 切回后还能用？

这是最容易困惑的点。ztunnel 已经切回了自己的 netns，为什么还能用 Pod netns 里的 socket 来收发数据？

**因为 socket 的生命周期和网络命名空间是独立的。**

```
时间线:
  t1: setns(pod_netns)        → 线程切换到 Pod 的网络环境
  t2: socket(AF_INET, ...)     → 内核把这个 socket 创建在 Pod 的 netns 中
  t3: bind(15008)              → 绑定到 Pod 的 0.0.0.0:15008
  t4: setsockopt(SO_MARK, 1337)→ 打上流量标记
  t5: setns(cur_netns)         → 线程回到 ztunnel 自己的 netns
  t6: listener.accept()        → 仍然接受的是 Pod netns 里的连接！
```

`t6` 之所以能工作，是因为 socket 的 `accept`/`recv`/`send` 操作使用的是 **socket 创建时所在的网络命名空间**，而不是线程当前的 netns。

你可以理解为：**socket 在哪个 netns 里出生，它就永远属于那个 netns**。即使你拿着这个 socket 的 FD 跑到别的 netns 里，它依然能读写原来那个网络的流量。

---

## 🔑 关键技术点

### Proxy 创建和流量处理

有了 `InPodSocketFactory`，ztunnel 开始为这个 Pod 创建 proxy。入口在 `statemanager.rs`：

```rust
// statemanager.rs:294-301
let proxies = self.proxy_gen.new_proxies_from_factory(
    Some(drain_rx),
    workload_info.clone(),
    Arc::from(self.inpod_config.socket_factory(netns)),  // ← 注入 InPodSocketFactory
).await?;
```

每个 Pod 会创建多个 proxy 组件，每个都是 ztunnel 进程内的一个 tokio task：

| 组件 | 端口 | 作用 |
|------|------|------|
| `Inbound` | 15008 | HBONE 入站监听，处理 mTLS 流量 |
| `InboundPassthrough` | 动态 | 入站透传，不加密的转发 |
| `Outbound` | 动态 | 出站流量转发到目标 |
| `Socks5` | 可选 | SOCKS5 代理 |
| `DNS Proxy` | 可选 | DNS 解析代理 |

以 `Inbound` 为例，完整的流量处理链路：

```
客户端 Pod ──→ iptables (检测到 mark 1337，重定向到 15008)
                │
                ▼
           ztunnel Inbound listener (15008)
                │  socket_factory.tcp_bind(15008)
                │  → netns.run(|| bind) → socket 在 Pod netns 中
                ▼
           TLS 握手 (mTLS 双向认证)
                │  获取 Pod 的证书 (spiffe://...)
                ▼
           RBAC 策略检查
                │  这个客户端有权访问这个端口吗？
                ▼
           建立上游连接
                │  socket_factory.new_tcp_v4() → 再次进入 Pod netns
                │  → 以 Pod 的 IP 发起连接到目标
                ▼
           copy_bidirectional
                │  客户端 ↔ ztunnel ↔ 目标应用
                │  双向透明转发
```

关键代码在 `inbound.rs:303`：

```rust
// 以 Pod 的源 IP 发起上游连接
let stream = super::freebind_connect(src_ip, dst_addr, pi.socket_factory.as_ref()).await?;
```

这里 `src_ip` 是 Pod 的 IP，`socket_factory` 会进入 Pod 的 netns 创建 socket，然后 bind 到这个源 IP。这就是 **源地址伪装** 技术——对下游应用来说，请求看起来就是 Pod 直接发过来的。

### Baggage — 身份信息的传递

在流量转发过程中，ztunnel 还需要传递工作负载的元信息（集群 ID、命名空间、部署名等），这就是 `baggage` 模块的作用。

Baggage 是 W3C Trace Context 规范的一部分，以 HTTP header 的形式在请求间传递：

```
Baggage: k8s.cluster.name=K1,k8s.namespace.name=NS1,k8s.deployment.name=N1,service.name=N2,service.version=V1
```

```rust
// baggage.rs:22-30
pub struct Baggage {
    pub cluster_id: Option<Strng>,
    pub namespace: Option<Strng>,
    pub workload_name: Option<Strng>,
    pub service_name: Option<Strng>,
    pub revision: Option<Strng>,
    pub region: Option<Strng>,
    pub zone: Option<Strng>,
}
```

这些信息用于：

- **指标采集**：给 metrics 打上 Pod 身份标签
- **访问日志**：记录请求来自哪个 deployment
- **溯源追踪**：在分布式追踪中标识服务来源

在入站响应中，ztunnel 会把本地工作负载的 baggage 注入到响应头中，让下游可以识别响应者的身份。

---

## 📈 完整架构

```
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes Node                                                │
│                                                                  │
│  ┌──────────────┐    UDS (SCM_RIGHTS)    ┌──────────────────┐   │
│  │ node agent   │ ─────────────────────→ │  ztunnel 进程     │   │
│  │ (CNI 插件)   │  netns FD + UID + Info │                  │   │
│  └──────────────┘                        │ ┌──────────────┐ │   │
│                                          │ │ inpod 模块    │ │   │
│  ┌─────┐ ┌─────┐ ┌─────┐                │ │ ┌──────────┐ │ │   │
│  │Pod A│ │Pod B│ │Pod C│                │ │ │netns.run()│ │ │   │
│  │netns│ │netns│ │netns│                │ │ │InPodSocket│ │ │   │
│  └──┬──┘ └──┬──┘ └──┬──┘                │ │ │Factory    │ │ │   │
│     │        │        │                  │ │ └────┬─────┘ │ │   │
│     │iptables│        │ (重定向 mark 1337)│ │      │       │ │   │
│     ▼        ▼        ▼                  │ │      ▼       │ │   │
│  [15008]  [15008]  [15008]               │ │  ┌─────────┐ │ │   │
│     │        │        │                  │ │  │ proxy    │ │ │   │
│     └────────┴────────┘                  │ │  │ tokio    │ │ │   │
│              │                           │ │  │ task     │ │ │   │
│              │ HBONE (mTLS)              │ │  └─────────┘ │ │   │
│              ▼                           │ └──────────────┘ │   │
│         目标 Pod                         └──────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🎯 总结

ztunnel 的 inpod 模块用不到 2000 行代码完成了 sidecar 的核心功能：

1. **node agent 通过 UDS 的 SCM_RIGHTS 把 Pod 的 netns FD 传给 ztunnel**
2. **`InpodNetns::run()` 用 `setns` 临时进入 Pod 的网络命名空间**
3. **`InPodSocketFactory` 把 netns 切换封装成透明的 socket 操作**
4. **创建的 socket 永久属于 Pod 的 netns，ztunnel 切回后仍能使用**
5. **每个 Pod 的 proxy 是 ztunnel 进程内的 tokio task，共享进程资源**

对比 sidecar 模式，这意味着：

- 资源开销从 **O(n)** 变成 **O(1)**
- 升级 ztunnel **不需要重启 Pod**
- 调试更容易——ztunnel 是独立进程，日志集中

当然，这个设计也有代价：ztunnel 需要 `CAP_NET_ADMIN` 和 `CAP_SYS_ADMIN` 等特权能力，且 `setns` 操作必须在特定线程上配对执行（tokio 的线程迁移需要注意）。但这在 Kubernetes 节点的可控环境下是可以接受的。
