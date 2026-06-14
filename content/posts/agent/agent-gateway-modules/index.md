---
title: "AgentGateway 模块总览"
date: 2026-06-14T17:10:00+08:00
draft: false
tags: [ai generated, agent gateway]
categories: [agent]
---

> **前言**：本文是 AgentGateway 系列的第三篇，提供完整的模块级参考手册。覆盖 11 个 Rust crate 的文件级职责说明、Go 控制面 Plugin 架构、UI 页面组成、配置系统三种模式，以及 LLM/MCP 请求的完整数据路径。适合作为源码阅读的导航地图使用。

---

## 项目概况

AgentGateway 是 Linux Foundation 旗下的开源 AI-native 协议代理，专为 MCP、A2A 和 LLM 工作负载设计。采用 Rust 数据面 + Go 控制面的双语言架构，源自 Istio ztunnel 项目。

```
agentgateway/
├── crates/              ← Rust 数据面（11 个 crate）
├── controller/          ← Go 控制面（K8s controller）
├── ui/                  ← Next.js 管理界面
├── examples/            ← 配置示例
├── schema/              ← JSON Schema + 配置文档
└── architecture/        ← 设计文档 & EP 提案
```

---

## 一、Rust Crate 依赖图

```
agentgateway-app (binary entry)
  └── agentgateway (main library)
        ├── agent-core         基础设施层
        ├── agent-celx         CEL 策略引擎
        │     └── cel-fork     cel-rust fork（零拷贝字段访问）
        ├── agent-hbone        HBONE H2 隧道
        │     └── agent-core
        ├── agent-xds          xDS Delta 客户端
        │     ├── agent-core
        │     └── protos
        ├── agent-pool         HTTP/2 连接池
        ├── protos             Protobuf 定义
        └── htpasswd-verify-fork  Basic Auth 密码验证
```

---

## 二、核心 Crate 详解

### 2.1 `agentgateway-app`（二进制入口）

| 路径 | 说明 |
|------|------|
| `crates/agentgateway-app/` | CLI 参数解析、信号处理、启动 `Gateway::run()` |

职责：解析命令行参数、初始化 telemetry、加载配置源（Static/Local/xDS）、启动主循环。

---

### 2.2 `agentgateway`（主库 crate）

这是项目的核心业务逻辑所在，内含以下子模块：

#### `src/proxy/` — 代理引擎

| 文件 | 职责 |
|------|------|
| `gateway.rs` | **Gateway struct**：管理 bind 生命周期（start/stop/drain），支持 Thread-Per-Core 模式（core_affinity + per-core tokio runtime + 独立连接池） |
| `httpproxy.rs` | **HTTP 代理主路径**：`proxy()` → `proxy_internal()` → route selection → policy chain → `make_backend_call()`。当 backend 有 `llm_provider` 时进入 LLM 路径 |
| `tcpproxy.rs` | TCP 层代理（L4 透传） |
| `request_builder.rs` | 构建上游请求（header 处理、host 重写） |
| `proxy_protocol.rs` | PROXY Protocol v1/v2 解析 |
| `dtrace.rs` | DTrace/USDT 探针定义 |

#### `src/llm/` — LLM Gateway 模块

| 文件/目录 | 职责 |
|-----------|------|
| `mod.rs` | **LLM 主管线**：`AIBackend`（P2C 负载均衡）、`NamedAIProvider`、`AIProvider` enum、`process_request()`/`setup_request()`/`process_response()`/`process_streaming()` |
| `openai.rs` | OpenAI provider 定义：默认 host/path、认证方式（Bearer token）、streaming 处理 |
| `anthropic.rs` | Anthropic provider：`x-api-key` 认证、`/v1/messages` 路径、stream event 解析 |
| `azure.rs` | Azure OpenAI：`api-key` header、deployment 路径重写 |
| `bedrock.rs` | AWS Bedrock：SigV4 签名、Converse API、EventStream 解码 |
| `gemini.rs` | Google Gemini：API key URL 参数 |
| `vertex.rs` | Google Vertex AI：GCP OAuth2 access token、project/region 路径 |
| `copilot.rs` | GitHub Copilot provider |
| `custom.rs` | Custom provider：native_format 偏好表、最少转换原则 |
| **`conversion/`** | **格式转换子模块** |
| ├ `completions.rs` | Messages → Completions（Anthropic 入 → OpenAI 出），含完整 StreamState 状态机 |
| ├ `messages.rs` | Completions → Messages（OpenAI 入 → Anthropic 出），tool_index_map 映射 |
| ├ `bedrock.rs` | Completions/Messages → Bedrock Converse（3 个 translate_stream） |
| ├ `openai_compat.rs` | Gemini/Vertex OpenAI-compat 流式修正 |
| ├ `responses.rs` | OpenAI Responses API 透传 |
| └ `vertex.rs` | Vertex AI 特有的请求/响应格式适配 |
| **`types/`** | **LLM 请求/响应类型定义** |
| ├ `completions.rs` | OpenAI Chat Completions wire format（Request/Response/Usage/StreamResponse） |
| ├ `messages.rs` | Anthropic Messages wire format（Request/Response/ContentBlock/StreamEvent） |
| ├ `responses.rs` | OpenAI Responses API format |
| ├ `detect.rs` | Detect/Passthrough 模式（Raw/Json，只提取 model+streaming 不修改 body） |
| ├ `embeddings.rs` | Embeddings 请求/响应类型 |
| ├ `rerank.rs` | Rerank 请求/响应类型 |
| ├ `count_tokens.rs` | Anthropic token counting 请求 |
| ├ `bedrock.rs` | Bedrock Converse wire types |
| └ `vertex.rs` | Vertex AI wire types |
| **`policy/`** | **LLM 策略子模块** |
| ├ `mod.rs` | `PromptGuard`/`RequestGuard`/`RequestGuardKind` enum、SortedRoutes（longest-first）、model alias 通配符、prompt enrichment |
| ├ `webhook.rs` | Webhook guardrail 协议（GuardrailsPromptRequest/RequestAction/ResponseAction） |
| ├ `moderation.rs` | OpenAI Moderation API 集成 |
| ├ `bedrock_guardrails.rs` | AWS Bedrock ApplyGuardrail API |
| ├ `google_model_armor.rs` | GCP Model Armor SanitizeUserPrompt |
| ├ `azure_content_safety.rs` | Azure Content Safety AnalyzeText + DetectJailbreak |
| └ `pii/` | 内置 PII 正则模式（SSN/CreditCard/PhoneNumber/Email/CaSin） |

#### `src/mcp/` — MCP Gateway 模块

| 文件/目录 | 职责 |
|-----------|------|
| `mod.rs` | MCP 模块入口、`MCPBackend` 定义 |
| `session.rs` | **会话管理**：30min idle TTL、stateless 模式、session store |
| `handler.rs` | MCP 请求分发、tool/resource/prompt 方法路由 |
| `router.rs` | **Relay 路由**：多上游 MCP Server 联邦聚合，按 tool name 分发 |
| `rbac.rs` | **Tool 级 RBAC**：per-consumer 工具可见性控制，未授权 tool 从 list 中隐藏 |
| `auth.rs` | MCP 会话认证（JWT/API Key） |
| `sse.rs` | SSE transport（legacy MCP transport） |
| `streamablehttp.rs` | Streamable HTTP transport（新 MCP transport） |
| `mergestream.rs` | 多上游 tool list 合并流 |
| **`guardrails/`** | MCP guardrails |
| ├ `client.rs` | Guardrail 客户端调用 |
| ├ `methods.rs` | 各 MCP 方法的 guardrail 挂载点 |
| ├ `mod.rs` | FailOpen/FailClosed 模式定义 |
| └ `phase.rs` | 请求/响应阶段区分 |
| **`upstream/`** | MCP 上游连接 |
| ├ `client.rs` | MCP 上游客户端（连接复用） |
| ├ `mod.rs` | 上游管理 |
| ├ `sse.rs` | SSE 上游 transport |
| ├ `stdio.rs` | Stdio 上游 transport（子进程模式） |
| ├ `streamablehttp.rs` | Streamable HTTP 上游 |
| └ `openapi/` | OpenAPI → MCP 转换（REST→MCP 桥接） |

#### `src/a2a/` — A2A Gateway 模块

| 文件 | 职责 |
|------|------|
| `mod.rs` | Agent-to-Agent 协议代理、任务路由、agent card 发现 |
| `tests.rs` | A2A 协议测试 |

#### `src/http/` — HTTP 中间件层

| 文件 | 职责 |
|------|------|
| `mod.rs` | HTTP 层公共类型（Body、Response、StatusCode） |
| `route.rs` | Route 匹配（PathMatch: Exact/PathPrefix/Regex/Invalid，段边界语义） |
| `filters.rs` | RequestRedirect、URLRewrite 实现 |
| `cors.rs` | CORS 跨域处理 |
| `csrf.rs` | CSRF 防护 |
| `jwt.rs` | JWT 验证（JWKS 获取/缓存/Claims 提取） |
| `oauth.rs` / `oidc/` | OAuth2/OIDC 认证流程 |
| `basicauth.rs` | Basic Auth（htpasswd 格式） |
| `apikey.rs` | API Key 认证 |
| `authorization.rs` | CEL 表达式授权（`request.auth.claims.sub == "admin"`） |
| `ext_authz.rs` | 外部授权服务（gRPC/HTTP ExtAuthZ 协议） |
| `ext_proc.rs` / `ext_proc/` | 外部处理器（ExtProc，Envoy 兼容） |
| `localratelimit.rs` | Token bucket 本地限流（支持 Token-based） |
| `remoteratelimit.rs` | 远程限流服务（RLS 协议） |
| `timeout.rs` | 请求超时配置 |
| `retry/` | 重试策略 |
| `buffer.rs` / `bufferbody.rs` | 请求 body 缓冲（guardrails 需要完整 body） |
| `compression/` | 响应压缩/解压（gzip/br/deflate） |
| `outlierdetection.rs` | 异常点检测（被动健康检查） |
| `sessionpersistence.rs` | 会话持久化（cookie/header affinity） |
| `transformation_cel.rs` | CEL 表达式 request/response 变换 |
| `health.rs` | 健康检查端点 |
| `peekbody.rs` / `recordbody.rs` | Body peek/record 辅助（不消耗 body 的前瞻读取） |

#### `src/cel/` — CEL 策略引擎集成

| 文件 | 职责 |
|------|------|
| `mod.rs` | CEL Program 编译、变量依赖追踪 |
| `properties.rs` | CEL 变量属性定义（request/response/jwt/llm/mcp/source/backend） |
| `query.rs` | CEL 查询执行 |
| `types.rs` | CEL→Rust 类型映射 |
| `helpers.rs` | CEL 辅助函数注册 |

#### `src/types/` — 配置类型系统

| 文件 | 职责 |
|------|------|
| `agent.rs` | 通用 agent 类型（BackendTrafficPolicy、HeaderMatch 等） |
| `agent_xds.rs` | xDS 资源解析为内部类型 |
| `backend.rs` | Backend 定义（service/host/port） |
| `discovery.rs` | 服务发现类型 |
| `frontend.rs` | Listener/Bind 前端类型 |
| `loadbalancer.rs` | 负载均衡配置（RoundRobin/LeastConnection/P2C） |
| `local.rs` | **本地配置解析**（2000+ 行）：LocalConfig → 内部 IR 翻译，含 `apply_base_url()`、provider defaults、wildcard model matching |
| `proto.rs` | Protobuf ↔ 内部类型转换 |
| `dynamic_ca_cert.rs` | 动态 CA 证书热更新 |

#### `src/transport/` — 传输层

| 文件 | 职责 |
|------|------|
| `tls.rs` | TLS 配置/握手/SNI 路由 |
| `hbone.rs` | HBONE 隧道（HTTP/2 CONNECT） |
| `stream.rs` | 通用流抽象（TCP/TLS/HBONE 统一接口） |
| `rewind.rs` | 可回退流（支持协议嗅探后重放前几个字节） |

#### `src/client/` — 出站客户端

| 文件 | 职责 |
|------|------|
| `mod.rs` | HTTP 客户端工厂 |
| `dns.rs` | DNS 解析（trust-dns，支持 /etc/hosts） |
| `tls.rs` | 出站 TLS 配置 |
| `azure.rs` | Azure AD token 获取 |
| `connect_tunnel.rs` | HTTP CONNECT 隧道代理 |
| `hbone_tunnel.rs` | HBONE 隧道出站 |

#### `src/store/` — 配置存储

| 文件 | 职责 |
|------|------|
| `binds.rs` | Bind/Listener/Route 配置存储 |
| `discovery.rs` | 服务发现状态 |
| `policy.rs` | Policy 存储/合并 |

#### `src/control/` — 控制面通信

| 文件 | 职责 |
|------|------|
| `mod.rs` | 控制面客户端管理 |
| `caclient.rs` | CA 证书客户端（mTLS 证书轮转） |

#### `src/telemetry/` — 可观测性

| 文件 | 职责 |
|------|------|
| `mod.rs` | Telemetry 初始化 |
| `log.rs` | **RequestLog**：per-request 结构化日志（含 LLMRequest/LLMResponse 元数据、token 用量） |
| `metrics.rs` | Prometheus metrics 导出 |
| `trc.rs` | OpenTelemetry trace span 管理 |

#### `src/parse/` — 解析辅助

| 文件 | 职责 |
|------|------|
| (内含 SSE parser) | `parse::sse::json_passthrough` / `json_transform` / `json_transform_multi` — 流式 SSE 事件解析与转换 |

#### 其他

| 文件 | 职责 |
|------|------|
| `app.rs` | Application 启动编排 |
| `config.rs` | 配置源选择逻辑 |
| `state_manager.rs` | 全局状态管理（配置热更新分发） |
| `ui.rs` | 内嵌 UI 静态文件 serve |
| `management/` | 管理 API（/config、/health、/metrics） |
| `aws.rs` | AWS 通用认证（STS、credential chain） |
| `json.rs` | JSON 序列化辅助 |
| `serdes.rs` | 自定义 serde 实现 |
| `agentcore.rs` | 核心 trait 导出 |

---

### 2.3 `agent-core`（基础设施层）

| 文件 | 职责 |
|------|------|
| `strng.rs` | 零拷贝字符串（Arc-based interning） |
| `drain.rs` | Graceful shutdown drain 机制 |
| `signal.rs` | Unix/Windows 信号处理 |
| `copy.rs` | 双向流拷贝（TCP proxy 基础） |
| `metrics.rs` | Prometheus metric 注册宏 |
| `telemetry.rs` / `telemetry/` | OpenTelemetry 初始化 |
| `readiness.rs` | 就绪探针 |
| `env.rs` | 环境变量读取 |
| `version.rs` | 版本信息 |
| `arc.rs` / `bow.rs` | 自定义智能指针 |
| `durfmt.rs` | Duration 格式化 |
| `timestamp.rs` | 时间戳工具 |
| `tokio_metrics.rs` | Tokio runtime 监控 |
| `responsechannel.rs` | 异步响应通道 |

---

### 2.4 `agent-celx`（CEL 引擎）

基于 cel-rust fork（`cel-fork` crate），通过 `cel-derive` 宏实现编译时变量追踪和零拷贝字段访问。

| 文件 | 职责 |
|------|------|
| `lib.rs` | CEL 编译/求值入口 |
| `general.rs` | 通用 CEL 函数（timestamp、duration、size） |
| `strings.rs` | 字符串函数（contains、startsWith、matches） |
| `math.rs` | 数学函数 |
| `cidr.rs` | CIDR 匹配函数（IP 范围检查） |
| `flatten.rs` | 嵌套结构展平 |
| `optimize.rs` | 表达式优化（常量折叠、死代码消除） |

核心设计：策略配置加载时确定每个 CEL 表达式引用的变量集合（ContextBuilder 模式），运行时只注入被引用的上下文变量，`request.body` 等昂贵操作变成 opt-in。

---

### 2.5 `agent-xds`（xDS 客户端）

| 文件 | 职责 |
|------|------|
| `client.rs` | xDS Delta gRPC 客户端（ADS 模式） |
| `types.rs` | xDS 资源类型注册 |
| `metrics.rs` | xDS 连接/同步指标 |

实现 Envoy xDS Delta 协议（增量订阅），资源类型：Listener、Route、Cluster、Endpoint、Secret、Extension。**UP-pointing 资源模型**：子资源引用父资源 ID，而非内嵌。

---

### 2.6 `agent-hbone`（HBONE 隧道）

| 文件 | 职责 |
|------|------|
| `client.rs` | HBONE 出站（HTTP/2 CONNECT 到目标） |
| `server.rs` | HBONE 入站（接收 H2 CONNECT 创建 TCP 流） |
| `pool.rs` | H2 连接池（per-destination 复用） |

HBONE（HTTP-Based Overlay Network Encapsulation）是 Istio ambient 模式的隧道协议，AgentGateway 保留了这一能力用于 mesh 内部通信。

---

### 2.7 `agent-pool`（连接池）

| 文件/目录 | 职责 |
|-----------|------|
| `pool.rs` | HTTP/2 多路复用连接池 |
| `connect/` | 连接建立策略 |
| `rt/` | Runtime 适配 |
| `service/` | Tower Service 包装 |
| `common/` | 通用工具 |

基于 pingora-pool + 自定义 hyper-util fork，支持 H2 stream 级别的负载均衡和健康检查。

---

### 2.8 `protos`（Protobuf 定义）

| 内容 | 说明 |
|------|------|
| xDS protos | Envoy xDS API（Listener/Route/Cluster/Endpoint） |
| workload.proto | 工作负载发现 |
| resource.proto | 通用资源包装 |
| ext_mcp.proto | MCP 扩展配置 |
| ext_authz.proto | ExtAuthZ gRPC 服务 |
| ext_proc.proto | ExtProc gRPC 服务 |
| rls.proto | Rate Limit Service gRPC |

---

## 三、Go 控制面（`controller/`）

### 3.1 核心架构

Go controller 基于 controller-runtime，使用 KRT（Kubernetes Runtime Toolkit）进行资源翻译。

```
controller/
├── cmd/agctl/                ← CLI 工具（agctl）
├── cmd/agentgateway/         ← controller binary 入口
├── pkg/controller/           ← 核心 reconciler
├── pkg/syncer/               ← KRT → xDS 快照翻译
├── pkg/agentgateway/plugins/ ← Plugin 架构
├── pkg/helm/                 ← Helm chart 管理
├── pkg/deployer/             ← Gateway 部署器
├── pkg/admin/                ← 管理 API
└── pkg/metrics/              ← 指标
```

### 3.2 Plugin 架构

| Plugin | 职责 |
|--------|------|
| `traffic_plugin.go` | HTTP/TCP 路由翻译（HTTPRoute → xDS Route） |
| `inference_plugin.go` | LLM 推理扩展（Gateway API Inference Extension 兼容） |
| `a2a_plugin.go` | A2A 协议路由 |
| `backend_tls_plugin.go` | Backend TLS 策略 |
| `ai_policies.go` | AI 策略（promptGuard/modelAlias/promptCaching） |
| `backend_policies.go` | Backend 级策略合并 |
| `frontend_policies.go` | Frontend 级策略（认证/限流） |
| `credential_resolver.go` | Secret 引用解析 |
| `jwks_lookup.go` | JWKS 端点发现 |

### 3.3 CRD 资源

| CRD | 说明 |
|-----|------|
| `AgentgatewayBackend` | AI/MCP/A2A backend 定义 |
| `AgentgatewayParameters` | Gateway 参数化配置 |
| `AgentgatewayPolicy` | 附加策略（promptGuard 等） |

结合标准 Gateway API 资源（Gateway、HTTPRoute、TCPRoute）使用。

---

## 四、UI（`ui/`）

Next.js + Tailwind + shadcn/ui 构建的管理界面。

| 页面 | 功能 |
|------|------|
| `/` (page.tsx) | Dashboard 概览 |
| `/listeners` | Listener 配置管理 |
| `/routes` | Route 规则管理 |
| `/backends` | Backend 配置管理 |
| `/playground` | LLM Playground（交互式测试） |
| `/cel` | CEL 表达式调试器 |

Setup Wizard 支持引导式配置创建（Listener → Route → Backend → Policy）。

---

## 五、配置系统

三种配置源：

| 模式 | 触发方式 | 说明 |
|------|---------|------|
| Static | 启动参数 `--config` | 启动时加载一次，不热更新 |
| Local | 启动参数 `--local-config` | 文件监控，修改后自动热加载 |
| xDS | 连接到控制面 | Delta 增量推送，运行时动态更新 |

两种配置格式：

- **简写格式**（`llm:` 顶层）：适合单 listener 简单场景
- **完整格式**（`binds:` 顶层）：支持多 listener、多 route、精细策略控制

---

## 六、数据流总览

### LLM 请求路径

```
Client Request
  → TLS termination
  → Listener accept
  → Route matching (Exact > PathPrefix > Regex)
  → Policy chain (CORS→JWT→RateLimit→Transform→...)
  → AI Backend selection (P2C from priority groups)
  → process_request():
      native_format → model alias → prompt enrichment
      → prompt guard → tokenization → format conversion
  → Upstream HTTP call (with provider-specific auth)
  → process_response() / process_streaming():
      decompress → SSE parse → format back-convert
      → token extraction → AmendOnDrop report
  → Client Response
```

### MCP 请求路径

```
Client (SSE/StreamableHTTP)
  → Session lookup/create (30min TTL)
  → Auth (JWT/APIKey)
  → RBAC check (tool-level visibility)
  → Guardrails (request phase)
  → Router dispatch (tool name → upstream)
  → Upstream MCP call (SSE/Stdio/StreamableHTTP)
  → Guardrails (response phase)
  → Response relay
```

---

## 七、关键设计决策

| 决策 | 原因 |
|------|------|
| **Thread-Per-Core** | 避免跨线程同步开销，每个 core 独立 tokio runtime + 连接池 |
| **P2C 负载均衡** | 比 Round-Robin 更适应异构后端（慢节点不拖累全局） |
| **UP-pointing xDS 资源** | 子资源引用父 ID 而非内嵌，增量更新只传 diff |
| **CEL 编译时变量追踪** | 运行时只注入被引用的上下文，`request.body` 变成 opt-in |
| **AmendOnDrop RAII** | 无论流如何结束都能正确报告 token 用量给限流器 |
| **SortedRoutes longest-first** | 路径后缀匹配优先选最长（`/messages/count_tokens` > `/messages`） |
| **pathPrefix = REPLACE** | 替换而非 prepend 默认路径前缀（统一各 provider 行为） |
| **MCP FailOpen/FailClosed** | 审查服务宕机时的行为可配置，生产环境需权衡 |
