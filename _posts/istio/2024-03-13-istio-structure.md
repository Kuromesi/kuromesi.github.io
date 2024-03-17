---
title: Istio 基础
date: 2024-03-13 19:13:06 +0800
categories: [Cloud Native, Istio]
tags: [istio]
author: kuromesi
---

![Istio架构](/images/istio-ports-components.webp)

## Istio 组件
Istio 是一个开放源代码的服务网格，它为微服务提供了网络层的抽象，以便在云原生应用中管理服务间的通信、监控、安全等方面。Istio 的架构设计包含了一系列的关键组件，它们协同工作以提供其功能。截至我的最后更新（2023年8月），Istio 的主要组件包括：
- **Envoy Proxy**：Istio 使用 Envoy 作为服务网格中的边车(sidecar)代理。Envoy 负责处理服务之间的所有入站和出站流量。它是由 Lyft 创建的一个高性能代理，能够处理HTTP/2 和 gRPC 通信。
- **Pilot**：Pilot 负责服务发现和配置代理以动态地管理流量路由规则、策略和服务间的负载均衡。Pilot 允许Istio 提供流量管理功能，如超时、重试、熔断、流量分割等。
- **Citadel**：负责安全通信的组件。Citadel 提供了密钥和证书管理，支持服务之间的强身份认证和授权。它确保所有通信都是加密的，且通过双向 TLS 进行。
- **Galley**：Galley 是 Istio 的配置验证、提取、处理和分发组件。它主要负责Istio 配置的集中管理，确保配置的有效性和一致性。
- **Mixer**：Mixer 是 Istio 的策略执行和遥测收集组件。它负责实施访问控制和收集服务网格内部的度量指标和日志。Mixer 支持可插拔的后端，允许集成各种日志和监控工具。

从Istio 1.5版本开始，Istio 项目开始对其架构进行了简化，将 Pilot、Citadel、Galley 等组件合并到了一个单一的二进制组件 istiod 中。这个变化旨在简化 Istio 的部署和操作，使得管理更加高效。

### Pilot
Pilot 分为两部分，分别为 Pilot-Agent 和 Pilot-Discovery。Pilot-Discovery 运行于 Istiod 中，Pilot-agent 与 Envoy 作为 istio-proxy 容器运行于 Sidecar 中。两者的启动见`pilot/cmd/`。

Pilot-Discovery 如前文所述，负责服务发现和配置代理。Pilot-Agent 是 Envoy 代理的助手，负责管理 Envoy 的生命周期，包括启动、配置更新和健康检查。Pilot-Agent 与 Istiod 通信，接收到最新的配置信息，并使用这些信息来动态配置 Envoy 代理。

```yaml
    # istio-proxy container
    containers:
        # ...
        image: docker.io/istio/proxyv2:1.20.3
        imagePullPolicy: IfNotPresent
        name: istio-proxy
        ports:
        - containerPort: 15090
        name: http-envoy-prom
        protocol: TCP
        readinessProbe:
        failureThreshold: 4
        httpGet:
            path: /healthz/ready
            port: 15021
            scheme: HTTP
        periodSeconds: 15
        successThreshold: 1
        timeoutSeconds: 3
```

#### Pilot 和 Pilot-Agent 工作流程示例

假设有一个简单的微服务应用，包括两个服务：Service A 和 Service B。Service A 需要调用 Service B 来完成某些操作。在 Istio 服务网格中，服务间的通信会通过各自的 Envoy 代理进行。

1. **服务注册**：当 Service A 和 Service B 启动时，它们会被 Kubernetes 服务发现机制注册。Pilot 监听 Kubernetes API，自动发现这些服务及其实例。

2. **配置 Envoy 代理**：
    - Pilot-Agent 在 Service A 和 Service B 的 Pod 中启动 Envoy 代理。
    - Pilot-Agent 向 Istiod 请求配置信息，包括服务发现信息、路由规则、负载均衡策略等。
    - Istiod（包含了 Pilot 功能）响应 Pilot-Agent 的请求，发送最新的配置数据。
    - Pilot-Agent 使用这些配置数据来配置 Envoy 代理，确保它知道如何正确路由到 Service B。

3. **服务间通信**：
    - 当 Service A 需要调用 Service B 时，它的请求首先被发送到 Service A 的 Envoy 代理。
    - 根据 Istiod 下发的路由规则，Service A 的 Envoy 代理将请求转发到 Service B 的 Envoy 代理。
    - Service B 的 Envoy 代理接收到请求，并将其转发给 Service B 本身。

4. **动态更新**：如果服务拓扑或策略发生变化（比如新增服务实例、更新路由规则等），Istiod 会直接使用 xds 自动将更新的配置推送给所有服务的 Envoy。


*以下为一段EDS更新的函数示例，最终更新在 `pilot/pkg/xds/ads.go` 的 `func (s *DiscoveryServer) Stream(stream DiscoveryStream) error` 中进行，。*

```go
// pilot/pkg/xds/eds.go
func (s *DiscoveryServer) EDSUpdate(shard model.ShardKey, serviceName string, namespace string,
	istioEndpoints []*model.IstioEndpoint,
) {
	inboundEDSUpdates.Increment()
	// Update the endpoint shards
	pushType := s.Env.EndpointIndex.UpdateServiceEndpoints(shard, serviceName, namespace, istioEndpoints)
	if pushType == model.IncrementalPush || pushType == model.FullPush {
		// Trigger a push
		s.ConfigUpdate(&model.PushRequest{
			Full:           pushType == model.FullPush,
			ConfigsUpdated: sets.New(model.ConfigKey{Kind: kind.ServiceEntry, Name: serviceName, Namespace: namespace}),
			Reason:         model.NewReasonStats(model.EndpointUpdate),
		})
	}
}
```

## Istio 端口
### Istiod 中的端口
Istiod 中的端口相对比较少且功能单一：

- 9876：ControlZ 用户界面，暴露 istiod 的进程信息
- 8080：istiod 调试端口，通过该端口可以查询网格的配置和状态信息
- 15010：暴露 xDS API 和颁发纯文本证书
- 15012：功能同 15010 端口，但使用 TLS 通信
- 15014：暴露控制平面的指标给 Prometheus
- 15017：Sidecar 注入和配置校验端口

### Sidecar 中的端口
从上文中，我们看到 sidecar 中有众多端口：

- 15000：Envoy 管理接口 ，你可以用它来查询和修改 Envoy 代理的的配置，详情请参考 Envoy 文档 。
- 15001：用于处理出站流量。**(App->Envoy->External)**
- 15004：调试端口。
- 15006：用于处理入站流量。**(External->Envoy->App)**
- 15020：汇总统计数据，对 Envoy 和 DNS 代理进行健康检查，调试 pilot-agent 进程。
- 15021：用于 sidecar 健康检查，以判断已注入 Pod 是否准备好接收流量。我们在该端口的 /healthz/ready 路径上设置了就绪探针，Istio 把 sidecar 的就绪检测交给了 kubelet，最大化利用 Kubernetes 平台自身的功能。envoy 进程将健康检查路由到 pilot-agent 进程的 15020 端口，实际的健康检查将发生在那里。
- 15053：本地 DNS 代理，用于解析 Kubernetes DNS 解析不了的集群内部域名的场景。
- 15090：Envoy Prometheus 查询端口，pilot-agent 将通过此端口收集统计信息。

以上端口可以分为以下几类：

- 负责进程间通信，例如 15001、15006、15053
- 负责健康检查和信息统计，例如 150021、15090
- 调试：15000、15004

## Sidecar 注入
注入 Sidecar的时候会在生成pod的时候附加上两个容器：istio-init、istio-proxy。istio-init这个容器从名字上看也可以知道它属于k8s中的Init Containers，主要用于设置iptables规则，让出入流量都转由 Sidecar 进行处理。istio-proxy是基于Envoy实现的一个网络代理容器，是真正的Sidecar，应用的流量会被重定向进入或流出Sidecar。

我们在使用Sidecar自动注入的时候只需要给对应的应用部署的命名空间打个istio-injection=enabled标签，这个命名空间中新建的任何 Pod 都会被 Istio 注入 Sidecar。

### Sidecar 注入原理
Sidecar 注入主要是依托k8s的准入控制器 Admission Controller 来实现的。准入控制器会拦截 Kubernetes API Server 收到的请求，拦截发生在认证和鉴权完成之后，对象进行持久化之前。可以定义两种类型的 Admission webhook：Validating 和 Mutating。Validating 类型的 Webhook 可以根据自定义的准入策略决定是否拒绝请求；Mutating 类型的 Webhook 可以根据自定义配置来对请求进行编辑。

![](images/kubernetes-webhook.png)

istio 注入源码见`pkg/kube/inject/webhook.go`。

```go
// pkg/kube/inject/webhook.go
func NewWebhook(p WebhookParameters) (*Webhook, error) {}

func (wh *Webhook) inject(ar *kube.AdmissionReview, path string) *kube.AdmissionResponse {}

func injectPod(req InjectionParameters) ([]byte, error) {}
...
```

## 引用
> [https://jimmysong.io/blog/istio-components-and-ports/](https://jimmysong.io/blog/istio-components-and-ports/)
>
> [Sidecar自动注入如何实现的？](https://www.cnblogs.com/luozhiyun/p/13942838.html#:~:text=istio%2Dinit%E8%BF%99%E4%B8%AA%E5%AE%B9%E5%99%A8%E4%BB%8E,%E5%AE%9A%E5%90%91%E8%BF%9B%E5%85%A5%E6%88%96%E6%B5%81%E5%87%BASidecar%E3%80%82)