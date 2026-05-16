---
title: "Istio XDS 推送机制随记：EDS"
date: 2026-05-17T10:00:00+08:00
draft: false
tags: [Istio, XDS, EDS, PushContext, 503]
categories: [Istio]
---

> Istio 的 XDS 推送机制通过全量（Full Push）和增量（Incremental Push）两种模式来平衡一致性和性能。理解推送逻辑对于排查 Gateway Programmed False、503 UC 等常见问题至关重要。

## 📋 概述

Istio 控制平面（istiod）通过 XDS 协议将配置下发到 Envoy Sidecar 或 ztunnel。核心流程如下：

1. **事件触发**：Kubernetes 资源（Service、Endpoint、Gateway 等）变化
2. **事件处理**：controller 调用 `XDSUpdater.ConfigUpdate` 触发推送
3. **推送计算**：`DiscoveryServer.Push` 决定是否重新计算 PushContext
4. **资源下发**：按 Cluster → Endpoint → Listener → Route → Secret 顺序推送

本文从源码角度分析 XDS 推送机制，并梳理实践中遇到的三个典型问题。

---

## 🏗️ XDS 推送机制

### 事件触发链

以 EndpointSlice 变化为例，完整链路：

```
K8s EndpointSlice 变化
    │
    ▼
endpointSliceController.onEventInternal()
    │
    ├── pushEDS(hostnames, namespace)          ← 更新 Endpoint 数据
    │       │
    │       └── DiscoveryServer.EDSUpdate()
    │               │
    │               └── EndpointIndex.UpdateServiceEndpoints()
    │                       │
    │                       └── 返回 PushType (Full / Incremental / NoPush)
    │
    └── XDSUpdater.ConfigUpdate(&PushRequest)   ← 触发推送
            │
            └── DiscoveryServer.Push()
                    │
                    └── AdsPushAll()
                            │
                            └── StartPush(req)  ← 下发到所有连接的 Envoy
```

```go
// endpointSliceController: EndpointSlice 事件处理
func (esc *endpointSliceController) onEventInternal(_, ep *v1.EndpointSlice, event model.Event) {
    esc.pushEDS(hostnames, namespacedName.Namespace)

    if len(configsUpdated) > 0 {
        esc.c.opts.XDSUpdater.ConfigUpdate(&model.PushRequest{
            Full:           true,
            ConfigsUpdated: configsUpdated,
            Reason:         model.NewReasonStats(model.HeadlessEndpointUpdate),
        })
    }
}
```

```go
// DiscoveryServer.EDSUpdate: 更新 Endpoint 并触发推送
func (s *DiscoveryServer) EDSUpdate(shard model.ShardKey, serviceName string, namespace string,
    istioEndpoints []*model.IstioEndpoint,
) {
    inboundEDSUpdates.Increment()
    pushType := s.Env.EndpointIndex.UpdateServiceEndpoints(shard, serviceName, namespace, istioEndpoints, true)
    if pushType == model.IncrementalPush || pushType == model.FullPush {
        s.ConfigUpdate(&model.PushRequest{
            Full:           pushType == model.FullPush,
            ConfigsUpdated: sets.New(model.ConfigKey{Kind: kind.ServiceEntry, Name: serviceName, Namespace: namespace}),
            Reason:         model.NewReasonStats(model.EndpointUpdate),
        })
    }
}
```

### PushType 判断逻辑

`EndpointIndex.UpdateServiceEndpoints` 决定了推送类型：

```go
func (e *EndpointIndex) UpdateServiceEndpoints(
    shard ShardKey, hostname string, namespace string,
    istioEndpoints []*IstioEndpoint, logPushType bool,
) PushType {
    // 场景 1: 无 Endpoint → 删除 shard，触发 Incremental Push
    if len(istioEndpoints) == 0 {
        e.DeleteServiceShard(shard, hostname, namespace, true)
        return IncrementalPush
    }

    pushType := IncrementalPush

    // 场景 2: 新 Service 首次出现 → Full Push
    ep, created := e.GetOrCreateEndpointShard(hostname, namespace)
    if created {
        pushType = FullPush
    }

    // 场景 3: 健康状态未变化 → No Push
    newIstioEndpoints, needPush := endpointUpdateRequiresPush(oldIstioEndpoints, istioEndpoints)
    if pushType != FullPush && !needPush {
        pushType = NoPush
    }

    // 场景 4: ServiceAccount 变化 → Full Push
    saUpdated := updateShardServiceAccount(ep, hostname)
    if saUpdated && pushType != FullPush {
        pushType = FullPush
    }

    e.clearCacheForService(hostname, namespace)
    return pushType
}
```

**四种 PushType 总结：**

| 场景 | PushType | 触发条件 |
|------|----------|----------|
| **新 Service 出现** | FullPush | 首次创建 EndpointShard |
| **Endpoint 健康状态变化** | IncrementalPush | Pod 就绪/未就绪切换 |
| **ServiceAccount 变化** | FullPush | mTLS 证书身份变更 |
| **健康状态无变化** | NoPush | Endpoint IP 不变或新 Pod 不健康 |

### Push 流程

```go
// DiscoveryServer.Push: 核心推送逻辑
func (s *DiscoveryServer) Push(req *model.PushRequest) {
    if !req.Full {
        // 增量推送：复用旧的 PushContext
        req.Push = s.globalPushContext()
        s.dropCacheForRequest(req)
        s.AdsPushAll(req)
        return
    }

    // 全量推送：重新计算 PushContext
    oldPushContext := s.globalPushContext()
    if oldPushContext != nil {
        oldPushContext.OnConfigChange()
        envoyfilter.RecordMetrics()
    }

    versionLocal := s.NextVersion()
    push := s.initPushContext(req, oldPushContext, versionLocal)
    req.Push = push
    s.AdsPushAll(req)
}
```

### 推送顺序

Istio 严格按以下顺序推送资源，确保依赖关系正确：

```go
var PushOrder = []string{
    v3.ClusterType,          // 1. CDS - 集群定义
    v3.EndpointType,         // 2. EDS - 后端地址
    v3.ListenerType,         // 3. LDS - 监听器
    v3.RouteType,            // 4. RDS - 路由规则
    v3.SecretType,           // 5. SDS - 证书
    v3.AddressType,          // 6. ADS - Ambient 地址
    v3.WorkloadType,         // 7. WDS - 工作负载
    v3.WorkloadAuthorizationType, // 8. 授权策略
}
```

---

## 🔍 EDS 为什么不需要重新计算 PushContext

### 核心结论

**EDS 只关心 Endpoint 数据的变化，而 PushContext 主要包含的是配置层面的聚合数据。**

当 `PushRequest.Full = false` 时：

| 操作 | 是否执行 |
|------|----------|
| 重新计算 PushContext | ❌ |
| 重新计算代理状态（ServiceInstances） | ❌ |
| 在标准指标中报告（push time） | ❌ |
| 重建变化的 ClusterLoadAssignment | ✅ |

### PushContext 包含的内容

```go
// pilot/pkg/model/push_context.go
func (ps *PushContext) createNewContext(env *Environment) {
    ps.initServiceRegistry(env, nil)        // Service 注册表
    ps.initKubernetesGateways(env)
    ps.initVirtualServices(env)             // VirtualService
    ps.initDestinationRules(env)            // DestinationRule
    ps.initAuthnPolicies(env)               // 认证策略
    ps.initAuthorizationPolicies(env)       // 授权策略
    ps.initTelemetry(env)                   // Telemetry 配置
    ps.initProxyConfigs(env)                // ProxyConfig
    ps.initWasmPlugins(env)                 // Wasm 插件
    ps.initEnvoyFilters(env, nil, nil)      // EnvoyFilter
    ps.initGateways(env)                    // Gateway 配置
    ps.initAmbient(env)                     // Ambient 配置
    ps.initSidecarScopes(env)               // Sidecar 范围
}
```

这些全部都是**控制平面配置**，不包括具体的 Endpoint IP 地址。

### 触发场景对比

| 触发原因 | Full | 需要新 PushContext? | 说明 |
|---------|------|-------------------|------|
| Pod IP 变化 | `false` | ❌ | Endpoint IP 列表变化，Service 配置本身没变 |
| Service Port 变化 | `true` | ✅ | Service 定义变化，可能影响路由规则 |
| DestinationRule 变化 | `true` | ✅ | 可能改变 Subset 定义，影响 CDS/RDS |
| VirtualService 变化 | `true` | ✅ | 路由规则变化，需要重新计算 RDS |

### 为什么可以这样优化

1. **PushContext 计算昂贵**：需要遍历所有配置、计算可见性、合并策略等
2. **Endpoint 变化频繁**：Pod 扩缩容、健康检查失败等场景高频触发
3. **EDS 数据独立**：Endpoint IP 列表不依赖复杂配置逻辑，只需要 Service 定义（从 PushContext 读取，但不会改变）和 Endpoint 列表（从 ServiceRegistry 直接获取）
