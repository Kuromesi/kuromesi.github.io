---
title: Istio Ambient Mesh
date: 2024-03-13 23:57:06 +0800
categories: [Cloud Native, Istio]
tags: [istio]
author: kuromesi
---

![Ambient 模式中的四层流量路径](images/ambient-mesh-l4-traffic-path.svg)

## 原理
Ambient 模式使用 tproxy 和 HBONE 这两个关键技术实现透明流量劫持和路由的：
- 使用 tproxy 将主机 Pod 中的流量劫持到 Ztunnel（Envoy Proxy）中，实现透明流量劫持；
- 使用 HBONE 建立在 Ztunnel 之间传递 TCP 数据流隧道；

## 什么是 tproxy？
tproxy 是 Linux 内核自 2.2 版本以来支持的透明代理（Transparent proxy），其中的 t 代表 transparent，即透明。你需要在内核配置中启用 NETFILTER_TPROXY 和策略路由。通过 tproxy，Linux 内核就可以作为一个路由器，将数据包重定向到用户空间。详见 tproxy 文档 。

## 什么是 HBONE？
HBONE 是 HTTP-Based Overlay Network Environment 的缩写，是一种使用 HTTP 协议提供隧道能力的方法。客户端向 HTTP 代理服务器发送 HTTP CONNECT 请求（其中包含了目的地址）以建立隧道，代理服务器代表客户端与目的地建立 TCP 连接，然后客户端就可以通过代理服务器透明的传输 TCP 数据流到目的服务器。在 Ambient 模式中，Ztunnel（其中的 Envoy）实际上是充当了透明代理，它使用 Envoy Internal Listener 来接收 HTTP CONNECT 请求和传递 TCP 流给上游集群。