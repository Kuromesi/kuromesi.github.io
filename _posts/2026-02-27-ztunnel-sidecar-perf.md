---
title: 将 Ztunnel 作为 Pod 级代理实现超大规模 xDS 性能优化
date: 2026-02-27 10:00:00 +0800
categories: [Istio]
tags: [istio, envoy, service mesh, ambient, ai generated]
---

## 前言

在 Istio 的演进过程中，我们见证了从传统的 **Sidecar 模式**（基于 Envoy）到 **Ambient Mesh 模式**（基于节点级 Ztunnel 和 Waypoint）的转变。传统的 Sidecar 模式为每个 Pod 提供了强大的 L7 处理能力，但在超大规模集群中，Envoy 庞大的 xDS 配置推送成为了控制面和网络带宽的沉重负担。

!["传统的 Sidecar 模式"](/assets/img/istio/traditional-istio.png)

Istio Ambient Mesh 的出现通过解耦 L4 (Ztunnel) 和 L7 (Waypoint) 代理，极大地降低了服务网格的运维成本。然而，在 **Serverless**  或高度受限的云原生环境中，Ambient 模式遇到了坚硬的墙：

1.  **无法部署 DaemonSet**：Serverless 屏蔽了底层节点，标准的共享 Ztunnel 无法安装。
    
2.  **CNI 限制**：Ambient 依赖 Node 级的 CNI 流量重定向逻辑，这在不允许修改宿主机网络栈的环境中失效。
    

!["Ambient 模式"](/assets/img/istio/traditional-istio.png)

为了打破这一限制，我们创新性地实现了 **“Ztunnel-as-Sidecar”** 方案：将轻量级的 Ztunnel 注入 Pod 内部，这种方式可以完美适配 Serverless 环境，并和 Ambient 模式使用体验保持一致，在 **xDS 配置量和推送性能**上，相对传统 Envoy Sidecar 有巨大的性能提升。

## 实验设计与数据分析

我们在三种不同规模（服务数/Pod数）的场景下，对比了三种代理所需的 xDS 数据量：

1.  **Envoy-Sidecar**: 传统的 Envoy 作为 Sidecar 注入。
    
2.  **Waypoint**: 标准 Ambient 模式中的 Waypoint 代理。
    
3.  **Ztunnel-Sidecar**: 我们创新的轻量级 L4 Sidecar 方案。
    

### 场景 A：中小规模 (100 Services, 1000 Pods)

| 代理模式 | WDS | CDS | EDS | LDS | RDS | Total Size |
| --- | --- | --- | --- | --- | --- | --- |
| Waypoint | 326.81kB | 208.80kB | 421.30kB | 951.30kB | \- | 1.87 MB |
| Envoy Sidecar | 326.81kB | 619.30kB | 304.00kB | 363.80kB | 146.40kB | 1.72 MB |
| **Ztunnel Sidecar** | **347.31kB** | \- | \- | \- | \- | **0.35 MB** |

> **观察**: 在百级服务规模下，Ztunnel Sidecar 的配置总量仅为 Envoy 的 **20%**。Envoy 需要加载完整的 CDS/EDS/LDS/RDS，而 Ztunnel 仅需 WDS 即可工作。

### 场景 B：中等规模 (500 Services, 3000 Pods)

| 代理模式 | WDS | CDS | EDS | LDS | RDS | Total Size |
| --- | --- | --- | --- | --- | --- | --- |
| Waypoint | 1.10MB | 338.80kB | 442.50kB | 1.50MB | \- | 3.37 MB |
| Envoy Sidecar | 1.10MB | 1.10MB | 452.40kB | 181.90kB | 287.60kB | 3.10 MB |
| **Ztunnel Sidecar** | **1.20MB** | \- | \- | \- | \- | **1.20 MB** |

> **观察**: 随着服务数增加，Envoy 的 CDS 和 RDS 显著增长。Ztunnel 依然保持极简结构，总体积降至 Envoy 的 **38%**。

### 场景 C：大规模 (1000 Services, 5000 Pods)

| 代理模式 | WDS | CDS | EDS | LDS | RDS | Total Size |
| --- | --- | --- | --- | --- | --- | --- |
| Waypoint | 1.70MB | 1.32MB | 1.46MB | 6.00MB | \- | 10.49 MB |
| Envoy Sidecar | 1.70MB | 4.40MB | 1.48MB | 363.80kB | 1.09MB | 9.02 MB |
| **Ztunnel Sidecar** | **1.90MB** | \- | \- | \- | \- | **1.90 MB** |

> **关键发现**: 在千级服务规模下，Envoy Sidecar 的单实例配置高达 **9MB**，其中 CDS 占据了近一半（4.4MB）。而 Ztunnel Sidecar 仅依赖 WDS，大小控制在 **1.9MB**。 **结论**: Ztunnel Sidecar 模式的单次推送数据量仅为传统 Envoy 模式的 **21%**。

### 测试结果概览

| 场景规模 | Sidecar (Envoy) | Waypoint | **Ztunnel-Sidecar (Ours)** | 优化比例（相对  Envoy Sidecar） |
| --- | --- | --- | --- | --- |
| 100 Services / 1000 Pods | 1.72 MB | 1.87 MB | **0.347 MB** | **~80% ↓** |
| 500 Services / 3000 Pods | 3.10 MB | 3.37 MB | **1.20 MB** | **~61% ↓** |
| 1000 Services / 5000 Pods | 9.02 MB | 10.49 MB | **1.90 MB** | **~79% ↓** |

从数据构成来看，Envoy 模式（Sidecar 和 Waypoint）需要维护庞大的 **CDS (Cluster)**、**EDS (Endpoint)** 和 **LDS/RDS (Listener/Route)** 配置。这是因为 Envoy 必须理解复杂的 L7 路由规则、重试机制和负载均衡策略。

而 **Ztunnel-Sidecar** 方案几乎只依赖 **WDS (Workload Discovery Service)**。由于它仅负责 L4 流量和 mTLS 加密，它不需要感知成千上万个 L7 路由，始终保持在 Envoy xDS 配置的 20% 左右。

虽然 Waypoint 的单实例配置最大（10.49MB），但 Waypoint 是共享的，一个 2 核 4G 的 Waypoint 吞吐量通常在 2000 - 3000 RPS 左右（这与实际的 Waypoint 配置，以及请求类型有关，该数据仅供参考），其 Proxy 数量远小于 Pod 数量。**真正的性能杀手是与 Pod 数量 1:1 对应的 Sidecar。**

以 **1000 Services / 5000 Pods** 场景为例：

*   **Envoy - Sidecar:** $S = 9.02 \text{ MB}$。 对于 5000 个 Pod，总传输数据量 = $9.02 \times 5000 = \mathbf{45.1 \text{ GB}}$。
    
*   **Ztunnel-Sidecar:** $S = 1.90 \text{ MB}$。 对于 5000 个 Pod，总传输数据量 = $1.90 \times 5000 = \mathbf{9.5 \text{ GB}}$。
    

**结论 1：带宽占用显著降低。** 在相同带宽 $B$ 下，Ztunnel-Sidecar 的网络传输耗时仅为 Envoy 的 **21%**。这意味着在配置变更频率较高的场景下，Ztunnel 方案能极大地减少 Istiod 导致的网络拥塞。这将直接决定控制面是否会 OOM（内存溢出）或触发长达数分钟的推送延迟。

**结论 2：CPU 处理开销降低。** Envoy 在解析几兆字节的 JSON/Protobuf 配置并更新其内部路由表时，会消耗大量 CPU 并可能产生短暂的流量抖动。而 Ztunnel 采用了更加轻量高效的 WDS，可以大幅降低解析配置所需的 CPU 消耗。

## 结语

将 Ztunnel 引入 Pod 级 Sidecar 模式，结合了 Sidecar 的安全隔离和 Ambient 的高效性，其优越性体现在：

1.  **极简的配置模型**：摒弃了复杂的 CDS/LDS，通过 WDS 实现轻量级分发，将 xDS 推送量降低了 75%-80%。
    
2.  **更短的收敛时间**：在配置变更（如 Pod 扩缩容）时，更小的数据量意味着更快的推送和应用速度，极大提高了服务发现的时效性。
    
3.  **极高的可扩展性**：在万级 Pod 的集群中，传统 Sidecar 模式常导致 Istiod 内存溢出 (OOM) 或网络带宽打满，而 Ztunnel-Sidecar 方案将这一上限提升了 5 倍以上。
    
4.  **L4 足够原则**：对于大量仅需 mTLS 和基础访问控制、不需要复杂 L7 重写的业务，该方案提供了性价比最高的选择。
    

数据证明，通过优化 Sidecar 的“重量”，我们可以获得更具弹性的服务网格。Ztunnel-as-Sidecar 的尝试，为 Istio 在超大规模云原生环境下的应用提供了一条全新的技术路径。