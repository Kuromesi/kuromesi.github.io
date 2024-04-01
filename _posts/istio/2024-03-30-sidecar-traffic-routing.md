---
title: Istio Sidecar 模式流量路由
date: 2024-03-30 14:56:06 +0800
categories: [Cloud Native, Istio]
tags: [istio]
author: kuromesi
mermaid: true
---

## 流量路由概览

sidecar 模式的流量路径为：

- productpage 访问 reviews Pod，入站流量处理过程对应于图示上的步骤：1、2、3、4、Envoy Inbound Handler、5、6、7、8、应用容器。

- reviews Pod 访问 rating 服务的出站流量处理过程对应于图示上的步骤是：9、10、11、12、Envoy Outbound Handler、13、14、15。

![sidecar 流量路径](images/istio-iptables.svg){: width="800"}
_sidecar 流量路径_

## iptables 规则

```shell
# PREROUTING 链：用于目标地址转换（DNAT），将所有入站 TCP 流量跳转到 ISTIO_INBOUND 链上。
Chain PREROUTING (policy ACCEPT 2701 packets, 162K bytes)
 pkts bytes target     prot opt in     out     source               destination
 2701  162K ISTIO_INBOUND  tcp  --  any    any     anywhere             anywhere

# INPUT 链：处理输入数据包，非 TCP 流量将继续 OUTPUT 链。
Chain INPUT (policy ACCEPT 2701 packets, 162K bytes)
 pkts bytes target     prot opt in     out     source               destination

# OUTPUT 链：将所有出站数据包跳转到 ISTIO_OUTPUT 链上。
Chain OUTPUT (policy ACCEPT 79 packets, 6761 bytes)
 pkts bytes target     prot opt in     out     source               destination
   15   900 ISTIO_OUTPUT  tcp  --  any    any     anywhere             anywhere

# POSTROUTING 链：所有数据包流出网卡时都要先进入 POSTROUTING 链，内核根据数据包目的地判断是否需要转发出去，我们看到此处未做任何处理。
Chain POSTROUTING (policy ACCEPT 79 packets, 6761 bytes)
 pkts bytes target     prot opt in     out     source               destination

# ISTIO_INBOUND 链：将所有入站流量重定向到 ISTIO_IN_REDIRECT 链上。目的地为 15090（Prometheus 使用）和 15020（Ingress gateway 使用，用于 Pilot 健康检查）端口的流量除外，发送到以上两个端口的流量将返回 iptables 规则链的调用点，即 PREROUTING 链的后继 INPUT 后直接调用原始目的地。
Chain ISTIO_INBOUND (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 RETURN     tcp  --  any    any     anywhere             anywhere             tcp dpt:ssh
    2   120 RETURN     tcp  --  any    any     anywhere             anywhere             tcp dpt:15090
 2699  162K RETURN     tcp  --  any    any     anywhere             anywhere             tcp dpt:15020
    0     0 ISTIO_IN_REDIRECT  tcp  --  any    any     anywhere             anywhere

# ISTIO_IN_REDIRECT 链：将所有的入站流量跳转到本地的 15006 端口，至此成功的拦截了流量到 sidecar 代理的 Inbound Handler 中。
Chain ISTIO_IN_REDIRECT (3 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 REDIRECT   tcp  --  any    any     anywhere             anywhere             redir ports 15006

# ISTIO_OUTPUT 链：规则比较复杂，将在下文解释
Chain ISTIO_OUTPUT (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 RETURN     all  --  any    lo      127.0.0.6            anywhere #规则1
    0     0 ISTIO_IN_REDIRECT  all  --  any    lo      anywhere            !localhost            owner UID match 1337 #规则2
    0     0 RETURN     all  --  any    lo      anywhere             anywhere             ! owner UID match 1337 #规则3
   15   900 RETURN     all  --  any    any     anywhere             anywhere             owner UID match 1337 #规则4
    0     0 ISTIO_IN_REDIRECT  all  --  any    lo      anywhere            !localhost            owner GID match 1337 #规则5
    0     0 RETURN     all  --  any    lo      anywhere             anywhere             ! owner GID match 1337 #规则6
    0     0 RETURN     all  --  any    any     anywhere             anywhere             owner GID match 1337 #规则7
    0     0 RETURN     all  --  any    any     anywhere             localhost #规则8
    0     0 ISTIO_REDIRECT  all  --  any    any     anywhere             anywhere #规则9

# ISTIO_REDIRECT 链：将所有流量重定向到 Envoy 代理的 15001 端口。
Chain ISTIO_REDIRECT (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 REDIRECT   tcp  --  any    any     anywhere             anywhere             redir ports 15001
```

其中，output 链的规则如下：

| 规则 | target | in | out | source | destination |
| --- | --- | --- | --- | --- | --- |
| 1 | RETURN | any | lo | 127.0.0.6 | anywhere |
| 2 | ISTIO_IN_REDIRECT | any | lo | anywhere | !localhost owner UID match 1337 |
| 3 | RETURN | any | lo | anywhere | anywhere !owner UID match 1337 |
| 4 | RETURN | any | any | anywhere | anywhere owner UID match 1337 |
| 5 | ISTIO_IN_REDIRECT | any | lo | anywhere | !localhost owner GID match 1337 |
| 6 | RETURN | any | lo | anywhere | anywhere !owner GID match 1337 |
| 7 | RETURN | any | any | anywhere | anywhere owner GID match 1337 |
| 8 | RETURN | any | any | anywhere | localhost |
| 9 | ISTIO_REDIRECT | any | any | anywhere | anywhere |

**规则 1**

- 目的：透传 Envoy 代理发送到本地应用容器的流量，使其绕过 Envoy 代理，直达应用容器。
- 对应图示中的步骤：6 到 7。
- 详情：该规则使得所有来自 127.0.0.6（该 IP 地址将在下文解释）的请求，跳出该链，返回 iptables 的调用点（即 OUTPUT）后继续执行其余路由规则，即 POSTROUTING 规则，把流量发送到任意目的地址，如本地 Pod 内的应用容器。如果没有这条规则，由 Pod 内 Envoy 代理发出的对 Pod 内容器访问的流量将会执行下一条规则，即规则 2，流量将再次进入到了 Inbound Handler 中，从而形成了死循环。将这条规则放在第一位可以避免流量在 Inbound Handler 中死循环的问题。

**规则 2、5**

- 目的：处理 Envoy 代理发出的站内流量（Pod 内部的流量），但不是对 localhost 的请求，通过后续规则将其转发给 Envoy 代理的 Inbound Handler。该规则适用于 Pod 对自身 IP 地址调用的场景，即 Pod 内服务之间的访问。
- 详情：如果流量的目的地非 localhost，且数据包是由 1337 UID（即 istio-proxy 用户，Envoy 代理）发出的，流量将被经过 ISTIO_IN_REDIRECT 最终转发到 Envoy 的 Inbound Handler。

**规则 3、6**

- 目的：透传 Pod 内的应用容器的站内流量。该规则适用于容器内部的流量。例如在 Pod 内对 Pod IP 或 localhost 的访问。
- 对应图示中的步骤：6 到 7。
- 详情：如果流量不是由 Envoy 用户发出的，那么就跳出该链，返回 OUTPUT 调用 POSTROUTING，直达目的地。

**规则 4、7**

- 目的：透传 Envoy 代理发出的出站请求。
- 对应图示中的步骤：14 到 15。
- 详情：如果请求是由 Envoy 代理发出的，则返回 OUTPUT 继续调用 POSTROUTING 规则，最终直接访问目的地。

**规则 8**

- 目的：透传 Pod 内部对 localhost 的请求。
- 详情：如果请求的目的地是 localhost，则返回 OUTPUT 调用 POSTROUTING，直接访问 localhost。

**规则 9**

- 目的：所有其他的流量将被转发到 ISTIO_REDIRECT 后，最终达到 Envoy 代理的 Outbound Handler。
- 对应图示中的步骤：10 到 11。
- 以上规则避免了 Envoy 代理到应用程序的路由在 iptables 规则中的死循环，保障了流量可以被正确的路由到 Envoy 代理上，也可以发出真正的出站请求。

### 具体案例

#### 访问相同 pod 服务

当 pod 同时包含应用 A 和应用 B 时，应用 A 访问 B.service 域名时匹配规则 9 会由 envoy outbound 劫持进行处理，查找可用的 endpoint 并将生成的流量进行转发。如果 endpoint 的 ip 为本 pod ip，则匹配规则2直接交由 envoy inbound 进行处理并发出流量，匹配到规则 1 之后直达应用 B。

![相同pod](images/envoy-same-pod.drawio.png)
_相同pod_

### 访问 localhost 服务

当 pod 内容器通过访问 localhost 进行调用时，匹配规则 3，不交给 envoy 处理，直接发送给 指定容器。

### 访问不同 pod 服务

当应用 A 访问其它 pod 中的服务 B.service 时，首先匹配规则 9 由 envoy outbound 劫持进行处理，查找可用的 endpoint 并将生成的流量进行转发。之后匹配到规则 4，直接跳出 ISTIO_OUTPUT 链，最终到达目的地。

> [Istio 中的 Sidecar 注入、透明流量劫持及流量路由过程详解](https://jimmysong.io/blog/sidecar-injection-iptables-and-traffic-routing/)