---
title: "不解密 TLS，如何复用 Envoy HTTP ext_proc：基于 HTTP/2 CONNECT 的内部隧道"
description: "将未终结的 TLS 连接封装为内部 HTTP/2 CONNECT，在不解密业务流量的前提下复用 Envoy HTTP ext_proc，并分析这条路径的性能代价。"
date: 2026-07-16T10:00:00+08:00
draft: false
tags: [Envoy, HTTP/2, CONNECT, ext_proc, TLS, Performance]
categories: [Envoy]
---

> 对一条不允许解密的 TLS 连接，能否既保持端到端加密，又复用 Envoy 已有的 HTTP `ext_proc` 完成连接级准入？本文介绍一种内部 HTTP/2 CONNECT 封装方案，并通过分层压测解释它约 21% 的饱和吞吐损失究竟来自哪里。

## 问题：不终结 TLS，HTTP ext_proc 就没有 HTTP 请求

Envoy 的 HTTP `ext_proc` 工作在 HTTP Connection Manager（HCM）中。它处理的是已经被 HTTP codec 解析出的请求头、请求体和响应，而一条未终结的 TLS 连接在 Envoy 看来只是 TCP 字节流：

```text
ClientHello + encrypted application data
```

Envoy 可以借助 TLS Inspector 读取 ClientHello 中的 SNI，但只要不终结 TLS，就无法看到加密后的 HTTP method、path、headers 和 body。因此，下面这条链路并不存在直接插入 HTTP `ext_proc` 的位置：

```text
TLS client
  -> TLS Inspector
  -> TCP Proxy
  -> original destination
```

一种直接方案是终结 TLS，再把解密后的 HTTP 流量送入 HCM。但这会改变连接语义：证书由代理提供，客户端与原始服务之间不再保持端到端 TLS，代理也能看到业务明文。这并不适用于要求 TLS 透明透传的场景。

另一个方向是实现 network filter 版本的外部处理协议。但如果已有的策略服务、故障处理、日志和运维体系都建立在 HTTP `ext_proc` 上，重新设计一套 network ext_proc 会带来新的协议、客户端、控制面配置和兼容成本。

于是产生了一个折中思路：

> 不终结业务 TLS，而是在 Envoy 内部把这条 TCP 连接包装成一个 HTTP/2 CONNECT stream，让现有 HTTP `ext_proc` 只处理 CONNECT 请求及其连接属性；完成决策后，再解开 CONNECT，把原始 TLS 字节原样转发给目标服务。

这里需要先明确能力边界：`ext_proc` 看到的是内部构造的 CONNECT 请求和显式传入的 attributes，不是加密隧道里的 HTTPS 请求。它适合基于 SNI、目标地址、来源身份等信息做连接级 allow/deny，不能检查 HTTPS path、header 或 body。

## 数据流：终结的是 CONNECT，不是 TLS

改造后的数据路径如下：

```text
TLS client（业务 TLS 未终结）
        │
        │ TLS Inspector 识别 SNI
        ▼
protocol matcher
        │
        │ feature disabled ───────────────► TCP Proxy ─► ORIGINAL_DST
        │
        │ feature enabled
        ▼
TCP Proxy + tunneling_config
        │
        │ HTTP/2 CONNECT
        │ :authority = original IP:port
        │ DATA = 原始 TLS 字节
        ▼
HTTP/2 internal-upstream cluster
        │
        ▼
internal listener: tls-connect-terminate
        │
        │ HCM, CONNECT upgrade, allow_connect
        │
        ├─► ext_proc：读取 SNI / authority / identity attributes
        ├─► router
        ▼
PassthroughCluster（ORIGINAL_DST）
        │
        ▼
original destination（仍接收原始 TLS 字节）
```

从业务 TLS 的视角看，代理没有生成证书，没有解密 Application Data，也没有修改 ClientHello。新增的 HTTP/2 只是一层 Envoy 内部传输协议。

## 实现

### 1. 在 TLS 分支中发起 CONNECT

功能开启时，原来的直连 TCP Proxy 改为指向一个 internal-upstream cluster，并配置 `tunneling_config`：

```yaml
name: forward-tls-connect
filters:
  - name: envoy.filters.network.tcp_proxy
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
      stat_prefix: forward_tls_connect
      cluster: tls_connect_internal
      tunneling_config:
        hostname: "%FILTER_STATE(io.example.connect_authority:PLAIN)%"
```

`hostname` 会成为 CONNECT 的 `:authority`。它必须携带原始目标的 `IP:port`，否则后面的 ORIGINAL_DST cluster 不知道应该把解封装后的 TCP 流量发到哪里。

TCP Proxy 不理解隧道中的 TLS 内容。它只是把下游 TCP 字节编码为 HTTP/2 DATA frame，并把收到的 DATA frame 重新还原为上游 TCP 字节。

### 2. 使用 HTTP/2 internal-upstream cluster

这个 cluster 的 endpoint 不是网卡地址，而是 Envoy internal listener：

```yaml
name: tls_connect_internal
type: STATIC
load_assignment:
  cluster_name: tls_connect_internal
  endpoints:
    - lb_endpoints:
        - endpoint:
            address:
              envoy_internal_address:
                server_listener_name: tls-connect-terminate
typed_extension_protocol_options:
  envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
    "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
    explicit_http_config:
      http2_protocol_options: {}
transport_socket:
  name: envoy.transport_sockets.internal_upstream
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.transport_sockets.internal_upstream.v3.InternalUpstreamTransport
```

`internal_upstream` 让这次转发停留在 Envoy 进程内，不需要监听新的物理端口，也不需要额外的 TLS transport socket。

### 3. 在 internal listener 中终结 CONNECT

internal listener 上运行一个只接受 CONNECT 的 HCM：

```yaml
name: tls-connect-terminate
internal_listener: {}
listener_filters:
  - name: envoy.filters.listener.original_dst
filter_chains:
  - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: tls_connect_terminate
          codec_type: HTTP2
          http2_protocol_options:
            allow_connect: true
            max_concurrent_streams: 100
          upgrade_configs:
            - upgrade_type: CONNECT
          http_filters:
            - name: envoy.filters.http.ext_proc
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
                # grpc_service、processing_mode 和 attributes 省略
            - name: envoy.filters.http.router
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
```

路由只匹配 CONNECT，并把解封装后的字节交给 ORIGINAL_DST cluster：

```yaml
routes:
  - match:
      connect_matcher: {}
    route:
      cluster: PassthroughCluster
      upgrade_configs:
        - upgrade_type: CONNECT
          connect_config: {}
```

此处 HCM 终结的是内部 CONNECT。CONNECT 建立后，后续 TLS 字节作为 tunnel payload 通过 router，不会被 HCM 当作新的 HTTP 请求解析。

### 4. 原始目标和 SNI 如何跨越 internal hop

原始目标通常来自透明代理入口的 original destination。进入内部 CONNECT 之前，需要把至少两类信息保存在 filter state：

- `original_dst.local_ip`：原始目标 `IP:port`，供第二个 listener 的 Original Destination listener filter 和 ORIGINAL_DST cluster 使用。
- `connect_authority`：生成 CONNECT `:authority`，也可作为 `ext_proc` attribute。

TLS Inspector 提取的 SNI 也可以写入 filter state，再作为 request attribute 传给 `ext_proc`：

```text
filter_state['io.example.connect_authority']
filter_state['io.example.outer_sni']
```

第二个 listener 不需要再次改写原始目标。它直接读取第一个入口已经建立、并随 internal-upstream 传递过来的状态即可。重复以不同生命周期写入同一个 filter-state key，反而可能触发 `FilterStateAccessViolation`。

filter state 的共享范围需要尽可能小。把下游临时端口、来源地址等每连接变化的字段标记为 shared/hashable，会让它们参与 upstream connection pool key，导致本可复用的 HTTP/2 连接被拆成多个 pool。

### 5. 门禁与零额外成本路径

这条内部路径应由显式 feature flag 控制，并且只在确实配置了 `ext_proc` 时生成：

```text
feature disabled
  TLS -> TCP Proxy -> PassthroughCluster

feature enabled && ext_proc configured
  TLS -> TCP Proxy tunneling -> h2 internal listener -> ext_proc -> PassthroughCluster
```

关闭开关时，不生成额外 listener、cluster 和 filter chain，TLS 继续走原来的直接 passthrough，避免让未使用该能力的连接承担任何新增成本。

## 性能测试设计

为了只测内部封装路径，测试期间完全移除了 HCM 中的 `ext_proc` filter，并将外部处理服务缩容为 0。访问日志保持开启，因此对比项只有：

```text
OFF: direct TCP passthrough
ON : TCP -> h2 CONNECT -> internal listener -> HCM/router -> TCP
```

主要测试条件：

- 单节点 KinD
- Fortio 1.75.2
- 128-byte HTTPS response
- TLS keepalive
- Fortio concurrency 16
- Envoy concurrency 1
- Envoy CPU limit 1 core
- 固定 30,000 QPS 与不限 QPS 两种模式
- 每次切换路径后重启 Envoy，确认 xDS 生效后再测试
- 先运行 3 次，再独立重复 5 次，每个条件合计 8 个样本

四种测试组合如下：

| Feature flag | QPS 模式 | 目的 |
|---|---|---|
| OFF | 固定 30k | 直接路径在相同负载下的延迟和 CPU |
| ON | 固定 30k | 内部 h2 路径在相同负载下的增量成本 |
| OFF | 不限 | 直接路径的单核最大吞吐 |
| ON | 不限 | 内部 h2 路径的单核最大吞吐 |

## 性能结果

### 相同 QPS：吞吐不变，但 CPU 和平均延迟上升

| Metric | Feature OFF | Feature ON | ON vs. OFF |
|---|---:|---:|---:|
| Actual QPS | 29,997.92 | 29,998.08 | ≈ 0% |
| Average latency | 0.2980 ms | 0.3718 ms | **+0.0738 ms / +24.77%** |
| Envoy CPU | 0.5402 cores | 0.6887 cores | **+0.1485 cores / +27.50%** |

固定 30k QPS 时，两条路径都能完成目标负载。内部 CONNECT 路径每次请求增加约 74 微秒平均延迟，同时多消耗约 0.15 核 CPU。

### 不限 QPS：单核最大吞吐下降约 21%

| Metric | Feature OFF | Feature ON | ON vs. OFF |
|---|---:|---:|---:|
| Maximum QPS | 56,463.82 | 44,399.72 | **-21.37%** |
| Average latency | 0.2831 ms | 0.3601 ms | **+0.0770 ms / +27.20%** |
| Envoy CPU | 0.9402 cores | 0.9687 cores | +3.03% |

不限 QPS 时，两组都接近单核上限。ON 路径每个请求需要更多 CPU service time，因此在相同 CPU 容量下只能完成更少请求。CPU 使用率只增加 3% 并不代表开销小，而是两组都已经被 1 core 的上限压住。

两轮实验共完成 21,703,746 个请求，全部返回 HTTP 200，没有错误。5 次独立重复中，关键 QPS、平均延迟和 CPU 指标的变异系数均小于 0.7%，差异显著大于运行间抖动。

Fortio 默认直方图精度为 1 ms，本实验的主要延迟低于 1 ms，因此 P50/P90/P99 是首个 bucket 内的插值。这里应优先观察由 `sum/count` 得到的平均延迟，而不是亚毫秒 percentile。

## 损耗是否全部来自 HTTP/2 封包

不是。为了分离各层成本，又增加了一条只经过 raw internal listener 的中间路径：

```text
direct
  TCP Proxy -> ORIGINAL_DST

raw internal
  TCP Proxy -> internal listener -> TCP Proxy -> ORIGINAL_DST

h2 CONNECT
  TCP Proxy tunneling -> h2 -> internal listener -> HCM/router -> ORIGINAL_DST
```

三条路径都不包含 `ext_proc`。每条路径在固定 30k QPS 和不限 QPS 下各运行 5 次，并轮换执行顺序。

### 三条路径的均值

| Mode | Metric | Direct | Raw internal | HTTP/2 CONNECT |
|---|---|---:|---:|---:|
| Fixed 30k | Average latency | 0.3014 ms | 0.3308 ms | 0.3690 ms |
| Fixed 30k | Envoy CPU | 0.5448 cores | 0.6093 cores | 0.6823 cores |
| Fixed 30k | CPU/request | 18.16 us | 20.31 us | 22.74 us |
| Unlimited | Maximum QPS | 56,054.75 | 49,555.57 | 43,878.28 |
| Unlimited | Average latency | 0.2852 ms | 0.3226 ms | 0.3644 ms |
| Unlimited | CPU/request | 16.79 us | 19.32 us | 22.08 us |

### 分层差异

| Mode | 新增层 | 吞吐变化 | 平均延迟变化 | CPU 变化 |
|---|---|---:|---:|---:|
| Fixed 30k | Raw internal - direct | ≈ 0% | **+0.0294 ms / +9.77%** | **+0.0645 cores / +11.85%** |
| Fixed 30k | HTTP/2/HCM - raw internal | ≈ 0% | **+0.0382 ms / +11.55%** | **+0.0730 cores / +11.98%** |
| Fixed 30k | 完整路径 - direct | ≈ 0% | **+0.0676 ms / +22.46%** | **+0.1374 cores / +25.26%** |
| Unlimited | Raw internal - direct | **-11.56%** | +0.0373 ms / +13.13% | +1.73%（已饱和） |
| Unlimited | HTTP/2/HCM - raw internal | **-11.46%** | +0.0418 ms / +12.95% | +1.18%（已饱和） |
| Unlimited | 完整路径 - direct | **-21.70%** | +0.0791 ms / +27.78% | +2.93%（已饱和） |

固定 30k QPS 时，raw internal hop 增加约 2.15 us/request，HTTP/2 codec 加 HCM/router 再增加约 2.43 us/request。不限 QPS 时对应为 2.53 us 和 2.76 us。

换句话说，新增 CPU demand 大致分为：

```text
47%～48%  additional raw internal userspace hop
52%～53%  HTTP/2 codec + HCM + router
```

所以，“增加一个 h2 封包”并不是完整解释。即便不使用 HTTP/2，仅增加一次 Envoy internal listener、buffer 转移、dispatcher callback 和第二个 TCP Proxy，也会消耗接近一半的增量 CPU。

### perf 看到的热点

固定 30k QPS 下对 Envoy 进程进行 10 秒 `perf` 采样，启发式分类结果如下：

| Symbol category | Direct | Raw internal | HTTP/2 CONNECT |
|---|---:|---:|---:|
| HTTP/2 / nghttp2 | 2.90% | 1.47% | 7.50% |
| HCM / router | 4.51% | 3.10% | 5.18% |
| TCP / network | 7.04% | 11.72% | 5.65% |

raw internal 路径中的热点主要是 buffer slice move/drain、TCP Proxy、`Network::ConnectionImpl` 和 internal socket callback。h2 路径则新增了 `nghttp2_session_send`、HTTP/2 encode/decode、buffer ownership、HCM 和 router callback。

采样数量不大，类别之间也可能重叠，因此这个表适合确认方向，不应当被当成精确 CPU 归因。它与受控分层实验的结论一致：成本大致由 internal userspace hop 和 HTTP/2/HCM 两部分平分。

## 连接池是不是主要问题

HTTP/2 理论上可以在一条连接中承载多个 CONNECT stream，但 filter state 也可能参与 upstream pool key。如果共享状态中包含下游临时端口等每连接变化的数据，16 条下游 TLS 连接可能产生 12～16 条 internal h2 connection，几乎没有多路复用。

诊断实验只移除 `original_dst.remote_ip` 后，internal h2 connection 降至 9～12 条；固定 30k QPS 的 CPU 改善约 2.3%，不限 QPS 吞吐改善约 2.8%。这说明 pool fragmentation 确实存在，但无法解释约 21% 的总吞吐差距。

并发为 1 时，系统中只有一条 TLS connection、一个 CONNECT stream 和一条 internal h2 connection，不存在多路复用空间。此时新增 CPU 仍约为 5.1 us/request，与并发 16 时的 4.7～5.1 us/request 很接近。这进一步证明主要成本来自稳态数据路径，而不是连接池数量。

优化连接池时也不能简单删除全部 filter state。一次全复用诊断虽然成功把 16 个 CONNECT stream 收敛到一条 h2 connection，却因 stream scope 与 connection scope 冲突而返回 503：

```text
FilterStateAccessViolation:
setData called twice with conflicting life_span

original_dst_load_balancer:
No downstream connection or no original_dst
```

更稳妥的方向是：只在 connection scope 传递真正共享的数据，把目标地址和身份等 per-CONNECT 信息改为 stream-scoped state，同时确保 ORIGINAL_DST 能在 stream 上读取这些信息。

## 如何理解这组结果

首先，21% 不是“HTTP/2 协议天然会损失 21%”。它是一个非常具体的实验结果：1 core、128-byte response、极低网络延迟、高 QPS、小请求、额外增加第二个 internal hop 和第二层 h2 CONNECT。在这种 workload 中，固定的每请求处理成本占比很高。

其次，direct baseline 本身已经包含客户端到 Envoy 的第一层 HTTP/2 CONNECT transport。本实验衡量的是新增第二次内部封装的成本，不是“系统完全没有 HTTP/2”和“系统使用 HTTP/2”的对比。

最后，相同 QPS 与不限 QPS 回答的是两个不同问题：

- 固定 QPS 表明容量足够时，每个请求多花约 0.07～0.08 ms，并增加约 25%～28% 的 Envoy CPU。
- 不限 QPS 表明单核打满时，多出的约 5 us/request 会转换为约 21% 的最大吞吐下降。

实际业务如果请求更慢、response 更大、上游 RTT 更高，固定代理开销在总延迟中的比例通常会下降；但大 payload 也会放大 DATA frame、buffer copy 和 flow-control 的每字节成本，仍需分别测试 4 KiB、64 KiB 等尺寸后才能下结论。

## 何时值得使用

这套方案更适合以下约束同时成立的场景：

- 业务 TLS 必须端到端保持，不允许代理解密。
- 只需要基于 SNI、原始目标和连接身份做 allow/deny。
- 已有策略服务使用 HTTP `ext_proc`，复用它比新建 network protocol 更重要。
- 可以接受额外的 Envoy CPU 与单核容量损失。
- 功能可以通过门禁只作用于需要检查的 TLS 连接。

如果需要读取 HTTPS path、header 或 body，就必须终结 TLS；内部 CONNECT 无法绕过加密边界。如果策略只依赖少量连接属性且性能优先级更高，原生 network filter、network ext_authz，或专门的 network ext_proc 协议可能更合适。

## 结论

将未终结 TLS 包装为内部 HTTP/2 CONNECT，提供了一种复用 Envoy HTTP `ext_proc` 的工程路径：业务 TLS 保持端到端加密，`ext_proc` 只检查 CONNECT 及其连接级 attributes，随后由 ORIGINAL_DST 恢复透明转发。

它不是零成本抽象。在本次单核小包实验中，完整路径增加约 5 us/request 的 CPU demand，使饱和吞吐下降约 21%。分层实验表明，这部分开销并非全部来自 h2 frame encode/decode：额外 internal userspace hop 与 HTTP/2 codec、HCM、router 大约各占一半。

因此，下一步优化不应只盯着 HTTP/2 connection pool，还应减少 internal hop 上的 buffer move、dispatcher callback 和 HCM/router 工作，并通过 payload-size、connection-count 和多核实验确认优化对真实 workload 的收益。

---

## 附录 A：复现实验步骤

下面使用通用资源名描述测试过程。具体 Deployment、namespace 和 admin port 请按自己的 Envoy 环境替换。

### A.1 准备环境

1. 创建单节点 KinD cluster。
2. 部署 Envoy gateway，并固定 `concurrency: 1`、CPU limit `1`。
3. 部署返回 128-byte body 的 HTTPS server。
4. 部署 Fortio 1.75.2。
5. 保持 Envoy access log 开启。
6. 从 TLS CONNECT HCM 中移除 `envoy.filters.http.ext_proc`，并把外部处理服务缩容到 0。

```bash
kind create cluster --name envoy-tls-perf

kubectl create namespace envoy-perf
kubectl -n envoy-perf scale deployment/ext-proc --replicas=0
kubectl -n envoy-perf rollout status deployment/envoy-gateway
kubectl -n envoy-perf rollout status deployment/tls-echo
kubectl -n envoy-perf rollout status deployment/fortio
```

移除 filter 后，不要只依赖控制面配置，要检查 Envoy 实际收到的 xDS：

```bash
kubectl -n envoy-perf port-forward deployment/envoy-gateway 15000:15000

curl -fsS http://127.0.0.1:15000/config_dump > /tmp/config-dump.json

# 应没有 ext_proc；仍应包含 access log。
if rg -q 'envoy.filters.http.ext_proc' /tmp/config-dump.json; then
  echo 'ext_proc is still present' >&2
  exit 1
fi

rg 'access_log|envoy.access_loggers' /tmp/config-dump.json
```

### A.2 切换路径并校验

假设使用 `ENABLE_TLS_H2_CONNECT` 控制该功能：

```bash
set_feature() {
  value="$1"

  kubectl -n envoy-perf set env deployment/envoy-gateway \
    ENABLE_TLS_H2_CONNECT="${value}"
  kubectl -n envoy-perf rollout status deployment/envoy-gateway --timeout=180s
}

set_feature false
set_feature true
```

每次切换后检查 config dump：

```bash
dump_config() {
  kubectl -n envoy-perf exec deployment/envoy-gateway -c envoy -- \
    curl -fsS http://127.0.0.1:15000/config_dump
}

set_feature false
dump_config > /tmp/off.json
! rg -q 'tls-connect-terminate|tls_connect_internal' /tmp/off.json

set_feature true
dump_config > /tmp/on.json
rg 'tls-connect-terminate|tls_connect_internal' /tmp/on.json
```

如果容器没有 `curl`，可以使用 `kubectl port-forward` 从宿主机获取 admin config dump。

### A.3 Fortio 命令

先确认 HTTPS 请求成功：

```bash
kubectl -n envoy-perf exec deployment/fortio -- \
  fortio curl https://tls-echo.envoy-perf.svc.cluster.local:8443/
```

固定 30,000 QPS：

```bash
kubectl -n envoy-perf exec deployment/fortio -- \
  fortio load \
    -c 16 \
    -qps 30000 \
    -t 20s \
    -keepalive=true \
    -json /tmp/fixed-30k.json \
    https://tls-echo.envoy-perf.svc.cluster.local:8443/
```

不限 QPS：

```bash
kubectl -n envoy-perf exec deployment/fortio -- \
  fortio load \
    -c 16 \
    -qps 0 \
    -t 15s \
    -keepalive=true \
    -json /tmp/unlimited.json \
    https://tls-echo.envoy-perf.svc.cluster.local:8443/
```

将结果复制到宿主机：

```bash
FORTIO_POD="$(kubectl -n envoy-perf get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')"

kubectl -n envoy-perf cp "${FORTIO_POD}:/tmp/fixed-30k.json" ./fixed-30k.json
kubectl -n envoy-perf cp "${FORTIO_POD}:/tmp/unlimited.json" ./unlimited.json
```

### A.4 四象限重复测试脚本

以下脚本是可移植模板。`set_feature` 和 `copy_cpu_sample` 需要按部署方式实现；其余部分保持所有条件使用相同 Fortio 参数。

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="envoy-perf"
URL="https://tls-echo.envoy-perf.svc.cluster.local:8443/"
OUT="${OUT:-./results}"

mkdir -p "${OUT}"

set_feature() {
  value="$1"
  kubectl -n "${NS}" set env deployment/envoy-gateway \
    ENABLE_TLS_H2_CONNECT="${value}" >/dev/null
  kubectl -n "${NS}" rollout status deployment/envoy-gateway \
    --timeout=180s >/dev/null
}

run_fortio() {
  mode="$1"
  run="$2"
  flag="$3"

  case "${mode}" in
    fixed)
      qps=30000
      duration=20s
      ;;
    unlimited)
      qps=0
      duration=15s
      ;;
    *)
      echo "unknown mode: ${mode}" >&2
      exit 1
      ;;
  esac

  pod="$(kubectl -n "${NS}" get pod -l app=fortio \
    -o jsonpath='{.items[0].metadata.name}')"
  remote="/tmp/${flag}-${mode}-${run}.json"

  kubectl -n "${NS}" exec "${pod}" -- \
    fortio load \
      -c 16 \
      -qps "${qps}" \
      -t "${duration}" \
      -keepalive=true \
      -json "${remote}" \
      "${URL}"

  kubectl -n "${NS}" cp \
    "${pod}:${remote}" "${OUT}/${flag}-${mode}-${run}.json"
}

# 反转开关顺序，减少机器温度、缓存和后台任务带来的时间偏差。
for run in 1 2 3 4 5; do
  if (( run % 2 == 1 )); then
    order="off on"
  else
    order="on off"
  fi

  for flag in ${order}; do
    if [[ "${flag}" == "on" ]]; then
      set_feature true
    else
      set_feature false
    fi

    run_fortio fixed "${run}" "${flag}"
    run_fortio unlimited "${run}" "${flag}"
  done
done
```

更严格的做法是每个 mode 都单独轮换顺序，并在每个 condition 前重启 Envoy，避免前一个不限 QPS 测试影响下一个固定 QPS 测试。

### A.5 从 Fortio JSON 提取指标

```bash
jq -r '
  [
    .Labels,
    .ActualQPS,
    (.DurationHistogram.Avg * 1000),
    .DurationHistogram.Count,
    .RetCodes["200"]
  ] | @tsv
' results/*.json
```

字段含义依次为 label、QPS、平均延迟（ms）、请求数和 HTTP 200 数。不同 Fortio 版本的 JSON 字段可能略有差异，正式统计前应先检查一个原始文件。

CPU 应使用同一个 Envoy container 的 `container_cpu_usage_seconds_total` 增量，除以测量窗口秒数得到平均 core：

```text
average cores =
  (cpu_usage_seconds_after - cpu_usage_seconds_before)
  / measurement_duration_seconds
```

不要使用某一时刻的 `kubectl top` 作为整段测试的平均 CPU。

### A.6 分层测试

准备三份只改变数据路径的 xDS 配置：

```text
direct       = TCP Proxy -> ORIGINAL_DST
raw_internal = TCP Proxy -> internal listener -> TCP Proxy -> ORIGINAL_DST
h2_connect   = TCP Proxy tunneling -> h2 -> HCM/router -> ORIGINAL_DST
```

三条路径都必须满足：

- 无 `ext_proc`
- access log 配置相同
- response、concurrency、CPU limit 和 Envoy concurrency 相同
- 每次切换后检查 config dump
- 每条路径至少运行 5 次
- 按 block 轮换顺序，例如：

```text
block 1: direct -> raw -> h2
block 2: h2 -> raw -> direct
block 3: raw -> direct -> h2
block 4: h2 -> direct -> raw
block 5: raw -> h2 -> direct
```

分层差异应在同一 block 内配对计算，再对 paired differences 求均值和置信区间，而不是只比较两组互不相关的总体均值。

### A.7 perf 采样

先找到宿主机上的 Envoy PID，再在固定 30k QPS 期间采样：

```bash
sudo perf record \
  -F 99 \
  -g \
  -p "${ENVOY_HOST_PID}" \
  -- sleep 10

sudo perf report --stdio --no-children > perf-report.txt
```

重点关注：

- `nghttp2_session_send` 与 HTTP/2 encode/decode
- HCM、router 和 CONNECT upgrade callback
- `TcpProxy::Filter`
- buffer slice move/drain
- `Network::ConnectionImpl`
- internal socket 与 dispatcher callback

低样本数 perf 适合寻找热点方向，最终归因仍应以受控的 direct/raw/h2 分层实验为准。

## 附录 B：实验校验清单

运行前：

- [ ] Envoy concurrency 固定为 1。
- [ ] Envoy CPU limit 固定为 1 core。
- [ ] `ext_proc` filter 已从 config dump 中消失。
- [ ] 外部处理服务 replica 为 0。
- [ ] access log 在 ON/OFF 两组中均开启。
- [ ] ON/OFF 只改变内部 CONNECT 路径。
- [ ] HTTPS upstream response 固定为 128 bytes。
- [ ] Fortio 使用 16 条 keepalive connection。

运行后：

- [ ] 每个 JSON 的连接数、持续时间和目标 QPS 符合预期。
- [ ] HTTP 200 数等于总请求数。
- [ ] error 为 0。
- [ ] 固定 QPS 组确实达到目标 QPS。
- [ ] 不限 QPS 组确实接近 CPU saturation。
- [ ] 检查 CFS throttling，避免把严重限流误判为 codec 成本。
- [ ] 报告平均值、样本数、CV 或置信区间，而不是只挑最好的一次。
