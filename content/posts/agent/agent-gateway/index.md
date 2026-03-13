---
title: "AgentGateway 简析"
date: 2026-03-13T13:00:00+08:00
draft: false
tags: [ai generated, agent gateway]
categories: [agent]
---

> **前言**：随着 AI Agent 技术的快速发展，传统的 API 网关已经无法满足 MCP（Model Context Protocol）、A2A（Agent-to-Agent）等新型工作负载的需求。本文将深入解析 AgentGateway 的架构设计、核心模块和实际应用场景，带你理解这个用 Rust 打造的高性能 AI 网关是如何工作的。

---

## 一、为什么需要 AgentGateway？

### 1.1 传统网关的局限性

在 Agentic AI 时代，我们面临着全新的 connectivity 挑战：

- **会话状态管理**：MCP/A2A 协议需要维护长连接和会话上下文，而传统 HTTP 网关是无状态的
- **双向通信**：服务器需要能够主动发起异步消息，而非传统的请求 - 响应模式
- **工具联邦**：需要将多个 MCP Server 聚合为统一的端点，并支持按客户端虚拟化
- **协议演进**：MCP 协议本身在快速发展，网关需要支持协议升级和降级

### 1.2 AgentGateway 的定位

AgentGateway 是 Linux Foundation 旗下的开源项目，专为 Agentic AI 设计的数据平面（Data Plane）。它的核心定位是：

```
AgentGateway = MCP/A2A 网关 + LLM 路由 + 企业级安全 + 可观测性
```

主要特性包括：

- ✅ **高性能**：基于 Rust 开发，针对高并发、长连接、扇出模式优化
- ✅ **安全优先**：内置 JWT 认证、RBAC 授权、防工具投毒
- ✅ **多租户**：支持多租户隔离，每个租户有独立的资源和用户
- ✅ **动态配置**：支持 xDS 协议，无需重启即可动态更新配置
- ✅ **协议无关**：支持 MCP、A2A、REST、OpenAPI 等多种协议
- ✅ **Kubernetes 原生**：内置 K8s Controller，支持 Gateway API

---

## 二、整体架构设计

### 2.1 架构概览

```
┌─────────────────────────────────────────────────────────┐
│                    Client Applications                   │
│         (Claude Desktop, OpenAI SDK, LangGraph, ...)     │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                  AgentGateway                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │   MCP       │  │    A2A      │  │      LLM        │  │
│  │  Handler    │  │   Handler   │  │     Router      │  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
│  ┌─────────────────────────────────────────────────────┐ │
│  │              Policy Engine (CEL)                    │ │
│  │  (AuthZ, Rate Limit, Transform, Observability)      │ │
│  └─────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────┐ │
│  │              Configuration Layer                    │ │
│  │    (Static | Local File Watch | xDS Remote)         │ │
│  └─────────────────────────────────────────────────────┘ │
└────────────────────┬────────────────────────────────────┘
                     │
         ┌───────────┼───────────┐
         ▼           ▼           ▼
    ┌────────┐  ┌────────┐  ┌─────────┐
    │  MCP   │  │  A2A   │  │   LLM   │
    │ Server │  │ Agent  │  │ Provider│
    └────────┘  └────────┘  └─────────┘
```

### 2.2 核心设计哲学

AgentGateway 的架构设计遵循几个关键原则：

#### 原则 1：配置 API 的直接映射

```
用户 API → XDS 资源 → 内部表示 (IR)
```

传统的 Envoy 网关在配置更新时存在"扇出"问题：修改一个路由可能需要更新所有 Cluster，导致数 MB 的配置需要分发给每个 Proxy。

AgentGateway 采用**一对一映射**：
- 一个 `HTTPRoute` 规则 → 一个 `Route` 资源（而非所有路由的列表）
- 一个 `Pod` → 一个 `Workload`（而非所有 Endpoint 的列表）
- Policy 保持原样引用，在运行时合并

这种设计大幅减少了配置更新的复杂度。

#### 原则 2：按需付费的性能优化

通过 CEL（Common Expression Language）实现动态字段追踪：

```rust
// 配置示例：定义日志字段
logging:
  fields:
    user_agent: 'request.headers["user-agent"]'
    tool_name: 'mcp.tool.name'
```

系统会在配置解析时提取表达式依赖的变量，仅在需要时保留相关数据（如 request body），避免不必要的内存开销。

---

## 三、核心模块解析

### 3.1 项目结构

```
agentgateway/
├── crates/
│   ├── agentgateway/       # 核心网关实现
│   ├── agentgateway-app/   # 应用程序入口
│   ├── core/               # 核心工具库
│   ├── xds/                # xDS 协议实现
│   ├── hbone/              # HBONE 协议
│   ├── celx/               # CEL 扩展
│   └── xtask/              # 构建任务
├── architecture/           # 架构文档
├── examples/               # 示例配置
└── schema/                 # CEL 变量/函数文档
```

### 3.2 模块详解

#### 模块 1：MCP 处理模块 (`src/mcp/`)

MCP 模块是 AgentGateway 的核心功能之一，负责处理 Model Context Protocol 的所有方面：

```
src/mcp/
├── handler.rs          # 请求处理逻辑
├── router.rs           # 路由分发
├── session.rs          # 会话管理
├── rbac.rs             # 基于角色的访问控制
├── auth.rs             # 认证处理
├── sse.rs              # Server-Sent Events 支持
├── streamablehttp.rs   # 流式 HTTP 传输
└── upstream/           # 上游服务器连接
```

**关键功能**：
- **多目标聚合**：将多个 MCP Server 聚合成一个统一的端点
- **工具虚拟化**：为不同客户端暴露不同的工具集合
- **会话管理**：维护长连接的会话上下文
- **协议适配**：支持 SSE 和 Streamable HTTP 两种传输方式

**配置示例**（多路复用）：

```yaml
binds:
- port: 3000
  listeners:
  - routes:
    - backends:
      - mcp:
          targets:
          - name: time
            stdio:
              cmd: uvx
              args: ["mcp-server-time"]
          - name: everything
            stdio:
              cmd: npx
              args: ["@modelcontextprotocol/server-everything"]
```

客户端会看到所有工具被聚合在一起，工具名自动添加前缀避免冲突：`time_get_current_time`、`everything_echo`。

#### 模块 2：A2A 模块 (`src/a2a/`)

A2A（Agent-to-Agent）模块处理 Agent 之间的通信：

```rust
// A2A 配置示例
policies:
  a2a: {}  # 标记此路由为 A2A 流量
backends:
- host: localhost:9999
```

**核心特性**：
- 支持长运行任务的会话管理
- 处理任务状态转移和结果返回
- 支持 Agent 间的协作和任务分发

#### 模块 3：LLM 路由模块 (`src/llm/`)

LLM 模块提供对各大 LLM 提供商的统一接口：

```
src/llm/
├── openai.rs           # OpenAI 兼容 API
├── anthropic.rs        # Anthropic Claude API
├── bedrock.rs          # AWS Bedrock
├── gemini.rs           # Google Gemini
├── azureopenai.rs      # Azure OpenAI
├── vertex.rs           # Google Vertex AI
├── policy/             # LLM 策略
└── types/              # 类型定义
```

**设计亮点**：采用"透传"（passthrough）解析策略：

```rust
#[derive(Serialize, Deserialize)]
pub struct ChatCompletionRequest {
    pub model: String,
    pub messages: Vec<Message>,
    // 其他未知字段存储在 rest 中
    #[serde(flatten, default)]
    pub rest: serde_json::Value,
}
```

这样做的好处：
- 新字段自动兼容，无需修改类型定义
- 跨提供商转换时保留完整信息
- 支持内部 typed 模式进行精确转换

#### 模块 4：CEL 引擎 (`src/cel/`)

CEL（Common Expression Language）是 AgentGateway 的策略引擎核心：

```
src/cel/
├── context.rs          # 执行上下文
├── functions.rs        # 自定义函数
├── variables.rs        # 变量定义
└── tests.rs            # 测试用例
```

**应用场景**：

1. **授权策略**：
```yaml
policies:
  mcpAuthorization:
    rules:
    - 'mcp.tool.name == "echo"'  # 允许所有人调用 echo
    - 'jwt.sub == "test-user" && mcp.tool.name == "add"'  # 仅 test-user 可调用 add
```

2. **日志字段**：
```yaml
logging:
  fields:
    user_agent: 'request.headers["user-agent"]'
    tool_name: 'mcp.tool.name'
    user_id: 'jwt.sub'
```

3. **速率限制**：
```yaml
rateLimit:
  requests:
    count: 100
    window: 1m
    key: 'jwt.sub'  # 按用户限流
```

**性能优化**：
- 配置变更时预解析表达式
- 动态追踪变量依赖
- 仅保留需要的请求数据

#### 模块 5：配置管理 (`src/config.rs`)

AgentGateway 支持三层配置：

```rust
// 1. 静态配置 (Static Configuration)
// 通过环境变量或 YAML/JSON 文件设置
// 用于全局设置：日志、端口等

// 2. 本地配置 (Local Configuration)
// 通过文件监控动态重载
// 定义后端、路由、策略等

// 3. XDS 配置 (XDS Configuration)
// 远程控制平面推送配置
// 使用自定义资源类型（非 Envoy 类型）
```

**配置热更新流程**：

```
文件变更 → 监控触发 → 解析验证 → 生成 IR → 原子替换 → 新请求生效
```

#### 模块 6：可观测性 (`src/telemetry/`)

```
src/telemetry/
├── metrics.rs          # Prometheus 指标
├── trc.rs              # 分布式追踪
└── logging.rs          # 结构化日志
```

**支持的输出**：
- Prometheus 指标
- OpenTelemetry Tracing
- OpenTelemetry Logs
- JSON 结构化日志

**示例配置**：

```yaml
telemetry:
  logging:
    format: json
    level: info
  tracing:
    providers:
    - name: otel
      otel:
        endpoint: http://otel-collector:4317
    sampling: 1.0
  metrics:
    prometheus:
      addr: 0.0.0.0:15020
```

---

## 四、实战示例

### 示例 1：基础 MCP 代理

最简单的使用场景：代理单个 MCP Server

**配置文件** (`examples/basic/config.yaml`)：

```yaml
binds:
- port: 3000
  listeners:
  - routes:
    - policies:
        cors:
          allowOrigins: ["*"]
          allowHeaders:
          - mcp-protocol-version
          - content-type
          - cache-control
          exposeHeaders:
          - "Mcp-Session-Id"
      backends:
      - mcp:
          targets:
          - name: everything
            stdio:
              cmd: npx
              args: ["@modelcontextprotocol/server-everything"]
```

**启动命令**：
```bash
cargo run -- -f examples/basic/config.yaml
```

**测试方法**：
```bash
# 使用 MCP Inspector
npx @modelcontextprotocol/inspector
# 访问 http://localhost:3000/sse 或 http://localhost:3000/mcp
```

### 示例 2：JWT 认证 + RBAC 授权

企业级安全配置示例：

```yaml
binds:
- port: 3000
  listeners:
  - routes:
    - policies:
        cors:
          allowOrigins: ["*"]
          allowHeaders: ["*"]
          exposeHeaders: ["Mcp-Session-Id"]
        # JWT 认证
        jwtAuth:
          issuer: agentgateway.dev
          audiences: [test.agentgateway.dev]
          jwks:
            file: ./manifests/jwt/pub-key
        # RBAC 授权
        mcpAuthorization:
          rules:
          - 'mcp.tool.name == "echo"'
          - 'jwt.sub == "test-user" && mcp.tool.name == "add"'
          - 'mcp.tool.name == "printEnv" && jwt.nested.key == "value"'
      backends:
      - mcp:
          targets:
          - name: mcp2
            mcp:
              host: http://localhost:3001/mcp
```

**授权规则说明**：
- 规则 1：任何人都可以调用 `echo` 工具
- 规则 2：只有 `sub=test-user` 的用户可以调用 `add` 工具
- 规则 3：只有 `nested.key=value` 的用户可以调用 `printEnv` 工具

### 示例 3：LLM 路由转换

将 OpenAI 格式请求转换为其他提供商：

```yaml
binds:
- port: 3000
  listeners:
  - routes:
    - match:
        path: /v1/chat/completions
      backends:
      - llm:
          provider: anthropic
          endpoint: https://api.anthropic.com/v1/messages
          auth:
            secret:
              key: ANTHROPIC_API_KEY
```

### 示例 4：A2A Agent 路由

```yaml
binds:
- port: 3000
  listeners:
  - routes:
    - policies:
        cors:
          allowOrigins: ['*']
          allowHeaders: [content-type, cache-control]
        # 标记为 A2A 流量
        a2a: {}
      backends:
      - host: localhost:9999
```

---

## 五、关键技术亮点

### 5.1 Rust 性能优势

AgentGateway 选择 Rust 的原因：

| 特性 | 收益 |
|------|------|
| 零成本抽象 | 无运行时开销 |
| 内存安全 | 无 GC 停顿 |
| 并发模型 | Tokio 异步运行时 |
| 类型系统 | 编译期错误检查 |

**性能优化技术**：
- 使用 `bytes::Bytes` 避免不必要的内存拷贝
- `Arc` 共享状态减少克隆
- Tokio 零拷贝网络 IO
- Jemalloc 内存分配器（可选）

### 5.2 xDS 协议实现

AgentGateway 使用 xDS 协议但不依赖 Envoy 类型：

```protobuf
// 自定义资源类型 (crates/agentgateway/proto/resource.proto)
message Route {
  string name = 1;
  ListenerTarget target = 2;
  repeated Backend backends = 3;
  repeated Policy policies = 4;
}

message Workload {
  string name = 1;
  string address = 2;
  map<string, string> labels = 3;
}
```

**优势**：
- 资源粒度与用户 API 一致
- 增量更新更高效
- 无需复杂的转换逻辑

### 5.3 会话状态管理

MCP/A2A 需要维护会话状态：

```rust
pub struct Session {
    id: SessionId,
    context: SessionContext,
    created_at: Instant,
    last_activity: Instant,
}

// 会话存储在内存或外部存储中
pub trait SessionStore: Send + Sync {
    async fn get(&self, id: &SessionId) -> Option<Session>;
    async fn set(&self, session: Session);
    async fn delete(&self, id: &SessionId);
}
```

**会话管理策略**：
- 基于 `Mcp-Session-Id` 头识别会话
- 支持会话超时和清理
- 可选的外部存储后端（Redis 等）

---

## 六、部署与运维

### 6.1 部署方式

**独立部署**：
```bash
# 使用配置文件启动
agentgateway -f config.yaml

# 使用环境变量
AGENTGATEWAY_CONFIG_FILE=config.yaml agentgateway
```

**Kubernetes 部署**：
```yaml
apiVersion: gateway.agentgateway.dev/v1
kind: Gateway
metadata:
  name: agentgateway
spec:
  gatewayClassName: agentgateway
  listeners:
  - name: mcp
    port: 3000
    protocol: HTTP
```

### 6.2 监控指标

**关键指标**：
```
# MCP 相关
agentgateway_mcp_requests_total{tool,server}
agentgateway_mcp_request_duration_seconds{tool,server}
agentgateway_mcp_sessions_active

# LLM 相关
agentgateway_llm_requests_total{provider,model}
agentgateway_llm_tokens_total{provider,type}

# 通用
agentgateway_http_requests_total{route,backend}
agentgateway_http_request_duration_seconds{route,backend}
```

### 6.3 日志示例

```json
{
  "timestamp": "2025-03-13T10:30:00Z",
  "level": "INFO",
  "target": "agentgateway::mcp::handler",
  "message": "MCP tool call",
  "tool": "echo",
  "server": "everything",
  "user": "test-user",
  "duration_ms": 15
}
```

---

## 七、与其他网关对比

| 特性 | Envoy | Kong | AgentGateway |
|------|-------|------|--------------|
| 语言 | C++ | Lua/Go | Rust |
| MCP 支持 | ❌ | ❌ | ✅ |
| A2A 支持 | ❌ | ❌ | ✅ |
| 会话感知 | ❌ | ❌ | ✅ |
| LLM 路由 | 基础 | 插件 | 原生 |
| xDS 协议 | ✅ | ❌ | ✅ (自定义类型) |
| 配置热更新 | ✅ | ✅ | ✅ |
| 多租户 | 有限 | 企业版 | 开源支持 |

---

## 八、未来发展方向

根据项目 Roadmap，AgentGateway 正在开发的功能：

1. **gRPC 支持**：将 OpenAPI 支持扩展到 gRPC
2. **AI 安全策略**：Prompt 注入检测、敏感信息过滤
3. **高级流量管理**：金丝雀发布、A/B 测试
4. **服务网格集成**：与 Istio、Linkerd 等集成
5. **WASM 扩展**：支持自定义 WASM 插件

---

## 九、总结

AgentGateway 代表了下一代 API 网关的发展方向：

### 核心价值

1. **专为 AI 设计**：不是传统网关的修补，而是从底层重新设计
2. **性能与安全并重**：Rust 保证性能，内置企业级安全
3. **开放标准**：支持 MCP、A2A、Gateway API 等开放标准
4. **云原生友好**：Kubernetes 原生，支持动态配置

### 适用场景

- ✅ 需要聚合多个 MCP Server
- ✅ 需要 Agent 间通信（A2A）
- ✅ 需要统一 LLM API 接口
- ✅ 需要企业级安全和审计
- ✅ 需要多租户隔离

### 快速开始

```bash
# 克隆项目
git clone https://github.com/agentgateway/agentgateway
cd agentgateway

# 运行基础示例
cargo run -- -f examples/basic/config.yaml

# 使用 MCP Inspector 测试
npx @modelcontextprotocol/inspector
```

---

## 参考资料

- **项目仓库**: https://github.com/agentgateway/agentgateway
- **官方文档**: https://agentgateway.dev/docs/
- **Discord 社区**: https://discord.gg/BdJpzaPjHv
- **MCP 协议**: https://modelcontextprotocol.io/
- **A2A 协议**: https://github.com/a2aproject/A2A