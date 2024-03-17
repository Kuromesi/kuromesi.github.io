---
title: Istio Security
date: 2024-03-14 20:41:06 +0800
categories: [Cloud Native, Istio]
tags: [istio]
author: kuromesi
---

## Istio 安全架构

Istio 为微服务提供了无侵入，可插拔的安全框架。应用不需要修改代码，就可以利用 Istio 提供的双向 TLS 认证实现服务身份认证，并基于服务身份信息提供细粒度的访问控制。Istio 安全的高层架构如下图所示：
![Istio 安全架构](images/arch-sec.svg){: width="800"}

图中展示了 Istio 中的服务认证和授权两部分内容。让我们暂时忽略掉授权部分，先关注认证部分。服务认证是通过控制面和数据面一起实现的：

- **控制面**：Istiod 中实现了一个 CA（Certificate Authority，证书机构）服务器。该 CA 服务器负责为网格中的各个服务签发证书，并将证书分发给数据面的各个服务的 sidecar 代理。
- **数据面**：在网格中的服务相互之间发起 plain HTTP/TCP 通信时，和服务同一个 pod 中的 sidecar 代理会拦截服务请求，采用证书和对端服务的 sidecar 代理进行双向 TLS 认证并建立一个 TLS 连接，使用该 TLS 连接来在网络中传输数据。

## 控制面证书签发流程

![Istio 证书分发流程](images/istio-ca.svg){: width="800"}

## 为什么要通过 Pilot-agent 中转？

Istio 证书签发的过程中涉及到了三个组件：Istiod (Istio CA) —> Pilot-agent —> Enovy。为什么其他 xDS 接口都是由 Istiod 直接向 Envoy 提供，但 SDS 却要通过 Pilot-agent 进行一次中转，而不是直接由 Envoy 通过 SDS 接口从 Istiod 获取证书呢？这样做主要有两个原因。

首先，在 Istio 的证书签发流程中，由 Pilot-agent 生成私钥和 CSR，再通过 CSR 向 Istiod 中的 CA 申请证书。在整个过程中，私钥只存在于本地的 Istio-proxy 容器中。如果去掉中间 Pilot-agent 这一步，直接由 Envoy 向 Istiod 申请证书，则需要由 Istiod 生成私钥，并将私钥和证书一起通过网络返回给 Envoy，这将大大增加私钥泄露的风险。

另一方面，通过 Pilot-agent 来提供 SDS 服务，由 Pilot-agent 生成标准的 CSR 证书签名请求，可以很容易地对接不同的 CA 服务器，方便 Istio 和其他证书机构进行集成。

## 控制面身份认证

要通过服务证书来实现网格中服务的身份认证，必须首先确保服务从控制面获取自身证书的流程是安全的。Istio 通过 Istiod 和 Pilog-agent 之间的 gRPC 通道传递 CSR 和证书，因此在这两个组件进行通信时，双方需要先验证对方的身份，以避免恶意第三方伪造 CSR 请求或者假冒 Istiod CA 服务器。在目前的版本中 (Istio1.6)，Pilot-agent 和 Istiod 分布采用了不同的认证方式。

- Istiod 身份认证
    - Istiod 采用其内置的 CA 服务器为自身签发一个服务器证书（图 2 中的 Istiod certificate），并采用该服务器证书对外提供基于 TLS 的 gPRC 服务。
    - Istiod 调用 Kube-apiserver 生成一个 ConfigMap，在该 ConfigMap 中放入了 Istiod 的 CA 根证书 (图 2 中的 istio-ca-root-cert)。
    - 该 ConfigMap 被 Mount 到 Istio-proxy 容器中，被 Pilot-agent 用于验证 Istiod 的服务器证书。
    - 在 Pilot-agent 和 Istiod 建立 gRPC 连接时，Pilot-agent 采用标准的 TLS 服务器认证流程对 Istiod 的服务器证书进行认证。
- Pilot-agent 身份认证
    - 在 Kubernetes 中可以为每一个 pod 关联一个 Service Account，以表明该 pod 中运行的服务的身份信息。例如 bookinfo 中 reviews 服务的 service accout 是“bookinfo-reviews” 。
    - Kubernetes 会为该 service account 生成一个 jwt token，并将该 token 通过 secret 加载到 pod 中的一个文件。
    - Pilot-agent 在向 Istiod 发送 CSR 时，将其所在 pod 的 service account token 也随请求发送给 Istiod。
    - Istiod 调用 Kube-apiserver 接口验证请求中附带的 service account token，以确认请求证书的服务身份是否合法。

备注：除了 Kubernetes 之外，Istio 也支持虚机部署，在虚机部署的场景下，由于没有 service account，Pilot-agent 和 Pilotd 之间的身份认证方式有所不同。由于 Istio 的主要使用场景还是 Kubernetes，本文只分析 Kubernetes 部署场景。

![身份供应流程](images/id-prov.svg){: width="800"}

## CA 具体认证流程

![CA 认证流程](images/1169376-20191009111543085-161187219.png)

整个过程如下：
1. 服务方 S 向第三方机构CA提交公钥、组织信息、个人信息(域名)等信息并申请认证;**（不交私钥）**
2. CA 通过线上、线下等多种手段验证申请者提供信息的真实性，如组织是否存在、企业是否合法，是否拥有域名的所有权等;
3. 如信息审核通过，CA 会向申请者签发认证文件-证书。
证书包含以下信息：**申请者公钥、申请者的组织信息和个人信息、签发机构 CA 的信息、有效时间、证书序列号等信息的明文，同时包含一个签名;**

签名的产生算法：首先，使用散列函数计算公开的明文信息的信息摘要，然后，采用 CA 的私钥对信息摘要进行加密，密文即签名;
4. 客户端 C 向服务器 S 发出请求时，S 返回证书文件;
5. 客户端 C读取证书中的相关的明文信息，采用相同的散列函数计算得到信息摘要，然后，利用对应CA的公钥解密签名数据，对比证书的信息摘要，如果一致，则可以确认证书的合法性，即公钥合法;
6. 客户端然后验证证书相关的域名信息、有效时间等信息;
7. 客户端会内置信任 CA 的证书信息（包含公钥），如果 CA 不被信任，则找不到对应 CA 的证书，证书也会被判定非法。

在这个过程注意几点：
1. 申请证书不需要提供私钥，确保私钥永远只能服务器掌握;
2. 证书的合法性仍然依赖于非对称加密算法，证书主要是增加了服务器信息以及签名;
3. 内置 CA 对应的证书称为根证书，颁发者和使用者相同，自己为自己签名，即自签名证书（为什么说"部署自签SSL证书非常不安全"）
4. 证书=公钥（服务方生成密码对中的公钥）+ 申请者与颁发者信息 + 签名（用 CA 机构生成的密码对的私钥进行签名）;

即便有人截取服务器 A 证书，再发给客户端，想冒充服务器A，也无法实现。因为证书和url的域名是绑定的。

## Istio 认证

![认证过程](images/authn.svg){: width="800"}

*源码见`pilot/pkg/security/authn`*

Istio 提供两种类型的认证：

- 对等认证：用于服务到服务的认证，以验证建立连接的客户端。 Istio 提供双向 TLS 作为传输认证的全栈解决方案，无需更改服务代码就可以启用它。这个解决方案：

    - 为每个服务提供代表其角色的强大身份，以实现跨集群和云的互操作性。
    - 确保服务间通信的安全。
    - 提供密钥管理系统，以自动进行密钥和证书的生成、分发和轮换。
- 请求认证：用于终端用户认证，以验证附加到请求的凭据。 Istio 使用 JSON Web Token（JWT）验证启用请求级认证， 并使用自定义认证实现或任何 OpenID Connect 的认证实现（例如下面列举的）来简化的开发人员体验。

    - ORY Hydra
    - Keycloak
    - Auth0
    - Firebase Auth
    - Google Auth

在所有情况下，Istio 都通过自定义 Kubernetes API 将认证策略存储在 Istio config store。 Istiod 使每个代理保持最新状态， 并在适当时提供密钥。此外，Istio 的认证机制支持宽容模式（permissive mode）， 以帮助您在强制实施前了解策略更改将如何影响您的安全状况。

## Istio 授权

![授权架构](images/authz.svg){: width="800"}

授权策略对服务器端 Envoy 代理的入站流量实施访问控制。 每个 Envoy 代理都运行一个授权引擎，该引擎在运行时授权请求。 当请求到达代理时，授权引擎根据当前授权策略评估请求上下文， 并返回授权结果 ALLOW 或 DENY。 运维人员使用 .yaml 文件指定 Istio 授权策略。

*源码见`pilot/pkg/security/authz`*

Istio 的授权功能为网格中的工作负载提供网格、 命名空间和工作负载级别的访问控制。这种控制层级提供了以下优点：

- 工作负载到工作负载以及最终用户到工作负载的授权。
- 一个简单的 API：它包括一个单独的并且很容易使用和维护的 AuthorizationPolicy CRD。
- 灵活的语义：运维人员可以在 Istio 属性上定义自定义条件，并使用 DENY 和 ALLOW 动作。
- 高性能：Istio 授权是在 Envoy 本地强制执行的。
- 高兼容性：原生支持 HTTP、HTTPS 和 HTTP2，以及任意普通 TCP 协议。


## 引用

> [https://cloudnative.to/blog/istio-certificate/](https://cloudnative.to/blog/istio-certificate/)
> 
> [https://www.cnblogs.com/xdyixia/p/11610102.html](https://www.cnblogs.com/xdyixia/p/11610102.html)
>
> [https://istio.io/latest/zh/docs/concepts/security](https://istio.io/latest/zh/docs/concepts/security)