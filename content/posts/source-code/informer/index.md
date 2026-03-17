---
title: "Kubernetes Client-Go SharedInformer"
date: 2026-03-17T15:00:00+08:00
draft: false
tags: [ai generated, kubernetes]
categories: [source code]
---
# Kubernetes Client-Go SharedIndexInformer 深度解析

> 本文深入分析 Kubernetes client-go 库中 `SharedIndexInformer` 接口的实现原理、架构设计和核心工作机制

## 概述

`SharedIndexInformer` 是 Kubernetes client-go 库中用于监听和缓存 Kubernetes 资源变化的核心组件。它是 Kubernetes 控制器模式（Controller Pattern）的基石，广泛应用于 Kubernetes 控制平面和各类 Operator 中。

### 核心特性

- **共享性（Shared）**：多个消费者可以共享同一个 Informer 的缓存，避免重复的 API Server 调用
- **索引能力（Index）**：支持自定义索引，提供高效的对象查询能力
- **最终一致性**：保证本地缓存与 API Server 状态的最终一致性
- **事件通知**：提供 Add、Update、Delete 三种事件通知机制

---

## 接口定义

### SharedIndexInformer 接口

```go
// vendor/k8s.io/client-go/tools/cache/shared_informer.go:267
type SharedIndexInformer interface {
    SharedInformer
    AddIndexers(indexers Indexers) error
    GetIndexer() Indexer
}
```

`SharedIndexInformer` 继承了 `SharedInformer` 接口，并添加了索引相关的方法。让我们先看看 `SharedInformer` 的核心方法：

```go
// vendor/k8s.io/client-go/tools/cache/shared_informer.go:130
type SharedInformer interface {
    // 添加事件处理器
    AddEventHandler(handler ResourceEventHandler) (ResourceEventHandlerRegistration, error)
    AddEventHandlerWithResyncPeriod(handler ResourceEventHandler, resyncPeriod time.Duration) (ResourceEventHandlerRegistration, error)
    AddEventHandlerWithOptions(handler ResourceEventHandler, options HandlerOptions) (ResourceEventHandlerRegistration, error)
    
    // 移除事件处理器
    RemoveEventHandler(handle ResourceEventHandlerRegistration) error
    
    // 获取存储
    GetStore() Store
    GetController() Controller
    
    // 运行控制循环
    Run(stopCh <-chan struct{})
    RunWithContext(ctx context.Context)
    
    // 同步状态
    HasSynced() bool
    LastSyncResourceVersion() string
    
    // 错误处理
    SetWatchErrorHandler(handler WatchErrorHandler) error
    SetWatchErrorHandlerWithContext(handler WatchErrorHandlerWithContext) error
    
    // 对象转换
    SetTransform(handler TransformFunc) error
    
    // 状态查询
    IsStopped() bool
}
```

### 事件处理器接口

```go
// vendor/k8s.io/client-go/tools/cache/controller.go:227
type ResourceEventHandler interface {
    OnAdd(obj interface{}, isInInitialList bool)
    OnUpdate(oldObj, newObj interface{})
    OnDelete(obj interface{})
}
```

---

## 核心架构

`sharedIndexInformer` 的实现包含**三大核心组件**：

```
┌─────────────────────────────────────────────────────────────────┐
│                    sharedIndexInformer                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │
│  │   Indexer   │  │ Controller  │  │   sharedProcessor       │ │
│  │   (本地缓存) │  │ (控制器)    │  │   (事件分发器)          │ │
│  │             │  │             │  │                         │ │
│  │ - 存储对象  │  │ - Reflector │  │ - processorListener     │ │
│  │ - 多索引   │  │ - DeltaFIFO │  │ - 事件队列              │ │
│  │ - 查询接口 │  │ - Process   │  │ - 事件分发              │ │
│  └──────┬──────┘  └──────┬──────┘  └───────────┬─────────────┘ │
│         │                │                      │               │
│         └────────────────┼──────────────────────┘               │
│                          │                                      │
│                  HandleDeltas()                                 │
└──────────────────────────┼──────────────────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │   ListerWatcher        │
              │   (API Server 交互)     │
              └────────────────────────┘
```

### 组件职责

| 组件 | 职责 |
|------|------|
| **Indexer** | 本地缓存存储，支持多索引查询 |
| **Controller** | 驱动 Reflector 和 DeltaFIFO，处理对象变更 |
| **sharedProcessor** | 管理事件监听器，分发事件通知 |

---

## 主要组件详解

### 1. Indexer（索引器）

Indexer 是 `SharedIndexInformer` 的本地缓存，实现了多线程安全的对象存储和索引功能。

#### 接口定义

```go
// vendor/k8s.io/client-go/tools/cache/index.go:27
type Indexer interface {
    Store
    // 索引查询
    Index(indexName string, obj interface{}) ([]interface{}, error)
    IndexKeys(indexName, indexedValue string) ([]string, error)
    ListIndexFuncValues(indexName string) []string
    ByIndex(indexName, indexedValue string) ([]interface{}, error)
    
    // 索引管理
    GetIndexers() Indexers
    AddIndexers(newIndexers Indexers) error
}
```

#### 索引函数

```go
// vendor/k8s.io/client-go/tools/cache/index.go:57
type IndexFunc func(obj interface{}) ([]string, error)

// 内置的命名空间索引函数
func MetaNamespaceIndexFunc(obj interface{}) ([]string, error) {
    meta, err := meta.Accessor(obj)
    if err != nil {
        return []string{""}, fmt.Errorf("object has no meta: %v", err)
    }
    return []string{meta.GetNamespace()}, nil
}
```

#### 数据结构

```go
// 索引器核心结构
type index struct {
    // 索引映射：索引名 -> 索引值 -> Key 集合
    Indexers Indexers  // 索引函数
    Indices  Indices   // 索引结果
    // 存储：Key -> Object
    Items map[string]interface{}
}
```

### 2. Controller（控制器）

Controller 是连接 Reflector 和事件处理的核心组件。

#### 配置结构

```go
// vendor/k8s.io/client-go/tools/cache/controller.go:38
type Config struct {
    // DeltaFIFO 队列
    Queue Queue
    
    // 列表和监听器
    ListerWatcher ListerWatcher
    
    // 处理函数
    Process ProcessFunc
    
    // 对象类型
    ObjectType runtime.Object
    
    // 全量同步周期
    FullResyncPeriod time.Duration
    
    // 是否需要重新同步
    ShouldResync ShouldResyncFunc
    
    // 错误处理
    WatchErrorHandler WatchErrorHandler
    WatchErrorHandlerWithContext WatchErrorHandlerWithContext
}
```

#### 运行逻辑

```go
// vendor/k8s.io/client-go/tools/cache/controller.go:147
func (c *controller) RunWithContext(ctx context.Context) {
    defer utilruntime.HandleCrashWithContext(ctx)
    
    // 关闭队列
    go func() {
        <-ctx.Done()
        c.config.Queue.Close()
    }()
    
    // 创建 Reflector
    r := NewReflectorWithOptions(
        c.config.ListerWatcher,
        c.config.ObjectType,
        c.config.Queue,
        ReflectorOptions{
            ResyncPeriod:    c.config.FullResyncPeriod,
            MinWatchTimeout: c.config.MinWatchTimeout,
            TypeDescription: c.config.ObjectDescription,
            Clock:           c.clock,
        },
    )
    r.ShouldResync = c.config.ShouldResync
    r.WatchListPageSize = c.config.WatchListPageSize
    r.watchErrorHandler = c.config.WatchErrorHandlerWithContext
    
    c.reflectorMutex.Lock()
    c.reflector = r
    c.reflectorMutex.Unlock()
    
    var wg wait.Group
    
    // 启动 Reflector
    wg.StartWithContext(ctx, r.RunWithContext)
    
    // 循环处理队列
    wait.UntilWithContext(ctx, c.processLoop, time.Second)
    wg.Wait()
}

// 处理循环
func (c *controller) processLoop(ctx context.Context) {
    for {
        select {
        case <-ctx.Done():
            return
        default:
            _, err := c.config.Pop(PopProcessFunc(c.config.Process))
            if err != nil {
                if errors.Is(err, ErrFIFOClosed) {
                    return
                }
            }
        }
    }
}
```

### 3. DeltaFIFO（增量先进先出队列）

DeltaFIFO 是连接 Reflector 和 Controller 的桥梁，负责存储对象的变更增量。

#### 核心概念

```go
// Delta 类型定义
type DeltaType string

const (
    Added   DeltaType = "Added"    // 添加
    Updated DeltaType = "Updated"  // 更新
    Deleted DeltaType = "Deleted"  // 删除
    Replaced DeltaType = "Replaced" // 替换（全量同步）
    Sync    DeltaType = "Sync"     // 同步（定期重同步）
)

// Delta 表示单次变更
type Delta struct {
    Type   DeltaType
    Object interface{}
}

// Deltas 是同一对象的多次变更累积
type Deltas []Delta
```

#### 数据结构

```go
// vendor/k8s.io/client-go/tools/cache/delta_fifo.go:97
type DeltaFIFO struct {
    lock sync.RWMutex
    cond sync.Cond
    
    // Key -> Deltas 映射
    items map[string]Deltas
    
    // FIFO 队列（Key 列表）
    queue []string
    
    // 是否已填充
    populated bool
    initialPopulationCount int
    
    keyFunc      KeyFunc
    knownObjects KeyListerGetter
    closed       bool
    emitDeltaTypeReplaced bool
    transformer  TransformFunc
}
```

#### 关键操作

```go
// 添加对象
func (f *DeltaFIFO) Add(obj interface{}) error {
    f.lock.Lock()
    defer f.lock.Unlock()
    f.lock.Unlock()
    
    key, err := f.KeyOf(obj)
    if err != nil {
        return KeyError{obj, err}
    }
    
    // 追加 Added 类型的 Delta
    f.items[key] = append(f.items[key], Delta{Type: Added, Object: obj})
    
    if f.queue == nil {
        return fmt.Errorf("DeltaFIFO was configured with no queue")
    }
    f.addIfNotPresentLocked(key)
    f.cond.Broadcast()
    return nil
}

// 弹出并处理
func (f *DeltaFIFO) Pop(process PopProcessFunc) (interface{}, error) {
    f.lock.Lock()
    defer f.lock.Unlock()
    
    for {
        for len(f.queue) == 0 {
            if f.IsClosed() {
                return nil, ErrFIFOClosed
            }
            f.cond.Wait()
        }
        
        key := f.queue[0]
        f.queue = f.queue[1:]
        
        deltas := f.items[key]
        delete(f.items, key)
        
        err := process(deltas)
        if err != nil {
            // 处理失败时重新加入队列
            f.addIfNotPresentLocked(key)
        }
        return deltas, err
    }
}
```

### 4. Reflector（反射器）

Reflector 负责与 API Server 交互，执行 List 和 Watch 操作。

#### 核心结构

```go
// vendor/k8s.io/client-go/tools/cache/reflector.go:69
type Reflector struct {
    name            string
    typeDescription string
    expectedType    reflect.Type
    expectedGVK     *schema.GroupVersionKind
    
    // 目标存储
    store ReflectorStore
    
    // 列表和监听
    listerWatcher ListerWatcherWithContext
    
    // 退避管理
    backoffManager wait.BackoffManager
    
    // 同步配置
    resyncPeriod    time.Duration
    minWatchTimeout time.Duration
    clock           clock.Clock
    
    // 资源版本跟踪
    lastSyncResourceVersion string
    lastSyncResourceVersionMutex sync.RWMutex
    
    // 错误处理
    watchErrorHandler WatchErrorHandlerWithContext
    
    // 分页配置
    WatchListPageSize int64
    
    // 同步检查
    ShouldResync func() bool
}
```

#### ListAndWatch 流程

```go
// vendor/k8s.io/client-go/tools/cache/reflector.go:433
func (r *Reflector) ListAndWatchWithContext(ctx context.Context) error {
    logger := klog.FromContext(ctx)
    var resourceVersion string
    
    // 1. 执行初始 List
    list, err := r.listWithContext(ctx, "")
    if err != nil {
        return fmt.Errorf("failed to list %v: %w", r.expectedType, err)
    }
    
    // 2. 将列表对象注入存储
    if err := r.syncWith(list.Items, list.ResourceVersion); err != nil {
        return fmt.Errorf("unable to sync list: %w", err)
    }
    
    // 3. 开始 Watch
    watchHandler := r.watchHandler
    if !r.useWatchList {
        watchHandler = r.watchWithManualFallback
    }
    
    return watchHandler(ctx, list, r.resyncPeriod)
}

// 同步列表到存储
func (r *Reflector) syncWith(items []runtime.Object, resourceVersion string) error {
    found := make([]interface{}, 0, len(items))
    for _, item := range items {
        found = append(found, item)
    }
    return r.store.Replace(found, resourceVersion)
}
```

### 5. sharedProcessor（共享处理器）

sharedProcessor 负责管理所有的 processorListener 并分发事件通知。

#### 结构定义

```go
// vendor/k8s.io/client-go/tools/cache/shared_informer.go:814
type sharedProcessor struct {
    listenersStarted bool
    listenersLock    sync.RWMutex
    // 监听器映射
    listeners map[*processorListener]bool
    clock     clock.Clock
    wg        wait.Group
}
```

#### 事件分发

```go
// 分发事件到监听器
func (p *sharedProcessor) distribute(obj interface{}, sync bool) {
    p.listenersLock.RLock()
    defer p.listenersLock.RUnlock()
    
    for listener, isSyncing := range p.listeners {
        switch {
        case !sync:
            // 非同步事件发送给所有监听器
            listener.add(obj)
        case isSyncing:
            // 同步事件只发送给需要同步的监听器
            listener.add(obj)
        default:
            // 跳过不需要同步的监听器
        }
    }
}
```

### 6. processorListener（处理器监听器）

processorListener 是单个事件处理器的封装，使用双 Goroutine 模型处理事件。

#### 结构定义

```go
// vendor/k8s.io/client-go/tools/cache/shared_informer.go:899
type processorListener struct {
    logger klog.Logger
    
    // 双通道设计
    nextCh chan interface{}  // 输出通道
    addCh  chan interface{}  // 输入通道
    
    handler ResourceEventHandler
    syncTracker *synctrack.SingleFileTracker
    
    // 环形缓冲区
    pendingNotifications buffer.RingGrowing
    
    // 重同步配置
    requestedResyncPeriod time.Duration
    resyncPeriod          time.Duration
    nextResync            time.Time
    resyncLock            sync.Mutex
}
```

#### 双 Goroutine 模型

```go
// pop 协程：从 addCh 接收，通过 nextCh 发送
func (p *processorListener) pop() {
    defer utilruntime.HandleCrashWithLogger(p.logger)
    defer close(p.nextCh)
    
    var nextCh chan<- interface{}
    var notification interface{}
    
    for {
        select {
        case nextCh <- notification:
            // 通知已发送
            var ok bool
            notification, ok = p.pendingNotifications.ReadOne()
            if !ok {
                nextCh = nil
            }
        case notificationToAdd, ok := <-p.addCh:
            if !ok {
                return
            }
            if notification == nil {
                notification = notificationToAdd
                nextCh = p.nextCh
            } else {
                p.pendingNotifications.WriteOne(notificationToAdd)
            }
        }
    }
}

// run 协程：从 nextCh 接收并调用处理器
func (p *processorListener) run() {
    sleepAfterCrash := false
    
    for next := range p.nextCh {
        if sleepAfterCrash {
            time.Sleep(time.Second)
        }
        
        func() {
            sleepAfterCrash = true
            defer utilruntime.HandleCrashWithLogger(p.logger)
            
            switch notification := next.(type) {
            case updateNotification:
                p.handler.OnUpdate(notification.oldObj, notification.newObj)
            case addNotification:
                p.handler.OnAdd(notification.newObj, notification.isInInitialList)
                if notification.isInInitialList {
                    p.syncTracker.Finished()
                }
            case deleteNotification:
                p.handler.OnDelete(notification.oldObj)
            }
            sleepAfterCrash = false
        }()
    }
}
```

---

## 工作流程

### 完整数据流

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           SharedIndexInformer                            │
│                                                                          │
│  ┌────────────┐     ┌─────────────┐     ┌─────────────┐                 │
│  │ API Server │────▶│  Reflector  │────▶│ DeltaFIFO   │                 │
│  │            │     │             │     │             │                 │
│  │ - List     │     │ - List      │     │ - 累积 Delta │                 │
│  │ - Watch    │     │ - Watch     │     │ - FIFO 顺序  │                 │
│  └────────────┘     │ - Transform │     └──────┬──────┘                 │
│                     └─────────────┘            │                         │
│                                                │ Pop()                   │
│                                                ▼                         │
│                     ┌─────────────────────────────────────┐              │
│                     │           HandleDeltas()            │              │
│                     │                                     │              │
│                     │  for each delta:                    │              │
│                     │    - 更新 Indexer                    │              │
│                     │    - 分发到 processor                │              │
│                     └─────────────┬───────────────────────┘              │
│                                   │                                      │
│                    ┌──────────────┼──────────────┐                       │
│                    │              │              │                       │
│                    ▼              ▼              ▼                       │
│             ┌──────────┐  ┌──────────┐  ┌──────────┐                    │
│             │ Indexer  │  │processor │  │processor │                    │
│             │ (缓存)   │  │Listener 1│  │Listener 2│                    │
│             │          │  │          │  │          │                    │
│             │ - Get    │  │ - OnAdd  │  │ - OnAdd  │                    │
│             │ - List   │  │ - OnUpdate│ │ - OnUpdate│                   │
│             │ - Index  │  │ - OnDelete│ │ - OnDelete│                   │
│             └──────────┘  └──────────┘  └──────────┘                    │
└──────────────────────────────────────────────────────────────────────────┘
```

### 初始化流程

```go
// 1. 创建 SharedIndexInformer
func NewSharedIndexInformerWithOptions(
    lw ListerWatcher, 
    exampleObject runtime.Object, 
    options SharedIndexInformerOptions,
) SharedInformer {
    realClock := &clock.RealClock{}
    
    return &sharedIndexInformer{
        // 创建 Indexer
        indexer: NewIndexer(DeletionHandlingMetaNamespaceKeyFunc, options.Indexers),
        
        // 创建 processor
        processor: &sharedProcessor{clock: realClock},
        
        listerWatcher:                   lw,
        objectType:                      exampleObject,
        resyncCheckPeriod:               options.ResyncPeriod,
        defaultEventHandlerResyncPeriod: options.ResyncPeriod,
        clock:                           realClock,
        cacheMutationDetector:           NewCacheMutationDetector(fmt.Sprintf("%T", exampleObject)),
    }
}
```

### 启动流程

```go
func (s *sharedIndexInformer) RunWithContext(ctx context.Context) {
    defer utilruntime.HandleCrashWithContext(ctx)
    
    if s.HasStarted() {
        logger.Info("Warning: the sharedIndexInformer has started, run more than once is not allowed")
        return
    }
    
    func() {
        s.startedLock.Lock()
        defer s.startedLock.Unlock()
        
        // 1. 创建 DeltaFIFO
        var fifo Queue
        if clientgofeaturegate.FeatureGates().Enabled(clientgofeaturegate.InOrderInformers) {
            fifo = NewRealFIFO(MetaNamespaceKeyFunc, s.indexer, s.transform)
        } else {
            fifo = NewDeltaFIFOWithOptions(DeltaFIFOOptions{
                KnownObjects:          s.indexer,
                EmitDeltaTypeReplaced: true,
                Transformer:           s.transform,
            })
        }
        
        // 2. 创建 Controller 配置
        cfg := &Config{
            Queue:             fifo,
            ListerWatcher:     s.listerWatcher,
            ObjectType:        s.objectType,
            ObjectDescription: s.objectDescription,
            FullResyncPeriod:  s.resyncCheckPeriod,
            ShouldResync:      s.processor.shouldResync,
            Process:           s.HandleDeltas,
            WatchErrorHandlerWithContext: s.watchErrorHandler,
        }
        
        // 3. 创建 Controller
        s.controller = New(cfg)
        s.controller.(*controller).clock = s.clock
        s.started = true
    }()
    
    // 4. 启动 processor
    processorStopCtx, stopProcessor := context.WithCancelCause(context.WithoutCancel(ctx))
    var wg wait.Group
    defer wg.Wait()
    defer stopProcessor(errors.New("informer is stopping"))
    wg.StartWithContext(processorStopCtx, s.processor.run)
    
    // 5. 启动 Controller（会启动 Reflector）
    s.controller.RunWithContext(ctx)
}
```

### 事件处理流程

```go
// HandleDeltas 处理 DeltaFIFO 弹出的 Deltas
func (s *sharedIndexInformer) HandleDeltas(obj interface{}, isInInitialList bool) error {
    s.blockDeltas.Lock()
    defer s.blockDeltas.Unlock()
    
    if deltas, ok := obj.(Deltas); ok {
        return processDeltas(s, s.indexer, deltas, isInInitialList)
    }
    return errors.New("object given as Process argument is not Deltas")
}

// processDeltas 处理每个 Delta
func processDeltas(
    handler ResourceEventHandler,
    clientState Store,
    deltas Deltas,
    isInInitialList bool,
) error {
    // 从最旧到最新处理每个 Delta
    for _, d := range deltas {
        obj := d.Object
        
        switch d.Type {
        case Sync, Replaced, Added, Updated:
            if old, exists, err := clientState.Get(obj); err == nil && exists {
                // 更新已存在的对象
                if err := clientState.Update(obj); err != nil {
                    return err
                }
                handler.OnUpdate(old, obj)
            } else {
                // 添加新对象
                if err := clientState.Add(obj); err != nil {
                    return err
                }
                handler.OnAdd(obj, isInInitialList)
            }
        case Deleted:
            // 删除对象
            if err := clientState.Delete(obj); err != nil {
                return err
            }
            handler.OnDelete(obj)
        }
    }
    return nil
}
```

---

## 关键机制

### 1. 共享机制

多个消费者可以共享同一个 Informer，避免重复的 ListWatch：

```go
// 添加多个事件处理器
informer.AddEventHandler(handler1)
informer.AddEventHandler(handler2)
informer.AddEventHandler(handler3)

// 所有处理器共享同一个缓存和 Reflector
// 只有一个 ListWatch 连接到 API Server
```

### 2. 重同步（Resync）机制

重同步是定期触发的事件，用于确保状态一致性：

```go
// sharedProcessor 定期检查是否需要重同步
func (p *sharedProcessor) shouldResync() bool {
    p.listenersLock.Lock()
    defer p.listenersLock.Unlock()
    
    resyncNeeded := false
    now := p.clock.Now()
    
    for listener := range p.listeners {
        shouldResync := listener.shouldResync(now)
        p.listeners[listener] = shouldResync
        
        if shouldResync {
            resyncNeeded = true
            listener.determineNextResync(now)
        }
    }
    return resyncNeeded
}

// listener 判断是否需要重同步
func (p *processorListener) shouldResync(now time.Time) bool {
    p.resyncLock.Lock()
    defer p.resyncLock.Unlock()
    
    if p.resyncPeriod == 0 {
        return false
    }
    return now.After(p.nextResync) || now.Equal(p.nextResync)
}
```

### 3. 动态添加处理器

在 Informer 运行后添加处理器时，会先发送当前缓存中所有对象的 Add 事件：

```go
func (s *sharedIndexInformer) AddEventHandlerWithOptions(
    handler ResourceEventHandler, 
    options HandlerOptions,
) (ResourceEventHandlerRegistration, error) {
    s.startedLock.Lock()
    defer s.startedLock.Unlock()
    
    // ... 配置 resync ...
    
    listener := newProcessListener(logger, handler, resyncPeriod, ...)
    
    if !s.started {
        return s.processor.addListener(listener), nil
    }
    
    // 安全地加入运行中的 Informer
    s.blockDeltas.Lock()
    defer s.blockDeltas.Unlock()
    
    handle := s.processor.addListener(listener)
    
    // 发送当前缓存中所有对象的 Add 事件
    for _, item := range s.indexer.List() {
        listener.add(addNotification{newObj: item, isInInitialList: true})
    }
    return handle, nil
}
```

### 4. 同步跟踪（Sync Tracking）

每个处理器可以独立跟踪其同步状态：

```go
// processorListener 使用 syncTracker 跟踪同步状态
func newProcessListener(...) *processorListener {
    ret := &processorListener{
        // ...
        syncTracker: &synctrack.SingleFileTracker{UpstreamHasSynced: hasSynced},
        // ...
    }
    return ret
}

// 开始初始列表处理
func (p *processorListener) add(notification interface{}) {
    if a, ok := notification.(addNotification); ok && a.isInInitialList {
        p.syncTracker.Start()
    }
    p.addCh <- notification
}

// 完成初始列表处理
case addNotification:
    p.handler.OnAdd(notification.newObj, notification.isInInitialList)
    if notification.isInInitialList {
        p.syncTracker.Finished()
    }

// 查询同步状态
func (p *processorListener) HasSynced() bool {
    return p.syncTracker.HasSynced()
}
```

### 5. 对象转换（Transform）

可以在对象存储前进行转换，用于减少内存占用：

```go
// 设置转换函数
informer.SetTransform(func(obj interface{}) (interface{}, error) {
    if typedObj, ok := obj.(*v1.Pod); ok {
        // 移除不需要的字段，减少内存占用
        typedObj.ManagedFields = nil
        return typedObj, nil
    }
    return obj, nil
})

// 转换函数在以下位置被调用：
// 1. Reflector 将对象存入 DeltaFIFO 时
// 2. DeltaFIFO 存储对象时
```

### 6. 错误处理与退避

Reflector 使用指数退避策略处理连接错误：

```go
// Reflector 使用指数退避管理器
backoffManager: wait.NewExponentialBackoffManager(
    800*time.Millisecond,  // 初始延迟
    30*time.Second,        // 最大延迟
    2*time.Minute,         // 重置时间
    2.0,                   // 倍数因子
    1.0,                   // 随机因子
    reflectorClock,
)

// 默认错误处理器
func DefaultWatchErrorHandler(ctx context.Context, r *Reflector, err error) {
    switch {
    case isExpiredError(err):
        // ResourceVersion 过期，静默处理
        klog.FromContext(ctx).V(4).Info("Watch closed", "err", err)
    case err == io.EOF:
        // 正常关闭
    case err == io.ErrUnexpectedEOF:
        // 意外 EOF
        klog.FromContext(ctx).V(1).Info("Watch closed with unexpected EOF", "err", err)
    default:
        // 其他错误
        utilruntime.HandleErrorWithContext(ctx, err, "Failed to watch", "err", err)
    }
}
```

---

## 实践建议

### 1. 正确使用事件处理器

```go
// ✅ 推荐：快速处理事件，异步执行耗时操作
informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
    AddFunc: func(obj interface{}) {
        key, _ := cache.MetaNamespaceKeyFunc(obj)
        workqueue.Add(key)  // 放入工作队列异步处理
    },
})

// ❌ 避免：在事件处理器中执行耗时操作
informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
    AddFunc: func(obj interface{}) {
        // 耗时操作会阻塞其他事件处理
        time.Sleep(10 * time.Second)
        doHeavyWork(obj)
    },
})
```

### 2. 合理设置 Resync 周期

```go
// 根据业务需求设置合适的 resync 周期
// 大多数场景不需要频繁 resync
resyncPeriod := 10 * time.Hour  // 默认值通常足够

// 对于需要定期校验的场景
resyncPeriod := 5 * time.Minute

// 对于不需要 resync 的场景
resyncPeriod := 0  // 禁用 resync
```

### 3. 使用索引优化查询

```go
// 添加自定义索引
indexer := informer.GetIndexer()
indexer.AddIndexers(cache.Indexers{
    "byOwner": func(obj interface{}) ([]string, error) {
        pod := obj.(*v1.Pod)
        owners := []string{}
        for _, owner := range pod.OwnerReferences {
            owners = append(owners, string(owner.UID))
        }
        return owners, nil
    },
})

// 使用索引查询
pods, err := indexer.ByIndex("byOwner", ownerUID)
```

### 4. 等待缓存同步

```go
// 启动 Informer
go informer.Run(stopCh)

// 等待缓存同步
if !cache.WaitForCacheSync(stopCh, informer.HasSynced) {
    log.Error("Failed to sync cache")
    return
}

// 开始处理
log.Info("Cache synced, starting controller")
```

### 5. 使用 Transform 减少内存

```go
// 对于大规模集群，使用 Transform 减少内存占用
informer.SetTransform(func(obj interface{}) (interface{}, error) {
    switch o := obj.(type) {
    case *v1.Pod:
        o.ManagedFields = nil
        o.Status.EphemeralContainerStatuses = nil
        return o, nil
    case *v1.Node:
        o.ManagedFields = nil
        return o, nil
    }
    return obj, nil
})
```

### 6. 错误处理最佳实践

```go
// 自定义错误处理器
informer.SetWatchErrorHandlerWithContext(func(ctx context.Context, r *cache.Reflector, err error) {
    // 记录详细的错误信息
    klog.FromContext(ctx).Error(err, "Watch error", 
        "reflector", r.Name(),
        "type", r.TypeDescription(),
    )
    
    // 可以添加监控指标
    metrics.InformerWatchErrors.Inc()
})
```

---

## 总结

`SharedIndexInformer` 是 Kubernetes client-go 的核心组件，其设计体现了以下优秀实践：

1. **职责分离**：Reflector、DeltaFIFO、Controller、Processor 各司其职
2. **共享设计**：多个消费者共享同一个数据源，减少 API Server 压力
3. **最终一致性**：通过 ListWatch 机制保证缓存与 API Server 的最终一致性
4. **灵活扩展**：支持自定义索引、转换函数、错误处理器
5. **健壮性**：完善的错误处理、退避重试、崩溃恢复机制

理解 `SharedIndexInformer` 的工作原理对于开发 Kubernetes 控制器和 Operator 至关重要。
