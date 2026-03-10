---
title: "IronClaw 简析"
date: 2026-03-10T07:00:00+08:00
draft: false
tags: [ai generated]
categories: [agent]
---

> **前言**：在 AI 助手日益中心化的今天，IronClaw 选择了一条不同的道路——一个完全本地化、开源、安全至上的个人 AI 助手。本文将从架构师视角，深度拆解这个用 Rust 重写的 OpenClaw 实现，揭示其设计哲学、核心模块和技术亮点。

---

## 一、项目背景与技术选型

### 1.1 项目定位

IronClaw 是一个**安全优先的个人 AI 助手**，核心理念是"你的 AI 助手应该为你工作，而不是对抗你"。它通过以下设计原则实现这一目标：

- **数据自主**：所有数据本地存储、加密，完全由用户控制
- **透明设计**：开源可审计，无隐藏遥测或数据收集
- **能力自扩展**：动态构建新工具，无需等待厂商更新
- **纵深防御**：多层安全机制防止提示词注入和数据泄露

### 1.2 技术栈分析

```yaml
核心语言：Rust 1.92+ (Edition 2024)
异步运行时：Tokio (full features)
HTTP 客户端：reqwest (rustls-tls)
序列化：serde + serde_json
数据库：
  - PostgreSQL 15+ with pgvector (默认)
  - libSQL/Turso (可选嵌入式)
LLM 框架：rig-core (多 provider 抽象)
WASM 沙箱：wasmtime + wasmtime-wasi
容器沙箱：bollard (Docker API)
Web 框架：axum (HTTP + WebSocket)
CLI: clap + rustyline + termimad
加密：aes-gcm, hkdf, blake3, ed25519-dalek
```

**技术选型亮点**：
- 选择 Rust 而非 TypeScript：原生性能、内存安全、单二进制分发
- WASM 沙箱 vs Docker：轻量级、基于能力的权限控制
- PostgreSQL vs SQLite：生产级持久化、向量搜索支持

---

## 二、项目架构总览

### 2.1 目录结构解析

```
ironclaw/
├── src/                          # 核心源代码
│   ├── agent/                    # 代理核心逻辑层
│   │   ├── agent_loop.rs         # 主事件循环
│   │   ├── router.rs             # 意图路由
│   │   ├── scheduler.rs          # 并行作业调度
│   │   ├── worker.rs             # 作业执行器
│   │   ├── session_manager.rs    # 会话管理
│   │   ├── self_repair.rs        # 自我修复
│   │   └── heartbeat.rs          # 心跳任务
│   │
│   ├── tools/                    # 工具系统层
│   │   ├── registry.rs           # 工具注册表
│   │   ├── wasm/                 # WASM 沙箱工具
│   │   ├── builtin/              # 内置工具
│   │   ├── mcp/                  # MCP 协议支持
│   │   └── builder/              # 动态工具构建
│   │
│   ├── sandbox/                  # 沙箱执行层
│   │   ├── manager.rs            # 沙箱管理器
│   │   ├── container.rs          # Docker 容器
│   │   └── proxy/                # 网络代理
│   │
│   ├── orchestrator/             # 编排器层
│   │   ├── api.rs                # 内部 HTTP API
│   │   ├── job_manager.rs        # 容器作业管理
│   │   └── auth.rs               # 令牌认证
│   │
│   ├── workspace/                # 工作空间/记忆层
│   │   ├── repository.rs         # 文档存储
│   │   ├── search.rs             # 混合搜索
│   │   └── embeddings.rs         # 向量嵌入
│   │
│   ├── channels/                 # 多渠道接入层
│   │   ├── manager.rs            # 渠道管理器
│   │   ├── web/                  # Web 网关
│   │   ├── wasm/                 # WASM 渠道
│   │   └── http.rs               # HTTP Webhook
│   │
│   ├── llm/                      # LLM 适配层
│   │   ├── provider.rs           # Provider trait
│   │   ├── failover.rs           # 故障转移
│   │   └── rig_adapter.rs        # rig-core 适配
│   │
│   ├── safety/                   # 安全层
│   │   ├── sanitizer.rs          # 输入净化
│   │   ├── leak_detector.rs      # 泄露检测
│   │   └── policy.rs             # 安全策略
│   │
│   └── secrets/                  # 密钥管理
│       └── store.rs              # 加密存储
│
├── tools-src/                    # WASM 工具源码 (独立 crates)
├── channels-src/                 # WASM 渠道源码 (独立 crates)
├── migrations/                   # 数据库迁移
└── wit/                          # WIT 接口定义
```

### 2.2 核心数据流

{{< mermaid >}}
graph TB
    subgraph "渠道层 Channels"
        A[REPL] --> CM[ChannelManager]
        B[HTTP Webhook] --> CM
        C[WASM Channels] --> CM
        D[Web Gateway] --> CM
    end

    CM --> AL[Agent Loop]

    subgraph "代理核心 Agent Core"
        AL --> R[Router 意图识别]
        R --> S[Scheduler 作业调度]
        S --> W[Worker 执行器]
    end

    subgraph "工具执行 Tool Execution"
        W --> TR[Tool Registry]
        TR --> BT[内置工具]
        TR --> WT[WASM 工具]
        TR --> MT[MCP 工具]
    end

    WT --> SB[Sandbox 沙箱]
    SB --> OP[Orchestrator API]
    OP --> DC[Docker Container]

    subgraph "支持系统 Support Systems"
        W --> SM[Session Manager]
        W --> WS[Workspace 记忆]
        W --> SL[Safety Layer]
        SL --> LD[Leak Detector]
    end

    DC --> NP[Network Proxy]
    NP --> INT[Internet]

    style AL fill:#f9f,stroke:#333
    style SB fill:#ff9,stroke:#333
    style SL fill:#9f9,stroke:#333
{{< /mermaid >}}

### 2.3 执行流程文字描述

1. **消息接收**：渠道层 (Channels) 接收外部消息，统一转换为 `IncomingMessage`
2. **意图路由**：Router 分析消息类型（命令/查询/任务），分发到对应处理器
3. **作业调度**：Scheduler 创建作业上下文，分配唯一 Job ID，启动 Worker
4. **LLM 推理**：Worker 调用 LLM Provider，获取工具调用决策
5. **工具执行**：
   - 内置工具：直接执行（带速率限制）
   - WASM 工具：沙箱隔离执行，能力验证，凭证注入
   - Docker 工具：容器创建，网络代理，资源限制
6. **安全过滤**：Safety Layer 检查输出，防止提示词注入和密钥泄露
7. **响应返回**：结果通过原渠道返回，更新会话历史
8. **记忆持久化**：重要信息写入 Workspace，支持混合搜索

---

## 三、核心模块深度剖析

### 3.1 代理核心层 (Agent Core)

**功能定义**：代理核心层是整个系统的大脑，负责消息处理、作业调度、LLM 推理协调。

#### 关键组件分析

##### 3.1.1 Agent Loop - 主事件循环

```rust
// src/agent/agent_loop.rs
pub struct Agent {
    pub(super) config: AgentConfig,
    pub(super) deps: AgentDeps,  // LLM, Safety, Tools, Workspace 等
    pub(super) channels: Arc<ChannelManager>,
    pub(super) context_manager: Arc<ContextManager>,
    pub(super) scheduler: Arc<Scheduler>,
    pub(super) router: Router,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) context_monitor: ContextMonitor,
    // ... 心跳、例行任务配置
}
```

**设计模式**：
- **依赖注入模式**：通过 `AgentDeps` 结构体注入所有外部依赖，便于测试和替换
- **外观模式**：Agent 作为统一入口，隐藏内部复杂性
- **观察者模式**：通过 SSE 广播作业事件到 Web 网关

**核心循环逻辑**：
```rust
// 简化版事件循环
loop {
    select! {
        // 1. 接收渠道消息
        Some(msg) = channel_stream.next() => {
            let intent = router.classify(&msg);
            scheduler.schedule_job(intent, msg).await;
        }

        // 2. 心跳任务触发
        _ = heartbeat_tick.tick() => {
            scheduler.schedule_heartbeat().await;
        }

        // 3. 例行任务触发
        _ = cron_tick.tick() => {
            routine_engine.execute_due_routines().await;
        }

        // 4. 作业完成通知
        Some(job_result) = job_rx.recv() => {
            session_manager.update_turn(job_result).await;
        }
    }
}
```

##### 3.1.2 Router - 意图识别

```rust
// src/agent/router.rs
pub enum MessageIntent {
    Command(String),      // /help, /undo 等
    Query(String),        // 信息查询
    Task(String),         // 需要执行工具的任务
    Clarification(String), // 需要澄清
}

pub struct Router {
    // 使用轻量级 LLM 或规则进行意图分类
}
```

**设计原则**：
- **单一职责**：只负责意图分类，不处理具体业务
- **开闭原则**：可扩展新的意图类型

##### 3.1.3 Scheduler - 并行作业调度

```rust
// src/agent/scheduler.rs
pub struct Scheduler {
    config: AgentConfig,
    context_manager: Arc<ContextManager>,
    llm: Arc<dyn LlmProvider>,
    safety: Arc<SafetyLayer>,
    tools: Arc<ToolRegistry>,
    jobs: Arc<RwLock<HashMap<Uuid, ScheduledJob>>>,
    subtasks: Arc<RwLock<HashMap<Uuid, ScheduledSubtask>>>,
}
```

**并发控制策略**：
- 使用 `tokio::sync::RwLock` 管理作业状态
- 每个作业独立上下文，互不干扰
- 通过 `mpsc::Sender` 向 Worker 发送控制消息（Start/Stop/Ping）

**技术亮点**：
```rust
// 作业隔离实现
pub struct JobContext {
    pub id: Uuid,
    pub conversation: ConversationMemory,
    pub actions: Vec<ActionRecord>,
    pub state: JobState,
    // 每个作业独立的会话历史
}
```

---

### 3.2 工具系统层 (Tool System)

**功能定义**：工具系统是代理的"手和脚"，提供与外部世界交互的能力。

#### 架构设计哲学

```
┌─────────────────────────────────────────────────────────────┐
│                    工具系统设计原则                          │
├─────────────────────────────────────────────────────────────┤
│ 1. 沙箱优先：不可信工具必须在 WASM 或 Docker 中运行          │
│ 2. 能力声明：工具通过 capabilities.json 声明所需权限        │
│ 3. 凭证注入：密钥在宿主边界注入，工具代码永不可见           │
│ 4. 泄露检测：所有输出经过泄露扫描才返回给 LLM               │
│ 5. 速率限制：每个工具独立限流，防止滥用                     │
└─────────────────────────────────────────────────────────────┘
```

#### 3.2.1 Tool Registry - 工具注册表

```rust
// src/tools/registry.rs
pub struct ToolRegistry {
    tools: RwLock<HashMap<String, Arc<dyn Tool>>>,
    builtin_names: RwLock<HashSet<String>>,  // 保护内置工具名
    credential_registry: Option<Arc<SharedCredentialRegistry>>,
    secrets_store: Option<Arc<dyn SecretsStore>>,
    rate_limiter: RateLimiter,
}

// 防止工具名冲突
const PROTECTED_TOOL_NAMES: &[&str] = &[
    "shell", "http", "memory_write", "create_job", ...
];
```

**安全设计**：
- **名称保护**：动态工具不能注册与内置工具相同的名称
- **凭证隔离**：WASM 工具声明的凭证映射集中管理
- **速率限制**：每个工具独立限流配置

#### 3.2.2 WASM 工具沙箱

```rust
// src/tools/wasm/runtime.rs
pub struct WasmToolRuntime {
    engine: Engine,           // Wasmtime 引擎 (编译一次)
    config: WasmRuntimeConfig,
    linker: Linker<HostState>,
}

// 每次执行创建新实例
let instance = runtime.instantiate(&prepared_module).await?;
let output = instance.execute(input).await?;
// 实例丢弃，防止状态泄露
```

**安全机制**：

| 威胁 | 缓解措施 |
|------|---------|
| CPU 耗尽 | Fuel metering (燃料计量) |
| 内存耗尽 | ResourceLimiter (默认 10MB) |
| 无限循环 | Epoch interruption + tokio timeout |
| 文件系统访问 | 无 WASI FS，仅宿主 workspace_read |
| 网络访问 | Allowlisted endpoints only |
| 凭证泄露 | 宿主边界注入，工具代码不可见 |
| 秘密外泄 | Leak detector 扫描所有输出 |

**能力声明示例** (`github.capabilities.json`)：
```json
{
  "http": {
    "allow": [
      {"host": "api.github.com", "path_prefix": "/"},
      {"host": "raw.githubusercontent.com", "path_prefix": "/"}
    ],
    "credentials": {
      "Authorization": "github_token"
    }
  },
  "workspace": {
    "reader": true
  },
  "secrets": {
    "allowed": ["github_token"]
  },
  "rate_limit": {
    "requests_per_minute": 60
  }
}
```

#### 3.2.3 凭证注入器

```rust
// src/tools/wasm/credential_injector.rs
pub struct CredentialInjector {
    registry: SharedCredentialRegistry,
}

// 在 HTTP 请求发出前注入
pub fn inject_credential(
    request: &mut Request,
    credential_name: &str,
    injection_point: InjectionLocation,
) -> Result<()> {
    let secret = secrets_store.get(credential_name).await?;

    match injection_point {
        Header(name) => {
            request.headers_mut().insert(name, secret.into());
        }
        QueryParam(name) => {
            request.url_mut().query_pairs_mut()
                .append_pair(name, secret.expose_secret());
        }
        // ...
    }

    // 凭证从未暴露给 WASM 代码
    Ok(())
}
```

**设计亮点**：
- **零知识原则**：工具代码永远接触不到实际凭证
- **注入点声明**：在 capabilities.json 中声明注入位置（Header/QueryParam/Body）
- **泄露检测**：扫描请求和响应，防止凭证意外泄露

---

### 3.3 沙箱执行层 (Sandbox System)

**功能定义**：为不可信代码执行提供隔离环境，包括 Docker 容器和网络代理。

#### 3.3.1 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                     Sandbox System                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                  SandboxManager                       │   │
│  │  • 协调容器创建和执行                                  │   │
│  │  • 管理代理生命周期                                    │   │
│  │  • 执行资源限制                                        │   │
│  └──────────────────────────────────────────────────────┘   │
│           │                              │                    │
│           ▼                              ▼                    │
│  ┌──────────────────┐          ┌───────────────────┐         │
│  │   Container      │          │   Network Proxy   │         │
│  │   Runner         │          │                   │         │
│  │                  │          │  • Allowlist      │         │
│  │  • Create        │◀────────▶│  • Credentials    │         │
│  │  • Execute       │          │  • Logging        │         │
│  │  • Cleanup       │          │                   │         │
│  └──────────────────┘          └───────────────────┘         │
│           │                              │                    │
│           ▼                              ▼                    │
│  ┌──────────────────┐          ┌───────────────────┐         │
│  │     Docker       │          │     Internet      │         │
│  │                  │          │   (allowed hosts) │         │
│  └──────────────────┘          └───────────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

#### 3.3.2 容器执行器

```rust
// src/sandbox/container.rs
pub struct ContainerRunner {
    docker: DockerClient,
    config: SandboxConfig,
}

pub async fn execute(
    &self,
    command: &str,
    policy: SandboxPolicy,
) -> Result<ContainerOutput> {
    // 1. 创建临时容器 (--rm 自动清理)
    let container = self.docker.create_container(&Config {
        image: "ironclaw-worker:latest",
        cmd: Some(vec!["sh", "-c", command]),
        user: Some("1000"),  // 非 root 执行
        read_only_rootfs: Some(true),  // 只读根文件系统
        cap_drop: Some(all_caps()),  // 丢弃所有能力
        cap_add: Some(essential_caps()),  // 仅添加必要能力
        network_mode: Some("none"),  // 无网络，通过代理
        ..Default::default()
    }).await?;

    // 2. 挂载工作空间 (根据策略)
    match policy {
        SandboxPolicy::ReadOnly => { /* 只读挂载 */ }
        SandboxPolicy::WorkspaceWrite => { /* 可写挂载 */ }
        SandboxPolicy::FullAccess => { /* 完全访问 */ }
    }

    // 3. 执行并等待 (带超时)
    let result = tokio::time::timeout(
        self.config.timeout,
        container.start_and_wait()
    ).await??;

    // 4. 清理容器
    container.remove().await?;

    Ok(result)
}
```

**安全策略**：

```rust
pub enum SandboxPolicy {
    ReadOnly,           // 仅读取工作空间，网络通过代理
    WorkspaceWrite,     // 可写工作空间，网络通过代理
    FullAccess,         // 完全访问（不推荐）
}
```

#### 3.3.3 网络代理

```rust
// src/sandbox/proxy/http.rs
pub struct HttpProxy {
    allowlist: DomainAllowlist,
    credential_resolver: CredentialResolver,
    leak_detector: LeakDetector,
}

// 代理所有容器网络请求
pub async fn proxy_request(
    &self,
    request: Request,
) -> Result<Response> {
    // 1. 域名白名单检查
    self.allowlist.validate(&request)?;

    // 2. 凭证注入 (如果需要)
    let mut authenticated_request = self
        .credential_resolver
        .inject(request)
        .await?;

    // 3. 执行请求
    let response = self.client
        .execute(authenticated_request)
        .await?;

    // 4. 响应泄露扫描
    let cleaned_response = self
        .leak_detector
        .scan_and_clean(response)
        .await?;

    Ok(cleaned_response)
}
```

**白名单示例**：
```rust
pub fn default_allowlist() -> Vec<String> {
    vec![
        "api.github.com".to_string(),
        "api.openai.com".to_string(),
        "raw.githubusercontent.com".to_string(),
        // ... 仅允许访问明确批准的域名
    ]
}
```

---

### 3.4 工作空间/记忆层 (Workspace & Memory)

**功能定义**：提供持久化记忆系统，支持混合搜索（全文 + 向量）。

#### 3.4.1 文件系统 API

```
workspace/
├── README.md              # 根目录运行手册
├── MEMORY.md              # 长期记忆
├── HEARTBEAT.md           # 周期性检查清单
├── context/               # 身份和上下文
│   ├── vision.md
│   └── priorities.md
├── daily/                 # 每日日志
│   ├── 2024-01-15.md
│   └── 2024-01-16.md
└── projects/              # 任意结构
    └── alpha/
        ├── README.md
        └── notes.md
```

#### 3.4.2 混合搜索实现

```rust
// src/workspace/search.rs
pub async fn hybrid_search(
    &self,
    query: &str,
    config: SearchConfig,
) -> Result<Vec<RankedResult>> {
    // 1. 全文搜索 (BM25)
    let fts_results = self
        .postgres
        .query(
            "SELECT id, ts_rank(to_tsvector, query) as score
             FROM workspace_entries
             WHERE to_tsvector @@ to_tsquery($1)
             ORDER BY score DESC
             LIMIT $2",
            &[&query, &config.limit],
        )
        .await?;

    // 2. 向量搜索 (pgvector)
    let embedding = self.embeddings.generate(query).await?;
    let vector_results = self
        .postgres
        .query(
            "SELECT id, 1 - (embedding <=> $1) as score
             FROM workspace_entries
             ORDER BY embedding <=> $1
             LIMIT $2",
            &[&embedding, &config.limit],
        )
        .await?;

    // 3. Reciprocal Rank Fusion (RRF) 合并
    let fused = reciprocal_rank_fusion(
        fts_results,
        vector_results,
        config.k,  // RRF 常数，默认 60
    );

    Ok(fused)
}

// RRF 算法实现
pub fn reciprocal_rank_fusion(
    fts: Vec<SearchResult>,
    vector: Vec<SearchResult>,
    k: f64,
) -> Vec<RankedResult> {
    let mut scores: HashMap<Uuid, f64> = HashMap::new();

    // 全文搜索排名贡献
    for (rank, result) in fts.iter().enumerate() {
        *scores.entry(result.id).or_insert(0.0) += 1.0 / (k + rank as f64);
    }

    // 向量搜索排名贡献
    for (rank, result) in vector.iter().enumerate() {
        *scores.entry(result.id).or_insert(0.0) += 1.0 / (k + rank as f64);
    }

    // 按融合分数排序
    let mut fused: Vec<_> = scores.into_iter().collect();
    fused.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());

    fused.into_iter()
        .map(|(id, score)| RankedResult { id, score })
        .collect()
}
```

**技术亮点**：
- **RRF 算法**：无需调参即可融合两种搜索结果
- **pgvector 集成**：利用 PostgreSQL 扩展进行向量相似度搜索
- **批量嵌入**：多个查询批量生成嵌入，减少 API 调用

---

### 3.5 安全层 (Safety Layer)

**功能定义**：提供纵深防御，防止提示词注入、秘密泄露和恶意输入。

#### 3.5.1 多层防御架构

```rust
// src/safety/mod.rs
pub struct SafetyLayer {
    sanitizer: Sanitizer,      // 输入净化
    validator: Validator,      // 策略验证
    policy: Policy,            // 安全策略
    leak_detector: LeakDetector, // 泄露检测
}
```

#### 3.5.2 提示词注入防御

```rust
// src/safety/sanitizer.rs
pub struct Sanitizer;

impl Sanitizer {
    pub fn sanitize(&self, input: &str) -> SanitizedOutput {
        let mut content = input.to_string();
        let mut warnings = Vec::new();

        // 1. 检测提示词注入模式
        let injection_patterns = [
            r"(?i)ignore\s+previous\s+instructions",
            r"(?i)you\s+are\s+now\s+",
            r"(?i)system\s+instruction:",
            r"(?i)forget\s+all\s+",
        ];

        for pattern in &injection_patterns {
            if let Some(m) = regex::Regex::new(pattern)
                .unwrap()
                .find(&content)
            {
                warnings.push(InjectionWarning {
                    pattern: pattern.to_string(),
                    severity: Severity::High,
                    location: m.range(),
                    description: "Potential prompt injection detected".to_string(),
                });
            }
        }

        // 2. 内容转义
        content = content
            .replace("<", "&lt;")
            .replace(">", "&gt;");

        // 3. 策略执行
        if !warnings.is_empty() {
            match self.policy.action(&warnings) {
                PolicyAction::Block => {
                    return SanitizedOutput {
                        content: "[Blocked by safety policy]".to_string(),
                        warnings,
                        was_modified: true,
                    };
                }
                PolicyAction::Sanitize => {
                    // 移除可疑内容
                    content = self.remove_injection_attempts(&content);
                }
                PolicyAction::Warn => {
                    // 仅记录警告，继续处理
                }
            }
        }

        SanitizedOutput {
            content,
            warnings,
            was_modified: !warnings.is_empty(),
        }
    }
}
```

#### 3.5.3 秘密泄露检测

```rust
// src/safety/leak_detector.rs
pub struct LeakDetector {
    patterns: Vec<LeakPattern>,
}

#[derive(Clone)]
pub struct LeakPattern {
    name: String,
    regex: Regex,
    severity: LeakSeverity,
}

impl LeakDetector {
    pub fn scan_and_clean(&self, content: &str) -> Result<String> {
        let mut cleaned = content.to_string();

        for pattern in &self.patterns {
            if pattern.regex.is_match(&cleaned) {
                match pattern.severity {
                    LeakSeverity::Critical => {
                        // 直接阻断
                        return Err(LeakDetectionError::CriticalLeak);
                    }
                    LeakSeverity::High => {
                        // 替换为占位符
                        cleaned = pattern.regex
                            .replace_all(&cleaned, "[REDACTED]")
                            .to_string();
                    }
                    LeakSeverity::Medium => {
                        // 记录日志，继续处理
                        tracing::warn!("Potential leak detected: {}", pattern.name);
                    }
                }
            }
        }

        Ok(cleaned)
    }
}

// 内置检测模式
fn default_patterns() -> Vec<LeakPattern> {
    vec![
        LeakPattern {
            name: "AWS Access Key".to_string(),
            regex: Regex::new(r"AKIA[0-9A-Z]{16}").unwrap(),
            severity: LeakSeverity::Critical,
        },
        LeakPattern {
            name: "Private Key".to_string(),
            regex::new(r"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----").unwrap(),
            severity: LeakSeverity::Critical,
        },
        LeakPattern {
            name: "Bearer Token".to_string(),
            regex::new(r"Bearer\s+[a-zA-Z0-9\-_]+\.[a-zA-Z0-9\-_]+").unwrap(),
            severity: LeakSeverity::High,
        },
    ]
}
```

---

### 3.6 编排器层 (Orchestrator)

**功能定义**：管理沙箱化工作容器，提供内部 HTTP API 用于 LLM 代理和凭证分发。

#### 3.6.1 架构设计

```
┌───────────────────────────────────────────────┐
│              Orchestrator                       │
│                                                 │
│  Internal API (默认端口 50051)                  │
│    POST /worker/{id}/llm/complete               │
│    POST /worker/{id}/llm/complete_with_tools    │
│    GET  /worker/{id}/job                        │
│    GET  /worker/{id}/credentials                │
│    POST /worker/{id}/status                     │
│    POST /worker/{id}/complete                   │
│                                                 │
│  ContainerJobManager                            │
│    create_job() -> container + token             │
│    stop_job()                                    │
│    list_jobs()                                   │
│                                                 │
│  TokenStore (仅内存)                             │
│    per-job bearer tokens                         │
│    per-job credential grants                     │
└───────────────────────────────────────────────┘
```

#### 3.6.2 作业管理器

```rust
// src/orchestrator/job_manager.rs
pub struct ContainerJobManager {
    docker: DockerClient,
    token_store: Arc<TokenStore>,
    reaper: Arc<SandboxReaper>,
}

pub async fn create_job(
    &self,
    config: ContainerJobConfig,
) -> Result<ContainerHandle> {
    // 1. 生成作业专属 bearer token
    let job_token = Uuid::new_v4().to_string();
    self.token_store.insert(&job_token, &config).await;

    // 2. 创建容器 (带 per-job token)
    let container = self.docker.create_container(&Config {
        image: "ironclaw-worker:latest",
        env: Some(vec![
            &format!("JOB_ID={}", config.job_id),
            &format!("ORCHESTRATOR_TOKEN={}", job_token),
            &format!("ORCHESTRATOR_URL=http://host.docker.internal:{}", self.port),
        ]),
        network_mode: Some("ironclaw-network"),  // 独立网络
        ..Default::default()
    }).await?;

    // 3. 启动容器
    container.start().await?;

    // 4. 启动清理任务 (容器退出后自动删除)
    self.reaper.watch(container.id.clone()).await;

    Ok(ContainerHandle {
        id: container.id,
        token: job_token,
    })
}
```

**安全设计**：
- **Per-job Token**：每个作业独立 bearer token，容器只能访问自己的资源
- **网络隔离**：容器在独立网络，只能通过编排器 API 通信
- **自动清理**：Reaper 监控容器状态，退出后自动删除

---

## 四、技术亮点与难点分析

### 4.1 并发处理

**挑战**：如何安全地并行执行多个作业，同时保持上下文隔离？

**解决方案**：
```rust
// 1. 每个作业独立上下文
pub struct JobContext {
    id: Uuid,
    conversation: ConversationMemory,  // 独立会话历史
    actions: Vec<ActionRecord>,        // 独立动作记录
    state: JobState,                   // 独立状态机
}

// 2. 使用 tokio 任务隔离
let job_handle = tokio::spawn(async move {
    worker.run(job_context).await
});

// 3. 通过 channel 通信
let (tx, rx) = mpsc::channel::<WorkerMessage>(32);
tx.send(WorkerMessage::Start).await?;
```

**亮点**：
- 无锁设计：使用 `Arc<RwLock>` 仅在必要时加锁
- 消息传递：通过 `mpsc::channel` 传递控制消息，避免共享状态
- 优雅取消：`WorkerMessage::Stop` 通知 Worker 优雅退出

### 4.2 缓存策略

**LLM 响应缓存**：
```rust
// src/llm/response_cache.rs
pub struct ResponseCache {
    cache: DashMap<String, CachedResponse>,  // 无锁并发 HashMap
    config: CacheConfig,
}

pub async fn get_or_compute<F, Fut>(
    &self,
    key: &str,
    compute: F,
) -> Result<CompletionResponse>
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<CompletionResponse>>,
{
    // 1. 检查缓存
    if let Some(cached) = self.cache.get(key) {
        if cached.is_fresh(&self.config.ttl) {
            return Ok(cached.response.clone());
        }
    }

    // 2. 计算新响应
    let response = compute().await?;

    // 3. 写入缓存
    self.cache.insert(
        key.to_string(),
        CachedResponse {
            response: response.clone(),
            created_at: Instant::now(),
        },
    );

    Ok(response)
}
```

**亮点**：
- 使用 `DashMap` 实现无锁并发缓存
- TTL 过期策略，避免缓存污染
- 缓存键基于请求内容哈希，相同请求命中缓存

### 4.3 WASM 沙箱优化

**编译一次，实例化多次**：
```rust
// src/tools/wasm/runtime.rs
pub struct WasmToolRuntime {
    engine: Engine,  // 编译一次
    modules: DashMap<String, PreparedModule>,  // 预编译模块
}

pub struct PreparedModule {
    module: Module,  // 已编译模块 (可共享)
    metadata: ToolMetadata,
}

// 注册时编译
pub async fn prepare(
    &self,
    name: &str,
    wasm_bytes: &[u8],
) -> Result<PreparedModule> {
    let module = Module::from_binary(&self.engine, wasm_bytes)?;
    // 验证、提取元数据...
    Ok(PreparedModule { module, metadata })
}

// 执行时实例化 (快速)
pub async fn instantiate(
    &self,
    prepared: &PreparedModule,
) -> Result<ToolInstance> {
    let mut store = Store::new(&self.engine, HostState::new());
    let instance = self.linker.instantiate_async(&mut store, &prepared.module).await?;
    Ok(ToolInstance { store, instance })
}
```

**性能提升**：
- 编译开销：注册时一次性支付
- 实例化开销：~1ms（相比编译的~100ms）
- 内存共享：`Module` 在多个实例间共享代码段

### 4.4 故障转移策略

**多 LLM Provider 故障转移**：
```rust
// src/llm/failover.rs
pub struct FailoverProvider {
    primary: Arc<dyn LlmProvider>,
    fallbacks: Vec<Arc<dyn LlmProvider>>,
    cooldowns: DashMap<String, Instant>,  // 无锁 cooldown 跟踪
}

pub async fn complete(&self, request: CompletionRequest) -> Result<CompletionResponse> {
    let mut last_error = None;

    // 1. 尝试 primary
    if !self.is_on_cooldown("primary") {
        match self.primary.complete(request.clone()).await {
            Ok(response) => return Ok(response),
            Err(e) if e.is_retryable() => {
                self.set_cooldown("primary");
                last_error = Some(e);
            }
            Err(e) => return Err(e),  // 非重试错误，直接返回
        }
    }

    // 2. 尝试 fallbacks
    for (i, fallback) in self.fallbacks.iter().enumerate() {
        let name = format!("fallback_{}", i);
        if !self.is_on_cooldown(&name) {
            match fallback.complete(request.clone()).await {
                Ok(response) => {
                    self.clear_cooldown(&name);
                    return Ok(response);
                }
                Err(e) if e.is_retryable() => {
                    self.set_cooldown(&name);
                    last_error = Some(e);
                }
                Err(e) => return Err(e),
            }
        }
    }

    Err(last_error.unwrap_or_else(|| Error::NoAvailableProvider))
}

fn set_cooldown(&self, name: &str) {
    self.cooldowns.insert(name.to_string(), Instant::now() + Duration::from_secs(60));
}
```

**亮点**：
- 无锁 cooldown 跟踪：使用 `DashMap` 避免全局锁
- 智能重试：仅重试可恢复错误（网络超时、速率限制）
- 自动恢复：cooldown 过期后自动重试

---

## 五、实际应用挑战

### 5.1 性能瓶颈

**问题**：WASM 工具每次执行都创建新实例，频繁 GC 可能影响性能。

**缓解措施**：
- 使用 `wasmtime::InstanceLimitStore` 限制并发实例数
- 设置合理的 fuel limit，防止长时间运行
- 对高频工具使用连接池模式（需谨慎处理状态隔离）

### 5.2 安全权衡

**问题**：WASM 沙箱安全但功能受限，Docker 功能强但攻击面大。

**建议**：
- 默认使用 WASM 沙箱（90% 场景足够）
- 仅对需要完整系统访问的工具使用 Docker
- 对 Docker 容器实施严格网络策略和资源限制

### 5.3 记忆系统扩展

**问题**：随着记忆增长，向量搜索性能下降。

**优化方向**：
- 实现记忆分层（热/温/冷）
- 使用 HNSW 索引加速近似最近邻搜索
- 定期压缩旧记忆（自动摘要）

---

## 六、技术总结与启示

### 6.1 架构设计最佳实践

1. **沙箱优先**：不可信代码必须在隔离环境运行
2. **能力声明**：工具通过配置文件声明权限，而非硬编码
3. **零知识凭证**：密钥在宿主边界注入，工具代码永不可见
4. **纵深防御**：多层安全检查（输入净化、策略验证、泄露检测）
5. **上下文隔离**：每个作业独立上下文，避免状态污染

### 6.2 Rust 在 AI 系统的优势

- **内存安全**：无 GC，无数据竞争，适合沙箱系统
- **零成本抽象**：trait 抽象无运行时开销
- **并发安全**：类型系统保证线程安全
- **单二进制**：易于分发和部署

### 6.3 可借鉴的设计模式

| 模式 | 应用场景 | IronClaw 实现 |
|------|---------|--------------|
| 依赖注入 | 解耦组件 | `AgentDeps` 结构体 |
| 外观模式 | 简化接口 | `Agent` 作为统一入口 |
| 策略模式 | 可替换算法 | `SandboxPolicy` |
| 观察者模式 | 事件广播 | SSE 事件流 |
| 工厂模式 | 对象创建 | `LlmProvider` 工厂 |

---

## 结语

IronClaw 展示了一个**安全至上、本地优先**的个人 AI 助手应该如何构建。它通过 WASM 沙箱、Docker 隔离、凭证注入、泄露检测等多层防御机制，实现了真正的"你的数据你做主"。

对于开发者而言，IronClaw 的最大价值在于：
1. **安全设计参考**：如何在 AI 系统中实现纵深防御
2. **Rust 实践案例**：如何用 Rust 构建复杂异步系统
3. **扩展架构思路**：如何通过 WASM 和 MCP 实现动态扩展

在 AI 助手日益中心化的今天，IronClaw 提供了一条不同的道路——一个真正属于用户的、透明的、可信赖的个人 AI 助手。

---

**项目地址**：[https://github.com/nearai/ironclaw](https://github.com/nearai/ironclaw)

**作者**：NEAR AI

**Commit id**：bcbdc273a53351dd2e7f85fbb0a7324e496a7f38
