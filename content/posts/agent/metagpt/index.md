---
title: "MetaGPT 简析"
date: 2026-03-10T08:00:00+08:00
draft: false
tags: [ai generated]
categories: [agent]
---

> **前言**：在 AI Agent 爆发的 2024-2025 年，MetaGPT 作为多智能体协作框架的代表作，开创了"软件公司即多智能体系统"的创新范式。本文将从架构师视角，深度拆解 MetaGPT 的核心模块、设计模式与实现细节，并通过完整的执行流程追踪，揭示其如何将复杂的软件开发流程转化为可协作的多智能体系统。

---

## 一、项目概览与技术栈

### 1.1 项目定位

MetaGPT 是一个**多智能体协作框架**，其核心理念是：

> **Code = SOP(Team)**

通过将标准操作流程（SOP）赋予基于 LLM 的角色团队，实现从"一行需求"到"完整软件项目"的自动化生成。

### 1.2 技术栈分析

```yaml
核心语言：Python 3.9-3.11
LLM 框架：Pydantic (数据验证), OpenAI SDK, Anthropic API 等
异步编程：asyncio
环境模拟：gymnasium (强化学习环境接口)
版本控制：GitPython
文档处理：openpyxl, python_docx, beautifulsoup4
向量数据库：faiss, lancedb, qdrant-client
```

### 1.3 目录结构解析

```
metagpt/
├── actions/           # 动作层：具体任务的执行逻辑
│   ├── write_code.py
│   ├── write_prd.py
│   ├── design_api.py
│   └── ...
├── roles/             # 角色层：产品经理、架构师、工程师等
│   ├── product_manager.py
│   ├── architect.py
│   ├── engineer.py
│   └── ...
├── environment/       # 环境层：角色交互的虚拟环境
│   ├── base_env.py
│   └── software/      # 软件公司环境
├── memory/            # 记忆层：短期/长期记忆管理
├── provider/          # LLM 提供者：封装各厂商 API
├── strategy/          # 策略层：规划、推理等高级策略
├── tools/             # 工具集：浏览器、编辑器等
├── schema.py          # 核心数据结构定义
├── context.py         # 全局上下文管理
└── team.py            # 团队编排入口
```

---

## 二、核心架构流程图

{{< mermaid >}}
graph TB
    User[用户输入需求] --> Team[Team 团队]
    Team --> Env[Environment 环境]
    
    subgraph "环境层"
        Env --> PM[ProductManager]
        Env --> Arch[Architect]
        Env --> Eng[Engineer]
        Env --> QA[QaEngineer]
    end
    
    subgraph "角色核心组件"
        PM --> RC_PM[RoleContext]
        Arch --> RC_Arch[RoleContext]
        Eng --> RC_Eng[RoleContext]
        
        RC_PM --> Memory[Memory 记忆]
        RC_Arch --> Memory
        RC_Eng --> Memory
    end
    
    subgraph "动作执行"
        PM --> WritePRD[WritePRD Action]
        Arch --> WriteDesign[WriteDesign Action]
        Eng --> WriteCode[WriteCode Action]
    end
    
    WritePRD --> LLM[LLM Provider]
    WriteDesign --> LLM
    WriteCode --> LLM
    
    LLM --> Context[Context 上下文]
    Context --> Config[Config 配置]
    Context --> CostManager[CostManager 成本管理]
{{< /mermaid >}}

---

## 三、核心模块深度剖析

## 模块一：角色系统（Role System）

### 功能定义

角色系统是 MetaGPT 的**核心抽象层**，负责：
- 定义不同角色的职责边界（产品经理、架构师、工程师等）
- 管理角色的状态机（思考 - 行动循环）
- 处理角色间的消息传递与协作

### 关键类分析：`Role` 类

```python
# metagpt/roles/role.py
class Role(BaseRole, SerializationMixin, ContextMixin, BaseModel):
    """Role/Agent"""
    
    name: str = ""
    profile: str = ""
    goal: str = ""
    constraints: str = ""
    
    # 核心组件
    actions: list[SerializeAsAny[Action]] = Field(default=[])
    rc: RoleContext = Field(default_factory=RoleContext)
    planner: Planner = Field(default_factory=Planner)
    
    # 反应模式
    rc.react_mode: RoleReactMode = RoleReactMode.REACT
```

**输入输出流程**：

```
观察 (Observe) → 思考 (Think) → 行动 (Act) → 发布消息 (Publish)
     ↓              ↓            ↓            ↓
  msg_buffer    选择 action   执行 run    env.publish_message
```

### 设计模式亮点

#### 1. **状态机模式（State Machine）**

```python
# role.py 中的状态流转
STATE_TEMPLATE = """
Your previous stage: {previous_state}

Now choose one of the following stages:
{states}

Just answer a number between 0-{n_states}
"""
```

角色通过 LLM 动态决定下一个状态，实现**智能状态流转**，而非硬编码的状态机。

#### 2. **观察者模式（Observer Pattern）**

```python
# role.py
def _watch(self, actions: Iterable[Type[Action]]):
    """订阅感兴趣的消息类型"""
    self.rc.watch = {any_to_str(t) for t in actions}

async def _observe(self) -> int:
    """从消息缓冲区筛选感兴趣的消息"""
    self.rc.news = [
        n for n in news 
        if (n.cause_by in self.rc.watch or self.name in n.send_to) 
        and n not in old_messages
    ]
```

每个角色订阅特定类型的消息（如工程师关注 `WriteTasks`），实现**解耦的消息驱动架构**。

#### 3. **策略模式（Strategy Pattern）**

```python
# 三种反应策略
class RoleReactMode(str, Enum):
    REACT = "react"           # 标准 ReAct 循环：think-act 交替
    BY_ORDER = "by_order"     # 按顺序执行动作
    PLAN_AND_ACT = "plan_and_act"  # 先规划后执行
```

不同角色可根据任务特性选择不同策略：
- **产品经理**：`BY_ORDER`（固定流程）
- **工程师**：`REACT`（动态响应）
- **复杂任务**：`PLAN_AND_ACT`（需要全局规划）

---

## 模块二：动作系统（Action System）

### 功能定义

动作是角色执行具体任务的**最小执行单元**，负责：
- 封装 LLM 调用逻辑
- 处理输入输出格式化
- 实现具体业务逻辑（写代码、写文档等）

### 关键类分析：`Action` 基类

```python
# metagpt/actions/action.py
class Action(BaseModel):
    name: str = ""
    i_context: Union[dict, CodingContext, str, None] = ""
    prefix: str = ""  # 作为 system_message
    desc: str = ""
    node: ActionNode = Field(default=None, exclude=True)
    
    async def run(self, *args, **kwargs):
        """子类实现具体逻辑"""
        raise NotImplementedError
```

### 典型动作示例：`WriteCode`

```python
# metagpt/actions/write_code.py
class WriteCode(Action):
    async def run(self, *args, **kwargs):
        # 1. 解析上下文（设计文档、任务文档）
        context = self.i_context  # CodingContext
        
        # 2. 构建 Prompt
        prompt = self._build_prompt(
            context.design_doc.content,
            context.task_doc.content,
            context.code_doc.content  # 已有代码
        )
        
        # 3. 调用 LLM
        code = await self.llm.aask(prompt)
        
        # 4. 返回结构化结果
        return CodingContext(
            filename=context.filename,
            code_doc=Document(content=code)
        )
```

### 设计原则

#### 1. **单一职责原则（SRP）**

每个动作只负责一个具体任务：
- `WritePRD`：只写产品需求文档
- `WriteCode`：只写代码
- `SummarizeCode`：只总结代码

#### 2. **依赖注入（Dependency Injection）**

```python
# action.py
def set_context(self, context: Context):
    """注入全局上下文"""
    self.context = context

def set_llm(self, llm: BaseLLM, override=True):
    """注入 LLM 实例"""
    if override or not self.llm:
        self.llm = llm
```

动作不自己创建依赖，而是由框架注入，便于**测试和配置管理**。

---

## 模块三：环境系统（Environment System）

### 功能定义

环境是角色活动的**虚拟空间**，负责：
- 管理所有角色的生命周期
- 处理消息的路由与分发
- 提供共享状态存储

### 关键类分析：`Environment` 类

```python
# metagpt/environment/base_env.py
class Environment(ExtEnv, BaseModel):
    desc: str = ""  # 环境描述
    roles: dict[str, BaseRole] = {}
    member_addrs: Dict[BaseRole, Set] = {}
    history: Memory = Memory()  # 历史记录
    
    def publish_message(self, message: Message, peekable: bool = True):
        """消息路由核心逻辑"""
        for role, addrs in self.member_addrs.items():
            if is_send_to(message, addrs):
                role.put_message(message)  # 放入角色私有缓冲区
```

### 消息路由机制

```
消息发布 → 遍历所有角色 → 检查地址匹配 → 放入目标角色缓冲区
    ↓
is_send_to(message, addrs)
    ↓
检查 message.send_to 是否包含角色地址
```

### 运行循环

```python
# team.py
async def run(self, n_round=3):
    while n_round > 0:
        if self.env.is_idle:  # 所有角色空闲则结束
            break
        
        await self.env.run()  # 并行执行所有角色的 run()
        n_round -= 1
```

### 设计亮点

#### 1. **地址路由模式**

```python
# 角色可以有多个地址
role.addresses = {any_to_str(self), self.name}

# 消息可以指定多个接收者
message.send_to = {"Engineer", "QaEngineer"}
```

实现**灵活的多播/单播通信**。

#### 2. **异步并发模型**

```python
# environment.py
async def run(self, k=1):
    for _ in range(k):
        futures = []
        for role in self.roles.values():
            if not role.is_idle:
                futures.append(role.run())
        
        if futures:
            await asyncio.gather(*futures)  # 并行执行
```

所有角色**并行执行**，模拟真实团队的并发工作模式。

---

## 模块四：上下文与配置系统（Context & Config）

### 功能定义

提供**全局状态管理**，包括：
- LLM 配置与实例管理
- 成本控制
- 项目路径等运行时参数

### 关键类分析：`Context` 类

```python
# metagpt/context.py
class Context(BaseModel):
    kwargs: AttrDict = AttrDict()  # 动态属性存储
    config: Config = Field(default_factory=Config.default)
    cost_manager: CostManager = CostManager()
    _llm: Optional[BaseLLM] = None
    
    def llm(self) -> BaseLLM:
        """懒加载 LLM 实例"""
        self._llm = create_llm_instance(self.config.llm)
        if self._llm.cost_manager is None:
            self._llm.cost_manager = self._select_costmanager(
                self.config.llm
            )
        return self._llm
```

### 配置优先级

```
环境变量 < ~/.metagpt/config2.yaml < 运行时传入配置
```

### 成本管理

```python
# metagpt/utils/cost_manager.py
class CostManager:
    max_budget: float = 10.0  # 投资上限
    total_cost: float = 0.0
    
    def update_cost(self, tokens, price):
        self.total_cost += tokens * price
        if self.total_cost > self.max_budget:
            raise NoMoneyException(...)
```

### 设计原则

#### 1. **单例模式（Singleton）**

```python
# config2.py
_CONFIG_CACHE = {}

@classmethod
def default(cls):
    if default_config_paths not in _CONFIG_CACHE:
        _CONFIG_CACHE[default_config_paths] = Config(**final)
    return _CONFIG_CACHE[default_config_paths]
```

确保配置全局唯一，避免重复加载。

#### 2. **工厂模式（Factory Pattern）**

```python
# llm_provider_registry.py
def create_llm_instance(config: LLMConfig) -> BaseLLM:
    """根据配置创建对应的 LLM 实例"""
    return LLM_REGISTRY[config.api_type](config)
```

支持多种 LLM 后端（OpenAI、Anthropic、Azure 等）的**无缝切换**。

---

## 模块五：记忆系统（Memory System）

### 功能定义

管理角色的**短期记忆**，负责：
- 存储历史消息
- 支持消息检索与过滤
- 为 LLM 提供上下文

### 关键类分析：`Memory` 类

```python
# metagpt/memory/memory.py
class Memory(BaseModel):
    storage: list[Message] = Field(default_factory=list)
    index: DefaultDict[str, list[Message]] = Field(default_factory=lambda: defaultdict(list))
    
    def add(self, message: Message):
        """添加消息到存储，同时更新索引"""
        if message in self.storage:
            return
        self.storage.append(message)
        if message.cause_by:
            self.index[message.cause_by].append(message)
    
    def get(self, k=0) -> list[Message]:
        """获取最近 k 条消息（k=0 返回全部）"""
        return self.storage[-k:] if k > 0 else self.storage
    
    def get_by_action(self, action) -> list[Message]:
        """返回由指定动作触发的所有消息"""
        index = any_to_str(action)
        return self.index[index]
```

### 记忆类型

```python
# role.py
class RoleContext(BaseModel):
    memory: Memory = Memory()  # 短期记忆
    working_memory: Memory = Memory()  # 工作记忆
    # long_term_memory: LongTermMemory = ...  # 长期记忆（可选）
```

- **短期记忆**：当前会话的历史
- **工作记忆**：规划相关的临时存储
- **长期记忆**：持久化存储（需启用）

### 索引机制详解

```python
# 添加消息时自动建立索引
memory.add(Message(content="PRD", cause_by=WritePRD))
# 内部执行：
self.storage.append(message)
self.index[WritePRD].append(message)

# 快速检索（O(1) 复杂度）
messages = memory.get_by_action(WritePRD)
# 直接返回 self.index[WritePRD]
```

---

## 四、完整执行流程追踪

### 4.1 从用户输入到代码生成的完整链路

让我们通过一个具体例子，追踪 `"Create a 2048 game"` 需求的完整执行流程：

#### 步骤 1：团队初始化

```python
# 用户调用
from metagpt.software_company import generate_repo
repo = generate_repo("Create a 2048 game")

# 内部执行流程
# 1. 创建 Context
ctx = Context(config=Config.default())

# 2. 创建 Team 和 Environment
company = Team(context=ctx)
# Team 内部创建 MGXEnv 或 Environment

# 3. 雇佣角色
company.hire([
    TeamLeader(),      # 团队领导
    ProductManager(),  # 产品经理
    Architect(),       # 架构师
    Engineer2(),       # 工程师
    DataAnalyst(),     # 数据分析师
])

# 4. 投资预算
company.invest(3.0)  # 3 美元预算
```

**详细初始化流程**：

```python
# team.py - Team.__init__()
def __init__(self, context: Context = None, **data: Any):
    super(Team, self).__init__(**data)
    ctx = context or Context()
    
    # 创建环境（使用 MGX 或传统 Environment）
    if not self.env and not self.use_mgx:
        self.env = Environment(context=ctx)
    elif not self.env and self.use_mgx:
        self.env = MGXEnv(context=ctx)
    
    # 如果传入了 roles，调用 hire()
    if "roles" in data:
        self.hire(data["roles"])

# team.py - Team.hire()
def hire(self, roles: list[Role]):
    """Hire roles to cooperate"""
    self.env.add_roles(roles)

# environment.py - Environment.add_roles()
def add_roles(self, roles: Iterable[BaseRole]):
    for role in roles:
        self.roles[role.name] = role
        role.context = self.context  # 注入上下文
        role.set_env(self)           # 设置环境引用
```

#### 步骤 2：发布需求消息

```python
# Team.run() 被调用
await company.run(n_round=5, idea="Create a 2048 game")

# 发布用户需求消息到环境
self.env.publish_message(
    Message(
        content="Create a 2048 game",
        cause_by=UserRequirement  # 标记为用户需求
    )
)
```

**消息发布详细流程**：

```python
# environment.py - Environment.publish_message()
def publish_message(self, message: Message, peekable: bool = True) -> bool:
    logger.debug(f"publish_message: {message.dump()}")
    found = False
    
    # 遍历所有角色，查找消息接收者
    for role, addrs in self.member_addrs.items():
        if is_send_to(message, addrs):
            role.put_message(message)  # 放入角色私有缓冲区
            found = True
    
    if not found:
        logger.warning(f"Message no recipients: {message.dump()}")
    
    self.history.add(message)  # 历史记录，用于调试
    return True

# role.py - Role.put_message()
def put_message(self, message):
    """Place the message into the Role object's private message buffer."""
    if not message:
        return
    self.rc.msg_buffer.push(message)  # 推入异步队列
```

#### 步骤 3：第一轮迭代 - 产品经理响应

**环境调度机制**：

```python
# environment.py - Environment.run()
async def run(self, k=1):
    """处理一次所有信息的运行 - Process all Role runs at once"""
    for _ in range(k):
        futures = []
        for role in self.roles.values():
            if role.is_idle:
                continue
            future = role.run()
            futures.append(future)

        if futures:
            await asyncio.gather(*futures)  # 并行执行所有角色
        
        logger.debug(f"is idle: {self.is_idle}")

# role.py - Role.is_idle 属性
@property
def is_idle(self) -> bool:
    """If true, all actions have been executed."""
    return not self.rc.news and not self.rc.todo and self.rc.msg_buffer.empty()
```

**产品经理完整执行流程**：

```python
# role.py - Role.run()
@role_raise_decorator
async def run(self, with_message=None) -> Message | None:
    """Observe, and think and act based on the results of the observation"""
    
    # 1. 如果有外部消息，先处理
    if with_message:
        msg = None
        if isinstance(with_message, str):
            msg = Message(content=with_message)
        elif isinstance(with_message, Message):
            msg = with_message
        if not msg.cause_by:
            msg.cause_by = UserRequirement
        self.put_message(msg)
    
    # 2. 观察环境（从缓冲区读取消息）
    if not await self._observe():
        # 没有新消息，暂停等待
        logger.debug(f"{self._setting}: no news. waiting.")
        return

    # 3. 思考并行动（ReAct 循环）
    rsp = await self.react()

    # 4. 重置下一个动作
    self.set_todo(None)
    
    # 5. 发布响应消息到环境
    self.publish_message(rsp)
    return rsp
```

**_observe() 详细实现**：

```python
# role.py - Role._observe()
async def _observe(self) -> int:
    """Prepare new messages for processing from the message buffer and other sources."""
    
    # 1. 从缓冲区读取未处理的消息
    news = []
    if self.recovered and self.latest_observed_msg:
        news = self.rc.memory.find_news(observed=[self.latest_observed_msg], k=10)
    if not news:
        news = self.rc.msg_buffer.pop_all()  # 清空缓冲区
    
    # 2. 获取已处理过的消息（用于去重）
    old_messages = [] if not self.enable_memory else self.rc.memory.get()
    
    # 3. 过滤感兴趣的消息
    # Role 通过 rc.watch 订阅特定类型的消息
    self.rc.news = [
        n for n in news 
        if (n.cause_by in self.rc.watch or self.name in n.send_to) 
        and n not in old_messages
    ]
    
    # 4. 如果是 observe_all_msg_from_buffer 模式，保存所有新消息
    if self.observe_all_msg_from_buffer:
        self.rc.memory.add_batch(news)  # 保存所有，但可能不都响应
    else:
        self.rc.memory.add_batch(self.rc.news)  # 只保存感兴趣的消息
    
    # 5. 记录最后观察到的消息（用于恢复状态）
    self.latest_observed_msg = self.rc.news[-1] if self.rc.news else None
    
    # 6. 日志记录
    news_text = [f"{i.role}: {i.content[:20]}..." for i in self.rc.news]
    if news_text:
        logger.debug(f"{self._setting} observed: {news_text}")
    
    return len(self.rc.news)
```

**ProductManager 的订阅配置**：

```python
# roles/product_manager.py
class ProductManager(RoleZero):
    name: str = "Alice"
    profile: str = "Product Manager"
    
    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        
        if self.use_fixed_sop:
            self.enable_memory = False
            # 设置动作序列
            self.set_actions([
                PrepareDocuments(send_to=any_to_str(self)), 
                WritePRD
            ])
            # 订阅特定类型的消息
            self._watch([UserRequirement, PrepareDocuments])
            # 使用固定顺序执行模式
            self.rc.react_mode = RoleReactMode.BY_ORDER
```

**_think() 决策过程**：

```python
# role.py - Role._think()
async def _think(self) -> bool:
    """Consider what to do and decide on the next course of action."""
    
    # 情况 1：只有一个动作，直接执行
    if len(self.actions) == 1:
        self._set_state(0)
        return True

    # 情况 2：从恢复状态继续
    if self.recovered and self.rc.state >= 0:
        self._set_state(self.rc.state)
        self.recovered = False
        return True

    # 情况 3：BY_ORDER 模式 - 按顺序切换动作
    if self.rc.react_mode == RoleReactMode.BY_ORDER:
        if self.rc.max_react_loop != len(self.actions):
            self.rc.max_react_loop = len(self.actions)
        self._set_state(self.rc.state + 1)
        return 0 <= self.rc.state < len(self.actions)

    # 情况 4：REACT 模式 - 使用 LLM 动态选择动作
    prompt = self._get_prefix()
    prompt += STATE_TEMPLATE.format(
        history=self.rc.history,
        states="\n".join(self.states),
        n_states=len(self.states) - 1,
        previous_state=self.rc.state,
    )

    next_state = await self.llm.aask(prompt)
    next_state = extract_state_value_from_output(next_state)
    
    # 验证状态值
    if (not next_state.isdigit() and next_state != "-1") or \
       int(next_state) not in range(-1, len(self.states)):
        logger.warning(f"Invalid answer of state, {next_state=}, will be set to -1")
        next_state = -1
    else:
        next_state = int(next_state)
        if next_state == -1:
            logger.info(f"End actions with {next_state=}")
    
    self._set_state(next_state)
    return True

# _set_state() 实现
def _set_state(self, state: int):
    """Update the current state."""
    self.rc.state = state
    logger.debug(f"actions={self.actions}, state={state}")
    # 设置当前要执行的动作
    self.set_todo(self.actions[self.rc.state] if state >= 0 else None)
```

**_act() 动作执行**：

```python
# role.py - Role._act()
async def _act(self) -> Message:
    logger.info(f"{self._setting}: to do {self.rc.todo}({self.rc.todo.name})")
    
    # 执行动作
    response = await self.rc.todo.run(self.rc.history)
    
    # 根据响应类型创建消息
    if isinstance(response, (ActionOutput, ActionNode)):
        msg = AIMessage(
            content=response.content,
            instruct_content=response.instruct_content,
            cause_by=self.rc.todo,      # 标记由哪个动作产生
            sent_from=self              # 标记发送者
        )
    elif isinstance(response, Message):
        msg = response
    else:
        msg = AIMessage(content=response or "", cause_by=self.rc.todo, sent_from=self)
    
    # 将响应加入记忆
    self.rc.memory.add(msg)
    return msg
```

**WritePRD 动作内部实现**：

```python
# metagpt/actions/write_prd.py
class WritePRD(Action):
    async def run(self, *args, **kwargs) -> ActionOutput:
        # 1. 从历史消息中提取需求
        requirement = self.rc.history.get_by_action(UserRequirement)[0].content
        
        # 2. 构建 Prompt
        prompt = self._build_prompt(requirement)
        
        # 3. 调用 LLM
        prd_content = await self.llm.aask(
            msg=prompt,
            system_msgs=[self.prefix]
        )
        
        # 4. 解析并返回结构化结果（使用 ActionNode）
        node = await self.node.fill(
            req=prd_content,
            llm=self.llm
        )
        
        return ActionOutput(
            content=node.content,
            instruct_content=node.instruct_content
        )
```

**LLM 调用与成本管理**：

```python
# provider/base_llm.py - BaseLLM.aask()
async def aask(
    self,
    msg: Union[str, list[dict[str, str]]],
    system_msgs: Optional[list[str]] = None,
    timeout=USE_CONFIG_TIMEOUT,
    stream=None
) -> str:
    # 1. 构建消息列表
    if system_msgs:
        message = self._system_msgs(system_msgs)
    else:
        message = [self._default_system_msg()]
    
    if not self.use_system_prompt:
        message = []
    
    if isinstance(msg, str):
        message.append(self._user_msg(msg))
    else:
        message.extend(msg)
    
    # 2. 日志记录（脱敏 base64 图片数据）
    masked_message = [self.mask_base64_data(m) for m in message]
    logger.debug(masked_message)
    
    # 3. 压缩消息（如果配置启用）
    compressed_message = self.compress_messages(
        message, 
        compress_type=self.config.compress_type
    )
    
    # 4. 调用完成接口
    rsp = await self.acompletion_text(
        compressed_message, 
        stream=stream, 
        timeout=self.get_timeout(timeout)
    )
    
    return rsp

# provider/base_llm.py - BaseLLM._update_costs()
def _update_costs(self, usage: Union[dict, BaseModel], model: str = None):
    """update each request's token cost"""
    calc_usage = self.config.calc_usage
    
    if calc_usage and self.cost_manager and usage:
        try:
            prompt_tokens = int(usage.get("prompt_tokens", 0))
            completion_tokens = int(usage.get("completion_tokens", 0))
            self.cost_manager.update_cost(
                prompt_tokens, 
                completion_tokens, 
                model
            )
        except Exception as e:
            logger.error(f"{self.__class__.__name__} updates costs failed! exp: {e}")

# utils/cost_manager.py - CostManager.update_cost()
def update_cost(self, prompt_tokens: int, completion_tokens: int, model: str):
    """Update total cost and check budget"""
    cost = self.get_cost(prompt_tokens, completion_tokens, model)
    self.total_cost += cost
    
    if self.total_cost > self.max_budget:
        raise NoMoneyException(
            self.total_cost, 
            f"Insufficient funds: {self.max_budget}"
        )
```

#### 步骤 4：第二轮迭代 - 架构师响应

**消息传递机制**：

```python
# 产品经理发布 PRD 消息后
# Environment.publish_message() 遍历所有角色
for role, addrs in self.member_addrs.items():
    if is_send_to(message, addrs):
        role.put_message(message)

# Architect 订阅了 WritePRD 产生的消息
Architect.rc.watch = {WritePRD, ...}

# 消息的 cause_by=WritePRD，匹配成功，进入 Architect 缓冲区
# is_send_to() 实现
def is_send_to(message: Message, addrs: Set[str]) -> bool:
    """Check if message is sent to any of the addresses"""
    return bool(message.send_to & addrs)
```

**架构师执行流程**：

```python
# Architect._think()
async def _think(self):
    # 选择 WriteSystemDesign 动作
    self._set_state(0)
    self.set_todo(WriteSystemDesign())
    return True

# WriteSystemDesign.run()
async def run(self):
    # 1. 从记忆获取 PRD
    prd = self.rc.memory.get_by_action(WritePRD)[0]
    
    # 2. 构建系统设计 Prompt
    prompt = f"""
## Requirements
{prd.content}

## Task
Design system architecture with:
- Module decomposition
- Data structures
- API interfaces
"""
    
    # 3. 调用 LLM
    design = await self.llm.aask(prompt)
    
    # 4. 保存设计文档到仓库
    await self.repo.docs.system_design.save(
        filename="system_design.md",
        content=design,
        dependencies=["requirements.md"]
    )
```

#### 步骤 5：第三轮迭代 - 工程师编写代码

**任务分解（ProjectManager）**：

```python
# WriteTasks.run()
async def run(self):
    # 1. 获取 PRD 和设计文档
    prd = self.rc.memory.get_by_action(WritePRD)[0]
    design = self.rc.memory.get_by_action(WriteSystemDesign)[0]
    
    # 2. 调用 LLM 分解任务
    task_list = await self.llm.aask(f"""
Based on the design, create a task list:
{design.content}

Return JSON format:
{{
    "task_list": [
        "main.py - Game main loop",
        "game.py - Game logic",
        "ui.py - User interface"
    ]
}}
""")
    
    # 3. 保存任务文件
    await self.repo.docs.task.save(
        filename="tasks.json",
        content=task_list
    )
```

**工程师并行编码详细流程**：

```python
# Engineer._new_code_actions()
async def _new_code_actions(self):
    # 1. 获取所有任务文件
    task_list = self._parse_tasks(task_doc)
    # ["main.py", "game.py", "ui.py"]
    
    # 2. 获取依赖关系
    dependency = await self.repo.git_repo.get_dependency()
    
    # 3. 为每个任务创建 WriteCode 动作
    changed_files = Documents()
    for task_filename in task_list:
        # 创建编码上下文
        context = CodingContext(
            filename=task_filename,
            design_doc=design_doc,
            task_doc=task_doc,
            code_doc=Document(content="")  # 初始为空
        )
        
        coding_doc = Document(
            root_path=str(self.repo.src_relative_path),
            filename=task_filename,
            content=context.model_dump_json()
        )
        
        changed_files.docs[task_filename] = coding_doc
    
    # 4. 创建动作列表
    self.code_todos = [
        WriteCode(
            i_context=coding_doc, 
            repo=self.repo, 
            input_args=self.input_args, 
            context=self.context, 
            llm=self.llm
        )
        for coding_doc in changed_files.docs.values()
    ]
    
    # 5. 设置第一个待办
    if self.code_todos:
        self.set_todo(self.code_todos[0])
```

**WriteCode.run() 详细实现**：

```python
# actions/write_code.py - WriteCode.run()
@retry(wait=wait_random_exponential(min=1, max=60), stop=stop_after_attempt(6))
async def run(self, *args, **kwargs) -> CodingContext:
    # 1. 加载编码上下文
    coding_context = CodingContext.loads(self.i_context.content)
    
    # 2. 获取相关文档
    design_doc = coding_context.design_doc      # 系统设计
    task_doc = coding_context.task_doc          # 当前任务
    
    # 3. 获取测试输出（如果有）
    test_doc = await self.repo.test_outputs.get(
        filename="test_" + coding_context.filename + ".json"
    )
    
    # 4. 获取日志（如果有测试错误）
    logs = ""
    if test_doc:
        test_detail = RunCodeResult.loads(test_doc.content)
        logs = test_detail.stderr
    
    # 5. 获取相关代码上下文（避免重复）
    code_context = await self.get_codes(
        task_doc=task_doc,
        exclude=self.i_context.filename,
        project_repo=self.repo
    )
    
    # 6. 构建详细 Prompt
    prompt = PROMPT_TEMPLATE.format(
        design=design_doc.content,
        task=task_doc.content,
        code=code_context,
        logs=logs,
        filename=self.i_context.filename,
        demo_filename=Path(self.i_context.filename).stem
    )
    
    # 7. 调用 LLM 生成代码
    logger.info(f"Writing {coding_context.filename}..")
    code = await self.write_code(prompt)
    
    # 8. 保存代码
    coding_context.code_doc.content = code
    await self.repo.srcs.save(
        filename=coding_context.filename,
        content=code
    )
    
    return coding_context

# WriteCode.write_code()
async def write_code(self, prompt) -> str:
    # 调用 LLM
    code_rsp = await self._aask(prompt)
    
    # 解析代码（从 Markdown 代码块中提取）
    code = CodeParser.parse_code(text=code_rsp)
    return code

# utils/common.py - CodeParser.parse_code()
@classmethod
def parse_code(cls, text: str, lang: str = "") -> str:
    """Parse code from Markdown code block"""
    pattern = rf'```{lang}.*?\n([\s\S]*?)```'
    match = re.search(pattern, text)
    if match:
        return match.group(1).strip()
    return text
```

**获取相关代码的机制**：

```python
# WriteCode.get_codes()
@staticmethod
async def get_codes(
    task_doc: Document, 
    exclude: str, 
    project_repo: ProjectRepo
) -> str:
    """
    Get codes for generating the exclude file in various scenarios.
    
    核心思想：编写一个文件时，需要参考其他已存在的文件
    """
    if not task_doc:
        return ""
    
    # 解析任务列表
    m = json.loads(task_doc.content)
    code_filenames = m.get(TASK_LIST.key, [])
    
    codes = []
    src_file_repo = project_repo.srcs
    
    # 遍历所有代码文件
    for filename in code_filenames:
        # 排除当前正在编写的文件
        if filename == exclude:
            continue
        
        # 从仓库读取文件
        doc = await src_file_repo.get(filename=filename)
        if not doc:
            continue
        
        # 获取 Markdown 代码块类型
        code_block_type = get_markdown_code_block_type(filename)
        
        # 添加到上下文
        codes.append(
            f"### File Name: `{filename}`\n"
            f"```{code_block_type}\n{doc.content}```\n\n"
        )
    
    return "\n".join(codes)
```

#### 步骤 6：代码审查与总结

**SummarizeCode 详细流程**：

```python
# Engineer._new_summarize_actions()
async def _new_summarize_actions(self):
    # 1. 获取所有源代码文件
    src_files = self.repo.srcs.all_files
    
    # 2. 为每对 (system_design_doc, task_doc) 生成 SummarizeCode 动作
    summarizations = defaultdict(list)
    for filename in src_files:
        # 获取依赖关系
        dependencies = await self.repo.srcs.get_dependency(filename=filename)
        
        # 创建上下文
        ctx = CodeSummarizeContext.loads(filenames=list(dependencies))
        summarizations[ctx].append(filename)
    
    # 3. 创建动作
    for ctx, filenames in summarizations.items():
        ctx.codes_filenames = filenames
        new_summarize = SummarizeCode(
            i_context=ctx, 
            repo=self.repo, 
            input_args=self.input_args, 
            context=self.context, 
            llm=self.llm
        )
        self.summarize_todos.append(new_summarize)
    
    if self.summarize_todos:
        self.set_todo(self.summarize_todos[0])

# SummarizeCode.run()
async def run(self):
    ctx: CodeSummarizeContext = self.i_context
    
    # 1. 读取所有相关代码
    codes = []
    for filename in ctx.codes_filenames:
        doc = await self.repo.srcs.get(filename)
        if doc:
            codes.append(f"## {filename}\n```python\n{doc.content}\n```")
    
    # 2. 读取设计和任务文档
    design_doc = await self.repo.docs.system_design.get(ctx.design_filename)
    task_doc = await self.repo.docs.task.get(ctx.task_filename)
    
    # 3. 构建审查 Prompt
    prompt = f"""
## Design
{design_doc.content}

## Task
{task_doc.content}

## Codes
{'\n'.join(codes)}

## Review Checklist
1. Is the code complete?
2. Does it follow the design?
3. Are there any TODOs left?
4. Is the code modular and maintainable?
"""
    
    # 4. 调用 LLM 审查
    summary = await self.llm.aask(prompt)
    
    # 5. 保存审查结果
    await self.repo.resources.code_summary.save(
        filename=ctx.design_filename + ".md",
        content=summary,
        dependencies=[ctx.design_filename, ctx.task_filename] + ctx.codes_filenames
    )
    
    # 6. 判断是否通过审查
    is_pass, reason = await self._is_pass(summary)
    if not is_pass:
        # 需要修复，触发重新编码
        logger.warning(f"Code review failed: {reason}")
    
    return summary
```

### 4.2 消息流转时序图

```
┌──────┐      ┌───────────┐      ┌──────────────┐    ┌───────────┐    ┌──────────┐
│ 用户  │      │ Environment │      │ ProductManager │    │ Architect │    │ Engineer │
└──┬───┘      └─────┬─────┘      └──────┬───────┘    └─────┬─────┘    └────┬─────┘
   │                │                    │                 │               │
   │ 发布需求        │                    │                 │               │
   ├───────────────>│                    │                 │               │
   │                │                    │                 │               │
   │                │ 广播消息            │                 │               │
   │                ├───────────────────>│                 │               │
   │                │                    │                 │               │
   │                │                    │ _observe()      │               │
   │                │                    │ - pop msg       │               │
   │                │                    │ - filter watch  │               │
   │                │                    │ - add memory    │               │
   │                │                    │                 │               │
   │                │                    │ _think()        │               │
   │                │                    │ - select action │               │
   │                │                    │                 │               │
   │                │                    │ WritePRD        │               │
   │                │                    │ - call LLM      │               │
   │                │                    │                 │               │
   │                │ 发布 PRD 消息        │                 │               │
   │                │<───────────────────┤                 │               │
   │                │                    │                 │               │
   │                │ 广播消息            │                 │               │
   │                ├──────────────────────────────────>│               │
   │                │                    │                 │               │
   │                │                    │                 │ _observe()    │
   │                │                    │                 │ _think()      │
   │                │                    │                 │ WriteDesign   │
   │                │                    │                 │               │
   │                │ 发布设计消息        │                 │               │
   │                │<───────────────────────────────────│               │
   │                │                    │                 │               │
   │                │ 广播消息            │                 │               │
   │                ├───────────────────────────────────────────────────>│
   │                │                    │                 │               │
   │                │                    │                 │               │ _observe()
   │                │                    │                 │               │ _think()
   │                │                    │                 │               │ WriteCode
   │                │                    │                 │               │
   │                │<────────────────────────────────────────────────────│
   │                │                    │                 │               │ 发布代码
```

### 4.3 内存与状态管理

#### RoleContext 状态变化追踪

```python
# 初始状态
rc.state = -1              # 未开始
rc.todo = None             # 无待办
rc.msg_buffer = []         # 空缓冲区
rc.memory.storage = []     # 空记忆
rc.news = []               # 无新消息

# =====================
# 收到消息后
# =====================
rc.msg_buffer = [
    Message(
        content="Create 2048 game",
        cause_by=UserRequirement,
        id="msg_001"
    )
]

# =====================
# _observe() 后
# =====================
rc.msg_buffer = []  # 已清空
rc.memory.storage = [
    Message(content="Create 2048 game", cause_by=UserRequirement)
]
rc.news = [
    Message(content="Create 2048 game", cause_by=UserRequirement)
]
rc.latest_observed_msg = Message(...)  # 记录最后观察到的消息

# =====================
# _think() 后（BY_ORDER 模式）
# =====================
rc.state = 0  # 指向第一个动作
rc.todo = PrepareDocuments()  # 设置待办

# =====================
# _act() 后
# =====================
rc.memory.storage.append(
    AIMessage(
        content="PRD document...",
        cause_by=WritePRD,
        sent_from=ProductManager
    )
)
rc.state = 1  # 指向下一个动作
rc.todo = WritePRD()
```

#### 消息去重机制

```python
# memory/memory.py - Memory.find_news()
def find_news(self, observed: list[Message], k=0) -> list[Message]:
    """
    find news (previously unseen messages) from the most recent k memories
    
    用于恢复状态时，找出上次观察后的新消息
    """
    already_observed = self.get(k)  # 获取已观察过的消息
    news: list[Message] = []
    
    for i in observed:
        if i in already_observed:
            continue  # 跳过已观察的
        news.append(i)
    
    return news

# 使用场景：角色从断点恢复
async def _observe(self):
    if self.recovered and self.latest_observed_msg:
        # 从最后观察到的消息开始，找新消息
        news = self.rc.memory.find_news(
            observed=[self.latest_observed_msg], 
            k=10
        )
```

---

## 五、LLM 调用与 Prompt 工程

### 5.1 BaseLLM 调用链

```python
# 调用链：Role._think() -> LLM.aask() -> LLM.acompletion_text() -> LLM._achat_completion()

# 1. Role._think() 调用
prompt = self._get_prefix() + STATE_TEMPLATE.format(...)
next_state = await self.llm.aask(prompt)

# 2. BaseLLM.aask()
async def aask(self, msg: str, system_msgs: list[str] = None):
    # 构建完整消息
    message = [
        {"role": "system", "content": self.system_prompt},
        {"role": "user", "content": msg}
    ]
    
    # 压缩（如果配置启用）
    compressed_message = self.compress_messages(
        message,
        compress_type=self.config.compress_type
    )
    
    # 调用完成
    rsp = await self.acompletion_text(compressed_message, stream=True)
    return rsp

# 3. BaseLLM.acompletion_text()
async def acompletion_text(self, messages: list[dict], stream: bool = False):
    if stream:
        return await self._achat_completion_stream(messages)
    resp = await self._achat_completion(messages)
    return self.get_choice_text(resp)

# 4. 具体实现（如 OpenAI API）
# provider/openai_api.py
async def _achat_completion(self, messages: list[dict]):
    kwargs = self._make_request_kwargs(messages=messages)
    rsp = await self.aclient.chat.completions.create(**kwargs)
    
    # 更新成本
    self._update_costs(rsp.usage)
    
    return rsp.model_dump()

# 5. 提取响应文本
def get_choice_text(self, rsp: dict) -> str:
    return rsp["choices"][0]["message"]["content"]
```

### 5.2 Prompt 压缩策略

```python
# provider/base_llm.py - BaseLLM.compress_messages()
def compress_messages(
    self,
    messages: list[dict],
    compress_type: CompressType = CompressType.NO_COMPRESS,
    max_token: int = 128000,
    threshold: float = 0.8
) -> list[dict]:
    """Compress messages to fit within the token limit."""
    
    if compress_type == CompressType.NO_COMPRESS:
        return messages
    
    # 计算保留的 token 数
    max_token = TOKEN_MAX.get(self.model, max_token)
    keep_token = int(max_token * threshold)  # 保留 80%
    
    compressed = []
    
    # 始终保留系统消息
    system_msgs = [msg for msg in messages if msg["role"] == "system"]
    compressed.extend(system_msgs)
    current_token_count = self.count_tokens(system_msgs)
    
    if compress_type == CompressType.POST_CUT_BY_TOKEN:
        # 从后往前保留消息，超出则截断
        for i, msg in enumerate(reversed(user_assistant_msgs)):
            token_count = self.count_tokens([msg])
            if current_token_count + token_count <= keep_token:
                compressed.insert(len(system_msgs), msg)
                current_token_count += token_count
            else:
                # 截断消息
                truncated_content = msg["content"][-(keep_token - current_token_count):]
                compressed.insert(len(system_msgs), {
                    "role": msg["role"], 
                    "content": truncated_content
                })
                break
    
    elif compress_type == CompressType.PRE_CUT_BY_TOKEN:
        # 从前往后保留消息，超出则截断
        for msg in user_assistant_msgs:
            token_count = self.count_tokens([msg])
            if current_token_count + token_count <= keep_token:
                compressed.append(msg)
                current_token_count += token_count
            else:
                truncated_content = msg["content"][:keep_token - current_token_count]
                compressed.append({
                    "role": msg["role"], 
                    "content": truncated_content
                })
                break
    
    return compressed
```

---

## 六、Planner 规划器详解

### 6.1 Planner 工作流程

```python
# strategy/planner.py
class Planner(BaseModel):
    plan: Plan
    working_memory: Memory = Memory()
    auto_run: bool = False
    
    async def update_plan(self, goal: str = "", max_tasks: int = 3):
        """更新计划"""
        if goal:
            self.plan = Plan(goal=goal)
        
        plan_confirmed = False
        while not plan_confirmed:
            # 1. 获取有用记忆
            context = self.get_useful_memories()
            
            # 2. 生成计划
            rsp = await WritePlan().run(context, max_tasks=max_tasks)
            self.working_memory.add(Message(content=rsp, role="assistant"))
            
            # 3. 预检查计划有效性
            is_plan_valid, error = precheck_update_plan_from_rsp(rsp, self.plan)
            if not is_plan_valid:
                # 无效则重试
                self.working_memory.add(Message(content=error, role="assistant"))
                continue
            
            # 4. 请求审查
            _, plan_confirmed = await self.ask_review(
                trigger=ReviewConst.TASK_REVIEW_TRIGGER
            )
        
        # 5. 更新计划
        update_plan_from_rsp(rsp=rsp, current_plan=self.plan)
        self.working_memory.clear()
    
    async def process_task_result(self, task_result: TaskResult):
        """处理任务结果"""
        # 1. 请求审查
        review, task_result_confirmed = await self.ask_review(task_result)
        
        if task_result_confirmed:
            # 确认完成，标记任务
            await self.confirm_task(self.current_task, task_result, review)
        elif "redo" in review:
            # 需要重做
            pass
        else:
            # 需要修改计划
            await self.update_plan()
```

### 6.2 Plan 数据结构

```python
# schema.py
class Plan(BaseModel):
    goal: str                    # 目标
    tasks: list[Task] = []       # 任务列表
    task_ids: list[int] = []     # 任务 ID
    current_task_id: str = ""    # 当前任务 ID
    
    def current_task(self) -> Optional[Task]:
        """获取当前任务"""
        return next(
            (task for task in self.tasks if task.task_id == self.current_task_id),
            None
        )
    
    def finish_current_task(self):
        """完成当前任务"""
        if self.current_task:
            self.current_task.is_finished = True
            # 移动到下一个任务
            next_idx = self.task_ids.index(self.current_task_id) + 1
            if next_idx < len(self.task_ids):
                self.current_task_id = self.task_ids[next_idx]
            else:
                self.current_task_id = ""

class Task(BaseModel):
    task_id: str
    instruction: str      # 任务指令
    task_type: str        # 任务类型
    code: str = ""        # 生成的代码
    result: str = ""      # 执行结果
    is_finished: bool = False
    
    def update_task_result(self, task_result: TaskResult):
        """更新任务结果"""
        self.code = task_result.code
        self.result = task_result.result
```

---

## 七、技术亮点与难点

### 7.1 并发处理：异步消息驱动架构

**挑战**：多个角色需要并行工作，且消息传递不能阻塞。

**解决方案**：
```python
# 每个角色有独立的消息缓冲区
class RoleContext:
    msg_buffer: MessageQueue = MessageQueue()  # 异步队列
    
# 角色运行时从缓冲区读取，而非直接接收
async def _observe(self):
    news = self.rc.msg_buffer.pop_all()
```

### 7.2 状态一致性：SOP 流程控制

**挑战**：如何确保多智能体按正确顺序协作？

**解决方案**：
```python
# 通过 watch 机制控制消息订阅
class ProductManager:
    def __init__(self):
        self._watch([UserRequirement, PrepareDocuments])
        self.set_actions([PrepareDocuments, WritePRD])
        self.rc.react_mode = RoleReactMode.BY_ORDER  # 固定顺序
```

产品经理必须按 `PrepareDocuments → WritePRD` 的顺序执行，确保流程正确。

### 7.3 成本控制：多层级预算管理

```python
# 团队级预算
class Team:
    def invest(self, investment: float):
        self.cost_manager.max_budget = investment
    
    def _check_balance(self):
        if self.cost_manager.total_cost >= self.cost_manager.max_budget:
            raise NoMoneyException(...)

# 每轮运行前检查
await self.env.run()
self._check_balance()
```

### 7.4 可扩展性：插件化设计

**工具注册机制**：
```python
# metagpt/tools/tool_registry.py
def register_tool(name):
    """注册新工具"""
    TOOL_REGISTRY[name] = func

# 角色动态加载工具
class RoleZero:
    tools: list[str] = ["Browser", "Editor"]
    
    def _load_tools(self):
        for tool_name in self.tools:
            self.tool_execution_map[tool_name] = TOOL_REGISTRY[tool_name]
```

---

## 八、设计模式总结

### 8.1 责任链模式（Chain of Responsibility）

```python
# 消息处理链
User -> Environment -> Role._observe() -> Role._think() -> Role._act() -> Environment

# 每个环节处理特定职责
# _observe: 过滤消息
# _think: 决策动作
# _act: 执行动作
```

### 8.2 命令模式（Command Pattern）

```python
# Action 作为命令
class Action(BaseModel):
    name: str
    i_context: Any
    async def run(self): ...

# Role 作为调用者
class Role(BaseModel):
    rc: RoleContext  # 包含 todo (当前命令)
    
    async def _act(self):
        response = await self.rc.todo.run()  # 执行命令
```

### 8.3 发布 - 订阅模式（Pub-Sub）

```python
# Environment 作为消息总线
class Environment:
    def publish_message(self, message):
        for role, addrs in self.member_addrs.items():
            if is_send_to(message, addrs):
                role.put_message(message)  # 推送给订阅者

# Role 作为订阅者
class Role:
    rc.watch: Set[str]  # 订阅的主题
    
    def _watch(self, actions):
        self.rc.watch = {any_to_str(t) for t in actions}
```

### 8.4 设计模式应用总览

| 模式 | 应用场景 | 收益 |
|------|---------|------|
| 策略模式 | RoleReactMode | 灵活切换反应策略 |
| 观察者模式 | _watch 机制 | 解耦消息生产与消费 |
| 工厂模式 | create_llm_instance | 支持多 LLM 后端 |
| 单例模式 | Config.default() | 全局配置一致性 |
| 状态机模式 | Role 状态流转 | 智能流程控制 |
| 命令模式 | Action | 统一动作接口 |
| 责任链模式 | Observe-Think-Act | 清晰的处理流程 |

---

## 九、调试技巧

### 9.1 启用详细日志

```python
# 在 config2.yaml 中配置
llm:
  api_type: "openai"
  # ...

# 运行前设置日志级别
import logging
logging.getLogger("metagpt").setLevel(logging.DEBUG)
```

### 9.2 查看消息流转

```python
# 在 Environment 中添加钩子
original_publish = env.publish_message

def debug_publish(msg):
    print(f"[MSG] {msg.cause_by} -> {msg.send_to}: {msg.content[:50]}...")
    return original_publish(msg)

env.publish_message = debug_publish
```

### 9.3 检查角色状态

```python
# 检查角色状态
for role_name, role in env.roles.items():
    print(f"{role_name}:")
    print(f"  state={role.rc.state}")
    print(f"  todo={role.rc.todo}")
    print(f"  msg_buffer_size={len(role.rc.msg_buffer)}")
    print(f"  memory_size={role.rc.memory.count()}")
```

### 9.4 性能优化建议

1. **减少上下文长度**：
   - 使用 `memory.get(k=10)` 只获取最近 10 条消息
   - 启用 `CompressType.POST_CUT_BY_TOKEN` 压缩长消息

2. **并行执行**：
   - 工程师的多个 WriteCode 任务可并行执行
   - 使用 `asyncio.gather()` 而非顺序执行

3. **缓存策略**：
   - 配置中启用 `enable_longterm_memory` 避免重复计算
   - 使用 Redis 存储大型项目的中间状态

---

## 十、技术总结与启示

### 10.1 架构设计最佳实践

1. **分层清晰**：Role → Action → LLM，职责边界明确
2. **消息驱动**：通过消息解耦角色间依赖
3. **配置优先**：所有行为可通过配置调整，无需修改代码
4. **异步优先**：充分利用 asyncio 提高并发性能

### 10.2 给开发者的启示

1. **SOP 即代码**：将业务流程标准化，然后自动化
2. **角色分离**：不同职责由不同 Agent 承担，降低单个 Agent 的复杂度
3. **消息路由**：通过消息而非直接调用来协调多 Agent
4. **成本控制**：在 AI 应用中，成本管理与性能优化同等重要

### 10.3 实际应用挑战

**LLM 调用成本**
- **问题**：每轮对话都需要调用 LLM，成本随轮次线性增长
- **缓解**：
  - 启用长期记忆减少上下文长度
  - 使用更便宜的模型处理简单任务
  - 优化 Prompt 减少 token 消耗

**错误恢复**
- **问题**：LLM 输出格式错误导致流程中断
- **缓解**：
  ```python
  # metagpt/utils/repair_llm_raw_output.py
  def extract_state_value_from_output(output: str) -> str:
      """修复 LLM 输出的状态值"""
      # 使用正则提取数字
  ```

**并发冲突**
- **问题**：多个角色同时修改同一文件
- **缓解**：
  - 使用 Git 进行版本控制
  - 通过消息路由确保串行访问

---

## 结语

MetaGPT 不仅仅是一个多智能体框架，更是对**软件生产流程**的一次重新思考。它通过精心设计的 SOP 和角色分工，将复杂的软件开发任务分解为可协作的多智能体系统。

通过本文的详细剖析，相信你已经对 MetaGPT 的内部运行机制有了深入理解。从用户输入一行需求，到最终生成完整代码，整个过程涉及：

1. **消息驱动**：通过消息队列解耦角色间通信
2. **状态管理**：RoleContext 维护角色运行状态
3. **记忆索引**：Memory 提供高效的消息检索
4. **LLM 调用**：统一的 API 抽象与成本管理
5. **规划执行**：Planner 负责任务分解与进度跟踪

其架构设计的精妙之处在于：
- **简单性**：核心抽象（Role、Action、Environment）清晰易懂
- **可扩展性**：通过插件化设计支持新角色、新工具
- **实用性**：已生成数千个真实项目，经过生产环境验证

对于希望构建多智能体系统的开发者，MetaGPT 提供了宝贵的参考范式：**不是让一个 LLM 做所有事，而是让多个 specialized agent 协作完成复杂任务**。

掌握这些机制后，你可以：
- 更好地调试多智能体系统
- 自定义角色和动作
- 优化 Prompt 和上下文管理
- 扩展新的协作模式

---

**参考文献**：
1. [MetaGPT GitHub](https://github.com/geekan/MetaGPT)
2. [MetaGPT 论文](https://openreview.net/forum?id=VtmBAGCN7o)
3. [ReAct 论文](https://arxiv.org/abs/2210.03629)
4. [RFC 116 - MetaGPT 架构文档](https://github.com/geekan/MetaGPT/blob/main/docs/README_CN.md)

---

**项目地址**：[https://github.com/FoundationAgents/MetaGPT](https://github.com/FoundationAgents/MetaGPT)

**Commit id**：11cdf466d042aece04fc6cfd13b28e1a70341b1f
