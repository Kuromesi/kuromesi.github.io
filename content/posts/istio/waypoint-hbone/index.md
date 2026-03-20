---
title: "Istio Waypoint HBONE 流量路由简析"
date: 2026-03-20T10:46:00+08:00
tags: ["Ambient Mesh", "HBONE", "Waypoint", "Service Mesh"]
categories: ["Istio"]
draft: false
---

## 📋 概述

本文详细解析 Istio Ambient Mesh 中 Waypoint Proxy 的 HBONE 流量路由机制，通过 config dump 逆向分析，揭示已知服务和未知服务的完整流量路径。

---

## 🎯 核心结论

### 流量路由决策树

```
                        流量到达 Waypoint (:15008)
                                │
                                ▼
                    ┌───────────────────────┐
                    │ connect_terminate     │
                    │ - TLS 终止            │
                    │ - 提取 :authority     │
                    │ - 提取目标 IP:Port    │
                    └───────────┬───────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │ main_internal         │
                    │ Filter Chain Matcher  │
                    │ 匹配目标 IP:Port      │
                    └───────────┬───────────┘
                                │
                ┌───────────────┼───────────────┐
                │               │               │
                ▼               ▼               ▼
          ┌───────────┐   ┌───────────┐   ┌───────────┐
          │ IP 匹配     │   │ IP 不匹配  │   │ IP 不匹配  │
          │ Port 匹配   │   │ 或        │   │ 或        │
          │ ✅        │   │ Port 不匹配 │   │ Port 不匹配 │
          └─────┬─────┘   └─────┬─────┘   └─────┬─────┘
                │               │               │
                ▼               │               │
        ┌───────────────┐       │               │
        │ 已知服务       │       │               │
        │ Filter Chain  │       │               │
        │               │       │               │
        │ → 服务集群     │       │               │
        │ connect_originate    │               │
        └───────────────┘       │               │
                                ▼               ▼
                        ┌───────────────────────────┐
                        │ 未知服务/其他 Waypoint    │
                        │ direct-tcp / direct-http  │
                        │                           │
                        │ → encap Cluster          │
                        │ → connect_originate      │
                        │ → 新 HBONE 隧道           │
                        │ → 下一个 Waypoint        │
                        └───────────────────────────┘
```

---

## 🏗️ 架构背景

### Waypoint Proxy 定位

```
┌─────────────────────────────────────────────────────────────────┐
│                    Istio Ambient Mesh 架构                       │
│                                                                 │
│   客户端 Pod → ztunnel → Waypoint → 服务 Pod                    │
│              (节点级)   (服务级)                                 │
│                                                                 │
│  Waypoint Proxy:                                                │
│  - 服务级别的共享代理                                           │
│  - 执行 L7 策略 (授权、限流、路由)                                │
│  - 提供可观测性 (指标、日志、追踪)                               │
│  - 基于服务账号 identity                                        │
└─────────────────────────────────────────────────────────────────┘
```

### HBONE 协议

```
┌─────────────────────────────────────────────────────────────────┐
│                         HBONE 协议                              │
│                                                                 │
│  HTTP-based Overlay Network Encapsulation                       │
│                                                                 │
│  特点:                                                          │
│  - 基于 HTTP/2 CONNECT 方法                                      │
│  - TLS 1.3 加密                                                  │
│  - mTLS 双向认证                                                 │
│  - SPIFFE 身份验证                                               │
│  - 标准端口：15008                                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🔍 核心组件详解

### 1. connect_terminate Listener

**端口:** 15008  
**作用:** 终止入站 HBONE 隧道

```yaml
name: connect_terminate
address: 0.0.0.0:15008
transport_socket:
  name: tls
  typed_config:
    common_tls_context:
      tls_params:
        tls_minimum_protocol_version: TLSv1_3
      alpn_protocols: [h2]
      require_client_certificate: true
filters:
  - waypoint_downstream_peer_metadata   # 提取下游身份
  - connect_authority                   # 提取 :authority
  - router                              # 路由到 main_internal
```

**关键功能:**
- TLS 1.3 终止
- 客户端证书验证 (mTLS)
- 提取 `:authority` 头到 filter_state
- 提取客户端 SPIFFE 身份
- 转发到 `main_internal` 监听器

---

### 2. main_internal Listener

**类型:** Internal Listener (不绑定物理端口)  
**作用:** 流量路由决策中心

```yaml
name: main_internal
internal_listener: {}
filter_chain_matcher:
  matcher_tree:
    input: {name: ip}
    custom_match:
      range_matchers:
        - ranges:
            - address_prefix: 192.168.40.238
              prefix_len: 32
          on_match:
            matcher:
              exact_match_map:
                map:
                  "8000":
                    action:
                      name: inbound-vip|8000|http|httpbin...
filter_chains:
  - name: inbound-vip|8000|http|httpbin...  # 已知服务
  - name: direct-tcp                         # 未知服务 (TCP)
  - name: direct-http                        # 未知服务 (HTTP)
```

**关键功能:**
- 基于目标 IP:Port 的精确匹配
- 匹配成功 → 已知服务 Filter Chain
- 匹配失败 → direct-tcp 或 direct-http

---

### 3. 已知服务 Filter Chain

```yaml
name: inbound-vip|8000|http|httpbin.ambient-test.svc.cluster.local
filters:
  - header_to_metadata
  - grpc_stats
  - fault
  - cors
  - waypoint_upstream_peer_metadata
  - router
route_config:
  routes:
    - match: {prefix: /}
      route:
        cluster: inbound-vip|8000|http|httpbin...
        timeout: 0s
        retry_policy:
          retry_on: reset-before-request
          num_retries: 2
```

**路由目标:** 服务集群 → 服务 Pod

---

### 4. 未知服务 Filter Chain

```yaml
# direct-tcp
name: direct-tcp
filters:
  - connect_authority
  - istio.metadata_exchange
  - tcp_proxy
    cluster: encap

# direct-http
name: direct-http
filters:
  - connect_authority
  - http_connection_manager
    route_config:
      routes:
        - route: {cluster: encap}
```

**路由目标:** encap Cluster

---

### 5. encap Cluster

**类型:** STATIC  
**作用:** 内部封装，转发到 `connect_originate`

```yaml
name: encap
type: STATIC
transport_socket:
  name: internal_upstream
  typed_config:
    passthrough_metadata:
      - kind: {host: {}}
        name: envoy.filters.listener.original_dst
    transport_socket:
      name: raw_buffer
load_assignment:
  endpoints:
    - address:
        envoy_internal_address:
          server_listener_name: connect_originate
```

**关键功能:**
- 使用 `internal_upstream` 内部转发
- 传递 filter_state 元数据
- 目标：`connect_originate` 监听器

---

### 6. connect_originate Listener & Cluster

**作用:** 发起出站 HBONE 隧道

```yaml
# Listener
name: connect_originate
internal_listener: {}
filters:
  - tcp_proxy
    cluster: connect_originate
    tunneling_config:
      hostname: "%DOWNSTREAM_LOCAL_ADDRESS%"

# Cluster
name: connect_originate
type: ORIGINAL_DST
transport_socket:
  name: tls
  typed_config:
    common_tls_context:
      tls_params: {tls_minimum_protocol_version: TLSv1_3}
      alpn_protocols: [h2]
original_dst_lb_config:
  upstream_port_override: 15008
  metadata_key:
    key: envoy.filters.listener.original_dst
    path: [{key: waypoint}]
```

**关键功能:**
- 从 filter_state 获取目标地址
- 端口覆盖为 15008
- TLS 1.3 + HTTP/2 CONNECT
- 发起新的 HBONE 隧道

---

## 🔑 关键技术点

### 1. Filter Chain Matcher

```yaml
filter_chain_matcher:
  matcher_tree:
    input: {name: ip}
    custom_match:
      range_matchers:
        - ranges:
            - address_prefix: 192.168.40.238
              prefix_len: 32
          on_match:
            matcher:
              exact_match_map:
                map:
                  "8000":
                    action:
                      name: inbound-vip|8000|http|httpbin...
```

**匹配逻辑:**
1. 检查目标 IP 是否在范围内
2. 如果匹配，检查目标 Port
3. 如果都匹配，选择对应的 Filter Chain
4. 如果不匹配，落入通配 Filter Chain (direct-tcp/direct-http)

---

### 2. 协议检测 (Listener Filters)

```yaml
listener_filters:
  - envoy.filters.listener.original_dst
  - envoy.filters.listener.http_inspector
    filter_disabled:
      destination_port_range: {start: 8000, end: 8001}
  - envoy.filters.listener.tls_inspector
    filter_disabled:
      destination_port_range: {start: 8000, end: 8001}
```

**作用:**
- `http_inspector`: 检测流量是否是 HTTP
- 在 8000 端口禁用 (因为已精确匹配)
- 检测结果用于选择 direct-tcp 或 direct-http

---

### 3. 元数据传递 (passthrough_metadata)

```yaml
# encap Cluster
transport_socket:
  name: internal_upstream
  typed_config:
    passthrough_metadata:
      - kind: {host: {}}
        name: envoy.filters.listener.original_dst
```

**作用:**
- 将 `connect_terminate` 提取的 filter_state 传递到 `connect_originate`
- `connect_originate` 需要这些信息来确定 HBONE 隧道目标

---

### 4. ORIGINAL_DST

```yaml
# connect_originate Cluster
type: ORIGINAL_DST
original_dst_lb_config:
  upstream_port_override: 15008
  metadata_key:
    key: envoy.filters.listener.original_dst
    path: [{key: waypoint}]
```

**作用:**
- 不从配置中获取目标地址
- 从 filter_state 动态读取
- 端口覆盖为 15008 (HBONE 标准端口)

---

## 📈 设计哲学

### 为什么需要 encap？

```
┌─────────────────────────────────────────────────────────────────┐
│                    encap 的设计哲学                              │
│                                                                 │
│  "永远不要让流量丢失"                                           │
│                                                                 │
│  即使当前 Waypoint 不知道如何处理这个流量，                      │
│  也不要直接拒绝，而是：                                        │
│  1. 通过 encap 转发到下一个可能的 Waypoint                      │
│  2. 或者通过 Egress Gateway 发送到外部                          │
│  3. 让下游决定如何处理                                          │
│                                                                 │
│  这比直接拒绝更健壮，支持：                                     │
│  - 配置延迟容忍                                                 │
│  - 服务迁移无中断                                               │
│  - 多跳策略执行                                                 │
│  - 灵活的网格架构                                               │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🎯 总结

### 流量路由决策

```
┌─────────────────────────────────────────────────────────────────┐
│                    流量路由决策树                                │
│                                                                 │
│                        流量到达 :15008                          │
│                            │                                    │
│                            ▼                                    │
│                  connect_terminate                              │
│                  - TLS 终止                                      │
│                  - 提取元数据                                   │
│                            │                                    │
│                            ▼                                    │
│                  main_internal                                  │
│                  Filter Chain Matcher                           │
│                            │                                    │
│         ┌──────────────────┼──────────────────┐                │
│         │                  │                  │                │
│         ▼                  ▼                  ▼                │
│   IP✅ Port✅        IP❌ 或           IP❌ 或                │
│   已知服务           Port❌             Port❌                 │
│                      HTTP 流量           TCP 流量               │
│         │                  │                  │                │
│         ▼                  ▼                  ▼                │
│   inbound-vip        direct-http       direct-tcp             │
│   → 服务集群         → encap           → encap                │
│   → 服务 Pod         → connect_        → connect_             │
│                      originate         originate               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 核心公式

```
已知服务 = connect_terminate → main_internal → 服务集群 → connect_originate

未知服务 = connect_terminate → main_internal → encap → connect_originate
```