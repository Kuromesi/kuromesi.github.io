---
title: Istio Ambient Mesh
date: 2024-03-13 23:57:06 +0800
categories: [Cloud Native, Istio]
tags: [ambient]
author: kuromesi
---

![Ambient 模式中的四层流量路径](images/ambient-mesh-l4-traffic-path.svg)
_Ambient 模式中的四层流量路径_

## 原理

Ambient 模式使用 tproxy 和 HBONE 这两个关键技术实现透明流量劫持和路由的：
- 使用 tproxy 将主机 Pod 中的流量劫持到 Ztunnel（Envoy Proxy）中，实现透明流量劫持；
- 使用 HBONE 建立在 Ztunnel 之间传递 TCP 数据流隧道；

## 架构

### Ztunnel

与 Sidecar 类似，Ztunnel 也充当 xDS 客户端和 CA 客户端：

1. 在启动期间，它使用服务账户令牌。一旦从 Ztunnel 到 Istiod 的连接使用 TLS 建立连接，它就开始作为一个 xDS 客户端获取 xDS 配置。 这种工作方式类似于 Sidecar 或 Gateway 或 waypoint proxy，只是 Istiod 识别来自 Ztunnel 的请求，并为 Ztunnel 发送特制的 xDS 配置。 并发送专门为 Ztunnel 设计的 xDS 配置，您将很快了解到更多。
2. 它还充当 CA 客户端，代表其管理的所有位于同一位置的工作负载管理和提供 mTLS 证书。
3. 当流量输入或输出时，它充当核心代理，为其管理的所有位于同一位置的工作负载处理入站和出站流量（网格外纯文本或网格内HBONE）。
4. 它提供 L4 遥测（指标和日志）以及带有调试信息的管理服务器，以帮助您在需要时调试 Ztunnel。

![ztunnel](images/ztunnel-architecture.png)
_ztunnel_

### Waypoint

与 Sidecar 类似，Waypoint Proxy 也是基于 Envoy 的，由 Istio 动态配置以服务于您的应用程序配置。 Waypoint Proxy 的独特之处在于它按照每个命名空间（默认）或每个服务账户来运行。 通过在应用程序 Pod 之外运行，Waypoint Proxy 可以独立于应用程序安装、升级和扩展，并降低运营成本。

![waypoint proxy](images/waypoint-architecture.png)
_waypoint proxy_

## 什么是 tproxy？

tproxy 是 Linux 内核自 2.2 版本以来支持的透明代理（Transparent proxy），其中的 t 代表 transparent，即透明。你需要在内核配置中启用 NETFILTER_TPROXY 和策略路由。通过 tproxy，Linux 内核就可以作为一个路由器，将数据包重定向到用户空间。详见 tproxy 文档 。

## 什么是 HBONE？

HBONE 是 HTTP-Based Overlay Network Environment 的缩写，是一种使用 HTTP 协议提供隧道能力的方法。客户端向 HTTP 代理服务器发送 HTTP CONNECT 请求（其中包含了目的地址）以建立隧道，代理服务器代表客户端与目的地建立 TCP 连接，然后客户端就可以通过代理服务器透明的传输 TCP 数据流到目的服务器。在 Ambient 模式中，Ztunnel（其中的 Envoy）实际上是充当了透明代理，它使用 Envoy Internal Listener 来接收 HTTP CONNECT 请求和传递 TCP 流给上游集群。

## 流量路由

在 Ambient 模式中，工作负载分为 3 类：

- Uncaptured: 这是一个未启用任何网格特性的标准 Pod。
- Captured: 这是流量已被 Ztunnel 截取的 Pod。 通过在命名空间上设置 istio.io/dataplane-mode=ambient 标签可以捕获 Pod。
- Waypoint enabled: 这是一个被“捕获”且部署了 waypoint 代理的 Pod。 waypoint 默认将应用到同一命名空间中的所有 Pod。 通过在 Gateway 上使用 istio.io/for-service-account 注解， 可以选择将 waypoint 仅应用到特定的服务账号。 如果同时存在命名空间 waypoint 和服务账号 waypoint，将优先使用服务账号 waypoint。

根据工作负载所属的类别，请求的路径将有所不同。

### Ztunnel 路由

#### 出站

当被捕获的 Pod 发出出站请求时，它将被透明地重定向到 Ztunnel，由 Ztunnel 来决定如何转发请求以及转发到哪儿。 总之，流量路由行为就像 Kubernetes 默认的流量路由一样； 到 Service 的请求将被发送到 Service 内的一个端点， 而直接发送到 Pod IP 的请求则将直接转到该 IP。

然而，根据目的地的权能，可能会出现不同的行为。 如果目的地也被捕获，或以其他方式具有 Istio 代理权能（例如 Sidecar）， 请求将被升级为加密的 HBONE 隧道。 如果目的地有一个 waypoint 代理，除了升级到 HBONE 之外，请求将被转发到该 waypoint。

请注意，对于到 Service 的请求，将选择特定的端点来决定其是否具有 waypoint。 然而，如果请求具有 waypoint，请求将随着 Service 的目标目的地而不是所选的端点被发送。 这就允许 waypoint 将面向服务的策略应用到流量。 在极少情况下，Service 会混合使用启用/未启用 waypoint 的端点， 某些请求将被发送到 waypoint，而到相同服务的其他请求不会被发送到 waypoint。

#### 入站

当被捕获的 Pod 收到一个入站请求时，它将被透明地重定向到 Ztunnel。 当 Ztunnel 收到请求时，它将应用鉴权策略并仅在请求与策略匹配时转发请求。

Pod 可以接收 HBONE 流量或纯文本流量。 这两种流量默认都可以被 Ztunnel 接受。 因为纯文本请求在评估鉴权策略时没有对等身份， 所以用户可以设置一个策略，要求进行身份验证（可以是任何身份验证或特定身份验证），以阻止所有纯文本流量。

当目的地启用 waypoint 时，所有请求必须通过 waypoint 来执行策略。 Ztunnel 将确保达成这种行为。 然而，存在一些边缘场景：一个行为良好的 HBONE 客户端（例如另一个 Ztunnel 或 Istio Sidecar） 知道发送到 waypoint，但其他客户端（例如网格外的工作负载）可能不知道 waypoint 代理的任何信息并直接发送请求。 当进行这些直接调用时，Ztunnel 将使请求"红头文件"调整到其自身 waypoint 的请求，以确保这些策略被正确执行。

### Waypoint 路由

waypoint 以独占方式接收 HBONE 请求。 在收到一个请求时，waypoint 将确保此请求指向其管理的 Pod 或包含所管理 Pod 的 Service。

对于任何请求类型，waypoint 将在转发请求之前执行策略 （例如 AuthorizationPolicy、WasmPlugin、Telemetry 等）。

对与直接发送到 Pod 的，请求将在应用策略后才会被直接转发。

对于发送到 Service 的请求，waypoint 还将应用路由和负载均衡。 默认情况下，Service 会简单地将请求路由到本身，在其端点之间进行负载均衡。 这可以重载为针对 Service 的路由。

例如，以下策略将确保到 echo 服务的请求被转发到 echo-v1：

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: echo
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: echo
  rules:
  - backendRefs:
    - name: echo-v1
      port: 80
```

> [https://preliminary.istio.io/latest/zh/docs/ops/ambient/architecture/](https://preliminary.istio.io/latest/zh/docs/ops/ambient/architecture/)

### Istio Ambient 模式四层路由

> [Istio Ambient 模式中的透明流量劫持四层网络路由路径详解](https://jimmysong.io/blog/ambient-mesh-l4-traffic-path/)

### Istio Ambient 模式七层路由

> [Istio Ambient 模式中的七层流量路由路径详解](https://jimmysong.io/blog/ambient-mesh-l7-traffic-path/)

### Ambient 模式流量路径

> [https://www.cnblogs.com/alisystemsoftware/p/17760960.html](https://www.cnblogs.com/alisystemsoftware/p/17760960.html)

## Istio Ambient 入门

> [Ambient 模式入门](https://preliminary.istio.io/latest/zh/docs/ops/ambient/getting-started/)

