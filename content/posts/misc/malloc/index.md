---
title: "从 glibc malloc 到 jemalloc"
date: 2026-05-16T10:00:00+08:00
draft: false
tags: [glibc, jemalloc, malloc, memory, performance]
categories: [misc]
---

> 在高并发、多线程、大量分配/释放的场景下，glibc 默认的 malloc 实现（ptmalloc2）会导致严重的内存碎片，RSS 可能是实际使用量的 2 倍以上。切换到 jemalloc 或 tcmalloc，内存占用可下降 30%~50%，且行为更可预测。

## 📋 概述

在容器化、微服务架构中，"内存泄漏"是最常见的告警之一。但很多时候，问题并不在代码本身——glibc 的 Arena 碎片机制才是幕后黑手。

本文从 glibc malloc 的 Arena 机制出发，对比 jemalloc 的三层架构设计，结合真实测试数据，给出可落地的优化方案。

---

## 🏗️ glibc malloc 的架构：Arena 机制

### 为什么需要 Arena？

单线程时代，`malloc`/`free` 管理一个全局的内存池就够用了。但多线程场景下，如果所有线程共享同一个分配池，每次 alloc/free 都要锁同一把锁，性能会急剧下降。

glibc 的解决方案是 **per-thread Arena**：

```
┌─────────────────────────────────────────────────┐
│               glibc malloc (ptmalloc2)           │
│                                                  │
│  Thread A ──▶ Arena 1 (独立锁)                    │
│  Thread B ──▶ Arena 2 (独立锁)                    │
│  Thread C ──▶ Arena 1 (复用，数量不够时)           │
│  Thread D ──▶ Arena 3 (新线程，新 Arena)          │
│  ...                                              │
└─────────────────────────────────────────────────┘
```

每个 Arena 内部维护自己的：

- **已分配块** — 程序正在使用的内存
- **空闲链表（free list）** — `free()` 回来的、下次可以复用的块
- **top chunk** — 还没分配、可以继续向 OS 申请的剩余空间

不同线程分配内存时，只需锁住自己对应的 Arena，互不阻塞。

### 问题出在哪？

**Arena 一旦创建，就不会自动销毁。而且 Arena 里 free 的内存，不还给 OS。**

```
线程 A：malloc(10MB) → 使用 → free()
        ↓
  内存留在 Arena 1 的 free list 里
  不归还给 OS（glibc 认为线程还会用到）
        ↓
  RSS 居高不下
```

更糟糕的是，glibc 的 Arena 数量**默认没有上限**。在 4 核机器上，默认最多创建 `8 * nCPU = 32` 个 Arena。线程越多、瞬时分配越剧烈，创建的 Arena 就越多，每个 Arena 里都留着一些碎片化的空闲块，加起来就是几十 MB 到几 GB 的"幽灵内存"。

### 为什么每次运行结果不一样？

这是最让人困惑的现象：同一份代码、同一个环境，每次启动后 RSS 稳定值可能差一倍。

原因在于 **Arena 的分配由 OS 线程调度决定**：

1. 每次 `malloc` 走哪个 Arena，取决于哪个线程当前空闲
2. 线程调度是 OS 决定的，每次运行都不一样
3. 不同线程的分配模式（大小、频率）不同
4. → 每个 Arena 的碎片程度不同
5. → 最终 RSS = 实际使用量 + 各 Arena 碎片量

碎片量取决于"运气"，所以结果不可预测。

---

## 🔍 jemalloc 的架构：为什么它更好？

### 设计哲学

jemalloc 由 FreeBSD 作者 Jason Evans 开发，核心设计理念是 **确定性和碎片最小化**。

它的内存管理分为三层：

```
┌───────────────────────────────────────┐
│              jemalloc                  │
│                                       │
│  Thread Cache (tcache)                │
│  ├── 每个线程独立，无锁访问             │
│  ├── 存放最近 free 的小块              │
│  └── 线程结束时自动回收                 │
│                                       │
│  Arena（数量有上限：4 × nCPU）          │
│  ├── 每个 Arena 管理多个 slab          │
│  ├── slab 按 size class 分类           │
│  └── 碎片只在同 size class 内产生       │
│                                       │
│  Pages                                │
│  ├── dirty pages → 定期 purge 回 OS   │
│  └── muzzy pages → 延迟 purge          │
└───────────────────────────────────────┘
```

### 关键区别

| 特性 | glibc malloc (ptmalloc2) | jemalloc |
|------|--------------------------|----------|
| **Arena 数量** | 无上限（最多 8×nCPU） | 有上限（默认 4×nCPU） |
| **线程缓存** | 有，但回收策略松散 | 积极，线程结束时自动清理 |
| **内存归还** | 基本不还（mmap 阈值以上除外） | dirty page 定期 purge 回 OS |
| **碎片控制** | 按大小分 bin，但跨 bin 碎片严重 | 严格按 size class 分 slab |
| **可预测性** | 差（受线程调度影响） | 好（行为确定性强） |

### 核心机制：Purge

jemalloc 最核心的优势是**主动把不用的内存还给 OS**：

- **dirty page**：free 后还没归还的内存，默认 10 秒后 purge 回 OS
- **muzzy page**：已经 purge 过但还没被 `madvise(MADV_FREE)` 清除的内存，默认 10 秒后处理

这两个机制确保：即使程序短暂分配了大量内存然后释放，jemalloc 也会在几十秒内把内存还给 OS，RSS 自然回落。

而 glibc malloc 的策略是：除非 top chunk 后面的空间够大，否则不还。一旦 Arena 里散布着一些已分配块，top chunk 后面就没足够连续空间，整个 Arena 的内存就"卡"在那里了。

---

## 📈 真实测试数据

### Java FFI + C 缓存库（1 亿条目）

| Allocator | RSS | 波动范围 |
|-----------|-----|----------|
| **glibc malloc** | 10GB ~ 18GB | **80% 波动** |
| **jemalloc** | ~11GB | 基本无波动 |

同一代码、同一环境，glibc 下结果不一致，jemalloc 下多次运行几乎一致。

### Hyperledger Besu（Java + RocksDB JNI）

| Allocator | RSS | 对比 |
|-----------|-----|------|
| **glibc malloc** | >9GB | 基准 |
| **jemalloc** | <5GB | **↓ ~45%** |
| **tcmalloc** | <5GB | **↓ ~45%** |
| **mimalloc** | ~5.5GB | ↓ ~39% |

### Cloudflare RocksDB 生产环境

Cloudflare 将 RocksDB 的底层 allocator 从 glibc malloc 切换到 tcmalloc 后：

- 内存占用下降 **30%~40%**
- 内存碎片显著减少
- OOM 事件频率大幅下降

### Istio ztunnel（Rust sidecar）

| 配置 | 预计 RSS |
|------|----------|
| **glibc malloc（默认）** | ~200MB |
| **MALLOC_ARENA_MAX=2** | ~100MB |
| **jemalloc（需编译）** | ~80-100MB |

### 总结对比

| 来源 | 场景 | glibc | 优化后 | 改善幅度 |
|------|------|-------|--------|----------|
| Medium 文章 | Java FFI + C 缓存 | 10-18GB（波动） | 11GB（稳定） | 消除波动 |
| Besu Wiki | Java + RocksDB | >9GB | <5GB | **~45%** |
| Cloudflare | C++ RocksDB 生产 | 高 | 显著降低 | **30-40%** |
| ztunnel | Rust | ~200MB | ~100MB | **~50%** |

---

## 🔑 关键技术点

### 为什么 RocksDB 和 Sidecar 特别受影响？

**RocksDB：**

- **大量小块分配**：B+ 树节点、memtable 条目、bloom filter
- **高并发**：compaction 线程 + flush 线程 + 读线程同时分配
- **内存占用大**：block cache + memtable 可能占数 GB
- → 正好触发 glibc malloc 的最坏情况

**Sidecar（Envoy / ztunnel）：**

- **短生命周期分配**：每个请求处理产生大量临时分配
- **多线程**：worker thread 并行处理
- **长期运行**：碎片只会积累不会释放
- → RSS 随运行时间逐渐增长，最终稳定在一个较高的值

### 如何判断你是不是 arena 碎片问题？

**快速判断法：**

```bash
# 1. 查看进程的 RSS
cat /proc/<pid>/status | grep VmRSS

# 2. 查看 smaps_rollup
cat /proc/<pid>/smaps_rollup

# 3. 对比 heap profile（如果是 Go/Rust）
pprof --top heap
```

如果 heap profile 显示的分配量远小于 RSS，那就是 malloc 碎片。

**验证法：**

```bash
# 加环境变量后重启，对比 RSS
MALLOC_ARENA_MAX=2 ./your-service
```

如果 RSS 明显下降，确认是 arena 碎片问题。

**jemalloc 统计：**

```bash
export MALLOC_CONF="stats_print:true"
# 进程退出时会打印详细统计信息
```

可以看到 arena 数量、分配/释放次数、碎片比例等。

---

## 🛠️ 解决方案

### 方案 A：限制 glibc Arena 数量（零成本）

```yaml
env:
- name: MALLOC_ARENA_MAX
  value: "2"
```

| 项目 | 说明 |
|------|------|
| **优点** | 不需要重新编译，立竿见影 |
| **缺点** | 线程间锁竞争可能略增（但通常可忽略） |
| **效果** | RSS 下降约 30%~50% |

### 方案 B：使用 jemalloc（需重新编译或 LD_PRELOAD）

**Rust 项目（如 ztunnel）：**

```toml
# Cargo.toml
[dependencies]
tikv-jemallocator = "0.5"
```

```rust
// src/main.rs 顶部
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;
```

**C/C++ 项目：**

```bash
# 编译时链接
gcc -ljemalloc ...

# 或者运行时 LD_PRELOAD
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so
```

**Java JNI 场景：**

```bash
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so
export MALLOC_CONF="stats_print:true"  # 退出时打印统计信息
```

| 项目 | 说明 |
|------|------|
| **优点** | 效果最好，碎片控制最彻底 |
| **缺点** | 需要重新编译或设置环境变量；CPU 开销可能略增 1-3% |
| **效果** | RSS 下降 40%~50%，行为可预测 |

### 方案 C：使用 tcmalloc 或 mimalloc

类似 jemalloc，但各有侧重：

| | jemalloc | tcmalloc | mimalloc |
|---|----------|----------|----------|
| **碎片控制** | ★★★★★ | ★★★★☆ | ★★★★☆ |
| **吞吐性能** | ★★★★☆ | ★★★★★ | ★★★★☆ |
| **内存回收速度** | 快（~10s） | 中等 | 快 |
| **适用场景** | 通用、RocksDB | Google 内部广泛使用 | Windows + 跨平台 |

---

## 🎯 总结

1. **glibc malloc 不是内存泄漏的错，而是碎片**。Arena 机制在高并发场景下会导致大量"幽灵内存"。
2. **jemalloc/tcmalloc/mimalloc 都优于 glibc malloc**，特别是在 RocksDB、网络代理、大规模缓存等场景。
3. **零成本方案 `MALLOC_ARENA_MAX=2`** 可以解决大部分问题，建议先试。
4. **如果追求极致**，编译时链接 jemalloc 是最终方案。
5. **RSS 和 CPU 是 trade-off**：jemalloc 回收积极，可能增加 1-3% 的 CPU 开销，但换来的是可预测的内存行为。

下次遇到"内存泄漏"的报警，先别急着排查代码——看看是不是 glibc malloc 在偷偷吃你的内存。

---

*参考：*

- *[Besu Wiki: Reduce Memory usage by choosing a different low level allocator](https://lf-hyperledger.atlassian.net/wiki/spaces/BESU/pages/22156632/)*
- *[Cloudflare: The effect of switching to tcmalloc on RocksDB memory use](https://blog.cloudflare.com/the-effect-of-switching-to-tcmalloc-on-rocksdb-memory-use/)*
- *[Medium: Jemalloc vs glibc malloc Memory Allocation Performance Comparison](https://medium.com/@binitabharati/jemalloc-vs-glibc-malloc-memory-allocation-performance-comparison-fbaeda1740de)*
- *[jemalloc 官方文档](https://jemalloc.net/)*
- *[Istio ztunnel 源码](https://github.com/istio/ztunnel)*
