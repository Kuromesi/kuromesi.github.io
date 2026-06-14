---
title: "AgentGateway LLM 模块深度解析"
date: 2026-06-14T16:55:00+08:00
draft: false
tags: [ai generated, agent gateway, llm, rust]
categories: [agent]
---

> **前言**：本文是 AgentGateway 系列的第二篇，聚焦 LLM Gateway 模块的实现细节。我们将从"什么是 LLM 网关"的基础概念出发，逐步深入到 AgentGateway 的请求处理管线、多 Provider 格式转换、流式 SSE 状态机、Token 计数与限流修正、内容审查（Guardrails）等核心实现，带你理解一个生产级 LLM 网关的完整数据路径。

---

## 一、LLM 网关基础概念

### 1.1 为什么需要 LLM 网关

在没有 LLM 网关的世界里，每个 AI 应用都需要直接对接各种 LLM Provider：

```
App A ──→ OpenAI
App B ──→ Anthropic
App C ──→ Azure OpenAI
App D ──→ Bedrock
```

这带来几个问题：

- **格式碎片化**：OpenAI 用 Chat Completions，Anthropic 用 Messages，Bedrock 用 Converse，三套不同的请求/响应格式
- **认证分散**：每个应用都要管理各家 Provider 的 API Key、OAuth Token、AWS SigV4 签名
- **缺乏治理**：没有统一的限流、审计、内容审查入口
- **切换成本高**：想把某个 model 从 OpenAI 迁移到 Azure，需要改所有调用方代码

LLM 网关就是在应用和 Provider 之间插入一个代理层：

```
App A ─┐                    ┌──→ OpenAI
App B ─┼──→ [LLM Gateway] ──┼──→ Anthropic
App C ─┤                    ├──→ Azure OpenAI
App D ─┘                    └──→ Bedrock
```

它的核心价值：**统一入口、协议转换、策略执行、可观测性**。

### 1.2 LLM 网关的核心能力

一个完整的 LLM 网关通常需要具备以下能力：

| 能力 | 说明 |
|------|------|
| 协议转换 | 客户端用 OpenAI 格式，网关自动转成 Anthropic/Bedrock 格式发给上游 |
| 模型路由 | 按请求中的 model 名称分发到不同的 Provider |
| 负载均衡 | 多个 Provider 之间做 P2C、加权等负载均衡 |
| Token 限流 | 按 Token 用量（而非 QPS）限流，因为 LLM 请求成本差异巨大 |
| 内容审查 | 在请求/响应中检测敏感内容、注入攻击 |
| 认证鉴权 | 统一管理各 Provider 的认证凭证 |
| 可观测性 | Token 用量统计、延迟监控、First Token Latency |
| 流式处理 | 正确处理 SSE（Server-Sent Events）流式响应 |

### 1.3 LLM 请求的两大格式

当前业界有两套主流 LLM 请求格式，AgentGateway 需要在它们之间做双向转换：

**OpenAI Chat Completions**（`POST /v1/chat/completions`）：

```json
{
  "model": "gpt-4o",
  "messages": [
    {"role": "system", "content": "You are helpful."},
    {"role": "user", "content": "Hello"}
  ],
  "stream": true
}
```

**Anthropic Messages**（`POST /v1/messages`）：

```json
{
  "model": "claude-sonnet-4-20250514",
  "system": "You are helpful.",
  "messages": [
    {"role": "user", "content": "Hello"}
  ],
  "stream": true
}
```

两者的关键差异：system prompt 位置不同（messages 数组 vs 顶层字段）、tool_calls 表达方式不同（OpenAI 用 `tool_calls` 数组嵌在 assistant message 里，Anthropic 用 `content` 数组中的 `tool_use` block）、streaming 事件格式完全不同。

---

## 二、AgentGateway LLM 模块架构

### 2.1 核心类型定义

LLM 模块的核心类型位于 `crates/agentgateway/src/llm/mod.rs`：

```rust
/// AI 后端：持有一组 Provider，使用 P2C 算法选择
pub struct AIBackend {
    pub providers: EndpointSet<NamedAIProvider>,
}

/// 命名的 AI Provider：包含 provider 类型 + 路径/host 覆盖 + 内联策略
pub struct NamedAIProvider {
    pub name: Strng,
    pub provider: AIProvider,
    pub host_override: Option<Strng>,
    pub path_prefix: Option<Strng>,
    pub path_override: Option<Strng>,
    pub tokenize: bool,
    pub inline_policies: Option<Arc<InlinePolicies>>,
}

/// Provider 枚举：每种 Provider 定义不同的 host/path/auth 默认值
pub enum AIProvider {
    OpenAI,
    Gemini,
    Vertex,
    Anthropic,
    Bedrock,
    Azure,
    Copilot,
    Custom,
}
```

`EndpointSet<T>` 实现了 Power-of-Two-Choices（P2C）负载均衡：随机选两个 Provider，比较它们的 score（基于 inflight 请求数和响应延迟），选更好的那个。这避免了 Round-Robin 在异构后端上的"慢节点拖累所有请求"问题。

### 2.2 路由类型识别

AgentGateway 通过请求路径的后缀来判断请求的 "RouteType"：

```rust
pub enum RouteType {
    Completions,       // /chat/completions
    Messages,          // /messages
    Models,            // /models
    Passthrough,       // 不解析 body，原样转发
    Detect,            // 自动从 body 推断格式
    Responses,         // /responses（OpenAI 新 API）
    Embeddings,        // /embeddings
    Realtime,          // /realtime（WebSocket）
    AnthropicTokenCount, // /messages/count_tokens
    Rerank,            // /rerank
}
```

路径后缀匹配由 `SortedRoutes` 实现（longest-first 排序）：

```rust
pub struct SortedRoutes {
    inner: IndexMap<Strng, RouteType>,
}
```

比如配置了 `/messages/count_tokens → AnthropicTokenCount` 和 `/messages → Messages`，由于前者更长，会优先匹配。

### 2.3 请求与响应元数据

```rust
/// 请求侧元数据（tokenization 后填充）
pub struct LLMRequest {
    pub input_tokens: Option<u64>,
    pub input_format: InputFormat,
    pub native_format: InputFormat,  // 后端期望的格式
    pub request_model: Option<Strng>,
    pub provider: AIProvider,
    pub streaming: bool,
    pub params: LLMParams,
    pub prompt: Option<Vec<SimpleChatCompletionMessage>>,
}

/// 响应侧元数据（从 usage 字段或 streaming 末尾 chunk 提取）
pub struct LLMResponse {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
    pub reasoning_tokens: Option<u64>,
    pub cached_input_tokens: Option<u64>,
    pub service_tier: Option<Strng>,
    pub provider_model: Option<Strng>,
    pub first_token: Option<Instant>,
    pub completion: Option<String>,
}
```

---

## 三、请求处理管线

### 3.1 HTTP Proxy 层入口

LLM 请求首先经过通用的 HTTP Proxy 层（`src/proxy/httpproxy.rs`）：

```
HTTPProxy::proxy()
  → proxy_internal()
    → route selection（PathMatch: Exact > PathPrefix > Regex）
    → apply_request_policies()  // 完整 policy 链
    → make_backend_call()
```

Policy 执行顺序（`apply_request_policies()`）：

```
CORS → OIDC → JWT → BasicAuth → APIKey → ExtAuthZ
→ Authorization → LocalRateLimit → RemoteRateLimit
→ Buffer → ExtProc → Transformation → CSRF
→ ResponseHeaderMod → RequestHeaderMod → HostnameRewrite
→ URLRewrite → RequestRedirect → DirectResponse
```

当 backend 配置中存在 `llm_provider` 时，进入 LLM 特殊处理路径。

### 3.2 LLM 请求处理流程

核心函数 `AIProvider::process_request()` 的执行步骤：

```
1. 确定 native_format
   ↓  根据 (input_format, provider) 决定后端期望什么格式
2. 验证兼容性
   ↓  某些组合不允许（如 Embeddings → Anthropic）
3. 解析 model aliases
   ↓  通配符匹配 → model 名称重写
4. Prompt Enrichment
   ↓  prepend/append 系统提示词
5. Prompt Guard（内容审查）
   ↓  regex / webhook / moderation API
6. Tokenization
   ↓  调用 tiktoken 计算 input tokens
7. 格式转换
   ↓  to_openai() / to_anthropic() / to_bedrock() / to_vertex()
8. 返回 RequestResult::Success 或 RequestResult::Rejected
```

其中 `RequestResult` 的定义：

```rust
pub enum RequestResult {
    Success(Request, LLMRequest),    // 正常：转换后的请求 + 元数据
    Rejected(Response),              // 被 guardrail 拦截
}
```

### 3.3 Native Format 决策

每种 Provider 都有自己偏好的"原生格式"。当客户端发送的格式与后端期望不一致时，网关需要做格式转换：

| 客户端格式 | Provider | Native Format | 是否需要转换 |
|-----------|----------|---------------|------------|
| Completions | OpenAI | Completions | 否 |
| Completions | Anthropic | Messages | 是 |
| Completions | Bedrock | Bedrock | 是 |
| Messages | OpenAI | Completions | 是 |
| Messages | Anthropic | Messages | 否 |
| Messages | Bedrock | Bedrock | 是 |

Custom Provider 有一个偏好表（`native_format_for()`）：

```rust
// Custom Provider 的格式偏好（最少转换原则）
Completions input → 偏好 [Completions, Messages]
Messages input    → 偏好 [Messages, Completions]
```

---

## 四、多 Provider 格式转换

### 4.1 转换矩阵

格式转换代码位于 `crates/agentgateway/src/llm/conversion/`，每个文件处理一个方向：

```
conversion/
├── completions.rs      // Messages → Completions（Anthropic 入 → OpenAI 出）
├── messages.rs         // Completions → Messages（OpenAI 入 → Anthropic 出）
├── bedrock.rs          // Completions/Messages → Bedrock Converse
├── openai_compat.rs    // Gemini/Vertex OpenAI-compat 流式修正
└── responses.rs        // OpenAI Responses API 透传
```

### 4.2 Completions → Messages 转换要点

从 OpenAI 格式转为 Anthropic 格式时，主要难点：

**system prompt 提取**：OpenAI 把 system message 放在 messages 数组里，Anthropic 需要提取到顶层 `system` 字段：

```rust
// 提取所有 role=system 的 message 合并为 Anthropic system blocks
let system_messages: Vec<_> = messages.iter()
    .filter(|m| m.role == "system")
    .collect();
```

**tool_calls 映射**：OpenAI assistant message 的 `tool_calls` 数组需要转为 Anthropic 的 `content` 数组中的 `tool_use` block：

```
// OpenAI:
{"role": "assistant", "tool_calls": [{"id": "call_1", "function": {"name": "search", "arguments": "{...}"}}]}

// → Anthropic:
{"role": "assistant", "content": [{"type": "tool_use", "id": "call_1", "name": "search", "input": {...}}]}
```

**thinking blocks**：Anthropic 的 extended thinking 需要在转换时保留为 `thinking` content block。

### 4.3 Bedrock 转换的特殊性

Bedrock 不使用原生的 Anthropic Messages 格式，而是有自己的 Converse API：

```rust
// Bedrock Converse 请求格式
{
  "modelId": "anthropic.claude-3-sonnet-...",
  "messages": [{"role": "user", "content": [{"text": "Hello"}]}],
  "system": [{"text": "You are helpful."}],
  "inferenceConfig": {"maxTokens": 1024, "temperature": 0.7}
}
```

AgentGateway 在 `conversion/bedrock.rs` 中实现了 Completions→Bedrock 和 Messages→Bedrock 两个方向的转换，都需要将 content 格式重新映射为 Bedrock 的 `ContentBlock` 类型系统。

---

## 五、流式 SSE 处理架构

### 5.1 为什么流式处理很复杂

LLM 的流式响应不是简单的数据透传。网关需要：

1. **解析每个 SSE 事件**：提取 token 用量、检测结束信号
2. **格式转换**：如果客户端期望 OpenAI 格式但后端返回 Anthropic 格式，需要逐事件转换
3. **Token 计数**：从最后一个 usage chunk 中提取实际用量，报告给 rate limiter
4. **First Token 计时**：记录第一个有实际内容的 chunk 的时间（TTFT 指标）

### 5.2 三种流处理辅助函数

位于 `src/llm/parse/sse.rs`：

```rust
/// 1. 透传：只解析 JSON 做监控，不修改内容
pub fn json_passthrough<T>(body, buffer_limit, callback) -> Body

/// 2. 一对一转换：一个输入事件 → 一个输出事件
pub fn json_transform<T, U>(body, buffer_limit, transform_fn) -> Body

/// 3. 一对多转换：一个输入事件 → 多个输出事件
pub fn json_transform_multi<T, U>(body, buffer_limit, transform_fn) -> Body
```

### 5.3 流式转换状态机（核心难点）

OpenAI 和 Anthropic 的 SSE 流格式差异很大。

**OpenAI 的流**是"扁平"的——每个 chunk 就是一个 delta，没有"块"的生命周期概念：

```
data: {"choices":[{"delta":{"content":"Hello"}}]}
data: {"choices":[{"delta":{"content":" world"}}]}
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"search"}}]}}]}
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"q\":"}}]}}]}
data: {"choices":[{"finish_reason":"stop"}]}
```

**Anthropic 的流**是"结构化"的——每段内容必须经历 `start → delta(s) → stop` 的完整生命周期：

```
event: message_start
event: content_block_start  {"index":0, "content_block":{"type":"text"}}
event: content_block_delta  {"index":0, "delta":{"text":"Hello world"}}
event: content_block_stop   {"index":0}
event: content_block_start  {"index":1, "content_block":{"type":"tool_use","id":"call_1","name":"search"}}
event: content_block_delta  {"index":1, "delta":{"partial_json":"{\"q\":"}}
event: content_block_stop   {"index":1}
event: message_delta        {"delta":{"stop_reason":"end_turn"}}
event: message_stop
```

当需要将 OpenAI 流转换为 Anthropic 流时（`conversion/completions.rs:242`），状态机需要跟踪哪些 block 处于"打开"状态：

```rust
struct StreamState {
    sent_message_start: bool,
    sent_message_stop: bool,
    sent_first_token: bool,
    next_block_index: usize,            // 下一个 block 的序号
    text_block_index: Option<usize>,    // 当前打开的 text block
    tool_block_indices: HashMap<u32, usize>,  // tool index → block index
    open_tool_blocks: HashSet<u32>,     // 哪些 tool block 还开着
    pending_tool_calls: HashMap<u32, PendingToolCall>,
    pending_stop_reason: Option<StopReason>,
    pending_usage: Option<Usage>,
}
```

状态转换逻辑：当 OpenAI chunk 从 `content` 切到 `tool_calls` 时，状态机必须：

1. 发 `content_block_stop` 关闭当前 text block
2. 发 `content_block_start` 开启新的 tool_use block
3. 然后才能发 `content_block_delta`

```rust
fn open_text_block(state, events) -> usize {
    if let Some(index) = state.text_block_index {
        return index;  // 已经开着，直接复用
    }
    close_all_tool_blocks(state, events);  // 先关闭所有 tool blocks
    let index = state.next_block_index;
    state.next_block_index += 1;
    state.text_block_index = Some(index);
    push_event(events, ContentBlockStart { index, content_block: Text("") });
    index
}

fn open_tool_block(state, events, tool_index, id, name) -> usize {
    close_text_block(state, events);  // 先关闭 text block
    // ... 开启新的 tool block
}
```

反方向（Anthropic → OpenAI）相对简单，因为 OpenAI chunk 是扁平的，不需要管理 block 生命周期。只需维护 `tool_index_map` 做序号映射。

### 5.4 AmendOnDrop：RAII Token 报告

流式响应的 Token 用量只有在流结束时才能确定。AgentGateway 使用 RAII 模式确保无论流如何结束（正常完成、客户端断开、超时）都能正确报告：

```rust
/// Drop 时自动向 rate limiter 报告实际 token 用量
pub struct AmendOnDrop {
    log: Arc<RequestLog>,
    rate_limiters: Vec<RateLimiter>,
}

impl Drop for AmendOnDrop {
    fn drop(&mut self) {
        let response = &self.log.response;
        // 计算修正量 = (实际 input - 预估 input) + output
        let amendment = (response.input_tokens - request.input_tokens) + response.output_tokens;
        for limiter in &self.rate_limiters {
            limiter.amend_tokens(amendment);
        }
    }
}
```

流处理过程中通过 `log.non_atomic_mutate()` 逐步更新 token 计数，最终在 `AmendOnDrop` 析构时一次性把差额补报给限流器。

---

## 六、Token 计数与限流

### 6.1 请求侧 Token 预估

在发送请求前，如果启用了 `tokenize: true`，网关使用 tiktoken 库本地计算 input tokens：

```rust
pub fn num_tokens_from_messages(messages: &[Message], model: &str) -> u64 {
    let encoding = match model {
        m if m.starts_with("gpt-4o") => O200kBase,
        _ => Cl100kBase,
    };
    // 公式：每条 message = 3 + role_tokens + content_tokens
    // 总计 = sum(messages) + 3（assistant reply 前缀）
    messages.iter().map(|m| 3 + encode(m.role) + encode(m.content)).sum() + 3
}
```

这是一个 CPU 密集操作（需要对全部 prompt 文本做 BPE 编码），所以通过 `tokenize` 字段控制是否启用——大流量场景可以关闭它，只依赖响应中的 usage 做后验统计。

### 6.2 两阶段限流修正

LLM 的 Token 限流面临一个鸡生蛋问题：请求到达时不知道最终会消耗多少 output token。AgentGateway 的解决方案是**两阶段限流**：

```
阶段 1（请求时）：
  预估 input tokens → 预扣 rate limit quota

阶段 2（响应完成时，AmendOnDrop）：
  实际 usage = response.input_tokens + response.output_tokens
  修正量 = 实际 usage - 预扣量
  → 向 rate limiter 补扣/退回差额
```

这确保了限流的最终一致性：即使预估不准确，在响应完成后总会修正为实际用量。

### 6.3 Streaming 场景的 Usage 提取

非流式响应直接从 JSON body 的 `usage` 字段提取。流式响应需要特殊处理：

- **OpenAI**：请求时传 `stream_options: {"include_usage": true}`，最后一个 chunk 会包含 `usage` 字段
- **Anthropic**：`message_delta` 事件中的 `usage` 字段包含 output_tokens，`message_start` 中的 `usage` 包含 input_tokens

---

## 七、内容审查（Prompt Guard）

### 7.1 审查架构

Prompt Guard 在请求侧和响应侧各有一条审查链，按数组顺序依次执行：

```rust
pub struct PromptGuard {
    pub request: Vec<RequestGuard>,
    pub response: Vec<ResponseGuard>,
}

pub struct RequestGuard {
    pub rejection: RequestRejection,  // 拒绝时返回的响应
    pub kind: RequestGuardKind,       // 审查方式
}

pub enum RequestGuardKind {
    Regex(RegexRules),                // 本地正则匹配
    Webhook(Webhook),                 // 外部审查服务
    OpenAIModeration(Moderation),     // OpenAI Moderation API
    BedrockGuardrails(BedrockGuardrails),    // AWS Bedrock
    GoogleModelArmor(GoogleModelArmor),      // GCP Model Armor
    AzureContentSafety(AzureContentSafety),  // Azure Content Safety
}
```

### 7.2 六种审查方式

**Regex**：最轻量，本地执行。支持两种 action：

- `reject`：匹配到就拒绝请求，返回自定义错误响应
- `mask`：将匹配内容替换为 `[REDACTED]` 后继续流程

内置 5 种敏感数据模式：SSN、CreditCard、PhoneNumber、Email、CaSin。

**Webhook**：调用外部审查服务。协议：

```
POST → {"body": {"messages": [{"role":"user","content":"..."}]}}
← {"action": "pass"} 或 {"action": "reject", "status": 403, "body": "..."} 或 {"action": "mask", "body": {...}}
```

支持 `failureMode: failClosed`（默认，审查服务宕机时拒绝所有请求）和 `failOpen`（审查服务宕机时放行）。

**OpenAI Moderation**：调用 OpenAI 的 `/v1/moderations` 端点，自动检测 hate/violence/self-harm/sexual 等分类。

**Bedrock Guardrails**：使用 AWS Bedrock ApplyGuardrail API，支持更丰富的安全策略。

**Google Model Armor**：使用 GCP Model Armor 的 SanitizeUserPrompt API。

**Azure Content Safety**：调用 Azure AnalyzeText 和 DetectJailbreak API，支持按严重程度阈值过滤（0-6 级）。

### 7.3 执行时序

```
请求到达
  → Prompt Enrichment（prepend/append）
  → Prompt Guard（按数组顺序逐条执行）
    → guard[0]: 任一 reject → 立即返回 RequestResult::Rejected
    → guard[1]: mask → 修改 message 内容后继续
    → guard[2]: pass → 继续
  → Tokenization
  → 格式转换
  → 发送给上游
```

注意：响应侧的 Prompt Guard **仅对非流式响应生效**。流式响应的内容已经逐 chunk 推送给客户端了，无法事后拦截。

---

## 八、模型路由与别名

### 8.1 两种路由模式

**模式 1：`llm.models[]` 按 model name 路由**

```yaml
llm:
  models:
  - name: "claude-sonnet-*"      # 通配符前缀匹配
    provider: anthropic
    params:
      baseUrl: https://api.anthropic.com/v1
      apiKey: "sk-ant-xxx"
  - name: "gpt-4o"               # 精确匹配
    provider: openai
    params:
      baseUrl: https://api.openai.com/v1
  - name: "*"                    # 兜底
    provider: openai
    params:
      baseUrl: https://default-llm.internal/v1
```

匹配优先级：精确匹配 > 长前缀（非通配字符数多的优先） > 短前缀 > `*`。

通配符规则：只允许单个 `*` 出现在 name 的头部或尾部。`claude-*` 匹配所有 `claude-` 开头的模型，`*-instruct` 匹配所有以 `-instruct` 结尾的模型。

实现路径：`llm_model_name_header_match()` 将 name string 编译为 `HeaderValueMatch::Regex`，如 `claude-*` → regex `^claude-.*$`。

**模式 2：Route-level AI backend**

```yaml
binds:
- listeners:
  - routes:
    - matches:
      - path:
          type: PathPrefix
          value: /v1/chat/completions
      backends:
      - ai:
          groups:
          - providers:
            - name: primary-openai
              provider: {openAI: {model: gpt-4o}}
              weight: 80
            - name: fallback-azure
              provider: {azureOpenAI: {host: my.openai.azure.com}}
              weight: 20
```

这种模式按 HTTP 层面（path/header/method）匹配，**无法按请求体中的 model 字段路由**——那是 `llm.models` 的独有能力。

### 8.2 模型名称重写

三种方式重写发送给上游的 model 名称：

1. `llm.models[].params.model`：匹配后固定覆盖
2. `provider.xxx.model`：binds 格式无条件覆盖
3. `policies.ai.modelAliases`：条件映射表（通配符匹配才改，没匹配则原样透传）

### 8.3 baseUrl 展开逻辑

`baseUrl` 字段会被自动展开为三个内部字段：

```rust
fn apply_base_url(base_url: &str) {
    let url = Url::parse(base_url);
    self.host_override = url.host() + ":" + url.port();
    self.path_prefix = url.path().trim_end_matches('/');  // 注意：是 REPLACE 而非 prepend!
    if url.scheme() == "https" {
        self.backend_tls = auto_tls_config();
    }
}
```

**关键陷阱**：`path_prefix` 的语义是**替换**默认路径前缀（如 Anthropic 的 `/v1`），而非在前面追加。

例如 `baseUrl: https://example.com/api/code` + Anthropic provider：
- 最终路径 = `/api/code` + `/messages` = `/api/code/messages`
- 而**不是** `/api/code/v1/messages`

如果上游端点期望 `/api/code/v1/messages`，则 baseUrl 必须设为 `https://example.com/api/code/v1`。

---

## 九、Provider 特定实现

### 9.1 路径构造

每种 Provider 定义自己的默认路径和后缀：

```rust
// Anthropic
const DEFAULT_BASE_PATH: &str = "/v1";
fn path_suffix(route_type: RouteType) -> &str {
    match route_type {
        Messages => "/messages",
        AnthropicTokenCount => "/messages/count_tokens",
        _ => unreachable!(),
    }
}
// 最终路径 = path_prefix.unwrap_or(DEFAULT_BASE_PATH) + path_suffix

// OpenAI
const DEFAULT_BASE_PATH: &str = "/v1";
fn path_suffix(route_type: RouteType) -> &str {
    match route_type {
        Completions => "/chat/completions",
        Models => "/models",
        Embeddings => "/embeddings",
        Responses => "/responses",
        _ => unreachable!(),
    }
}
```

### 9.2 认证方式

| Provider | 认证方式 |
|----------|---------|
| OpenAI | `Authorization: Bearer <api_key>` |
| Anthropic | `x-api-key: <api_key>` |
| Azure | `api-key: <api_key>` 或 Azure AD token |
| Bedrock | AWS SigV4 签名（自动从环境/配置获取凭证） |
| Vertex | GCP OAuth2 access token（通过 ADC） |
| Gemini | `?key=<api_key>` URL 参数 |

### 9.3 Custom Provider

Custom provider 通过 `native_format_for()` 偏好表决定使用什么格式发送请求，实现最少转换原则：

```rust
fn native_format_for(input_format: InputFormat) -> InputFormat {
    match input_format {
        Completions => Completions,   // 客户端发 completions → 直接用 completions
        Messages => Messages,         // 客户端发 messages → 直接用 messages
        _ => Completions,             // 其他情况默认用 completions
    }
}
```

配置时可以覆盖 `formats` 字段，指定 Custom provider 接受哪些格式。

---

## 十、与阿里云 AI 网关对比

| 维度 | AgentGateway（开源） | 阿里云 AI 网关（商业） |
|------|---------------------|---------------------|
| 部署形态 | 自部署二进制/容器 | 全托管云服务 |
| 协议转换 | 双向状态机转换（含流式） | OpenAI-compatible 统一代理 |
| Provider 数 | 21 种 | 主流 6-8 种 |
| 内容审查 | 6 种（Regex/Webhook/OpenAI/Bedrock/GCP/Azure） | AI 安全护栏（敏感词/注入攻击） |
| 语义缓存 | 不支持 | 支持 |
| 限流模式 | Token 两阶段修正 | Token 按消费者限流 |
| 数据面语言 | Rust（Thread-Per-Core） | 未公开 |
| 配置方式 | YAML / xDS / K8s CRD | 控制台可视化 |
| MCP 支持 | 完整 session 管理 + RBAC | 代理 + RESTful→MCP 转换 |
| 成本 | 开源免费（自运维） | 按量/包月付费（免运维） |

---

## 十一、关键设计亮点

### 11.1 RequestType Trait 抽象

所有请求格式通过一个 trait 统一接口：

```rust
pub trait RequestType {
    fn model(&self) -> Option<&str>;
    fn prepend_prompts(&mut self, prompts: &[Message]);
    fn append_prompts(&mut self, prompts: &[Message]);
    fn to_llm_request(&self) -> LLMRequest;
    fn get_messages(&self) -> Vec<SimpleChatCompletionMessage>;
    fn to_openai(&self) -> Result<Request>;
    fn to_anthropic(&self) -> Result<Request>;
    fn to_bedrock(&self) -> Result<Request>;
    fn to_vertex(&self) -> Result<Request>;
}
```

Completions、Messages、Responses、Embeddings、Detect 都实现了这个 trait，使得上层处理逻辑完全格式无关。

### 11.2 Detect 模式

当路由配置为 `Detect` 时，网关不预设格式，而是从请求 body 中嗅探：

```rust
pub enum DetectRequest {
    Raw(Bytes),       // 无法解析为 JSON，原样透传
    Json(Value),      // JSON 但无法判断格式
}

// 从 JSON 中提取 model 和 streaming 字段，不修改内容
impl RequestType for DetectRequest {
    fn model(&self) -> Option<&str> {
        self.as_json()?.get("model")?.as_str()
    }
}
```

这种模式适用于"只需要做路由和观测，不需要做格式转换"的场景——网关只提取必要元数据，请求/响应 body 原样透传。

### 11.3 零拷贝流处理

流式响应不 buffer 整个 body，而是通过 `parse::sse` 在数据经过时解析/变换/监控：

```
HTTP Response Body (chunked)
  → decompress (gzip/br/deflate)
  → SSE event parser (按 \n\n 切分)
  → JSON deserialize 为具体事件类型
  → transform/monitor/extract usage
  → serialize 为目标格式 JSON
  → 重新包装为 SSE event
  → 推送给客户端
```

整个过程没有将完整响应加载到内存中——每个 SSE 事件到达时立即处理并转发，内存占用恒定。

---

## 总结

AgentGateway 的 LLM 模块是一个高度抽象的多协议 LLM 代理实现。它的几个核心设计决策值得借鉴：

1. **Trait 抽象**：`RequestType` 让处理管线与具体格式解耦
2. **状态机流转换**：在不 buffer 完整响应的前提下，实现了 SSE 事件级别的格式转换
3. **两阶段 Token 限流**：通过 RAII（AmendOnDrop）保证限流的最终一致性
4. **按需付费的 Tokenization**：CPU 密集的 tiktoken 计算可以通过配置关闭
5. **六种 Guardrail 统一接口**：从本地 regex 到云服务 API，统一为 `RequestGuardKind` 枚举

这些设计组合在一起，使得 AgentGateway 能够在保持高性能的同时，灵活支持各种 LLM Provider 的接入和治理需求。
