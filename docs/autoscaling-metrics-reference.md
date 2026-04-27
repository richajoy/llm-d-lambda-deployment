# llm-d autoscaling metrics reference

Complete reference of metrics available for autoscaling in llm-d, how they flow through the system, and how to configure HPA to use them.

---

## Metrics pipeline

```
vLLM pod /metrics (:8000)
    │ scraped every 10s by EPP
    ▼
EPP aggregates into pool-level metrics
    │ exposed on :9090/metrics
    ▼
Prometheus scrapes EPP (via ServiceMonitor)
    │ stored as time series
    ▼
Prometheus Adapter bridges to k8s External Metrics API
    │
    ▼
HPA reads external metrics every 15s → computes desired replicas → scales Deployment
```

The EPP is the **single source of truth** for inference-aware metrics. It scrapes each vLLM pod and aggregates into pool-level signals. You do NOT need to scrape vLLM pods directly — the EPP does that for you.

---

## Pool-level metrics (from EPP)

These are the metrics the EPP exposes on its `:9090/metrics` endpoint. They are the recommended signals for autoscaling.

### Primary autoscaling signals

| Metric | Type | What it measures | Autoscaling usage |
|---|---|---|---|
| `inference_pool_average_queue_size` | gauge | Average `num_requests_waiting` across all pods in the pool | **Scale-out**: high queue = requests waiting for processing. Threshold: 5-10 depending on model latency. |
| `inference_pool_average_kv_cache_utilization` | gauge | Average `kv_cache_usage_perc` (0-1) across all pods | **Scale-out**: high KV cache = pods running out of memory for new KV entries. Threshold: 0.70-0.85. |
| `inference_objective_running_requests` | gauge | Total requests being processed by all pods in the pool | **Scale-out**: high running count = compute saturation. Threshold: N × max_num_seqs. |
| `inference_pool_ready_pods` | gauge | Number of pods passing readiness probe | **Informational**: useful for understanding current capacity. |

### Flow control signals (EPP gateway-level buffering)

| Metric | Type | What it measures | Autoscaling usage |
|---|---|---|---|
| `inference_extension_flow_control_queue_size` | gauge | Requests buffered AT the EPP (not yet dispatched to any pod) | **Scale-out**: non-zero = EPP can't find a suitable backend. Requires `flowControl` feature gate. |
| `inference_extension_flow_control_queue_bytes` | gauge | Bytes buffered in the flow control queue | Size-aware variant of queue_size. |
| `inference_extension_flow_control_dispatch_cycle_duration_seconds` | histogram | Time per dispatch cycle | High latency = EPP struggling to find backends. |
| `inference_extension_flow_control_request_queue_duration_seconds` | histogram | Time each request spends in the EPP queue | Direct measure of queueing delay. |

### Scheduling performance signals

| Metric | Type | What it measures |
|---|---|---|
| `inference_extension_scheduler_e2e_duration_seconds` | histogram | End-to-end scheduling latency (pick endpoint + dispatch) |
| `inference_extension_scheduler_attempts_total` | counter | Total scheduling attempts |
| `inference_extension_plugin_duration_seconds` | histogram | Time spent in each scorer plugin |

### Prefix cache signals

| Metric | Type | What it measures |
|---|---|---|
| `inference_extension_prefix_indexer_size` | gauge | Number of entries in the EPP's prefix locality index |
| `inference_extension_prefix_indexer_hit_ratio` | histogram | Hit ratio of the prefix index (how often the EPP's prefix prediction was correct) |
| `inference_extension_prefix_indexer_hit_bytes` | histogram | Bytes served from prefix cache hits |

### Request lifecycle signals (per model/objective)

| Metric | Type | What it measures |
|---|---|---|
| `inference_objective_request_total` | counter | Total requests per model |
| `inference_objective_request_duration_seconds` | histogram | End-to-end request duration per model |
| `inference_objective_input_tokens` | histogram | Input token count distribution |
| `inference_objective_output_tokens` | histogram | Output token count distribution |
| `inference_objective_prompt_cached_tokens` | histogram | Cached token count distribution |
| `inference_objective_running_requests` | gauge | Currently running requests per model |

---

## vLLM pod-level metrics (scraped by EPP, not directly by Prometheus)

These are exposed by each vLLM pod on `:8000/metrics`. The EPP scrapes them and aggregates into the pool-level metrics above. Direct scraping (via PodMonitor) is optional and gives per-pod visibility.

| Metric | What it shows |
|---|---|
| `vllm:num_requests_running` | Current batch size on this pod |
| `vllm:num_requests_waiting` | Queue depth on this pod |
| `vllm:kv_cache_usage_perc` | KV cache fill ratio (0-1) |
| `vllm:prefix_cache_queries_total` | Prefix cache lookups |
| `vllm:prefix_cache_hits_total` | Prefix cache hits |
| `vllm:avg_prompt_throughput_toks_per_s` | Prompt processing speed |
| `vllm:avg_generation_throughput_toks_per_s` | Token generation speed |
| `vllm:time_to_first_token_seconds` | TTFT distribution |
| `vllm:time_per_output_token_seconds` | TPOT distribution |
| `vllm:e2e_request_latency_seconds` | End-to-end latency |

---

## GPU hardware metrics (NOT from llm-d — separate install)

| Metric | Source | What's needed |
|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | NVIDIA DCGM Exporter | Install DCGM Exporter DaemonSet |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | DCGM Exporter | Same |
| `DCGM_FI_DEV_POWER_USAGE` | DCGM Exporter | Same |

These are NOT part of llm-d and are generally NOT recommended for LLM autoscaling because GPU utilization is often pegged at ~100% during active batching regardless of actual load.

---

## Two autoscaling architectures in llm-d

### 1. HPA + IGW Metrics (what we deployed)

Simple, standard Kubernetes HPA with EPP metrics via Prometheus Adapter.

```
EPP metrics → Prometheus → Prometheus Adapter → External Metrics API → HPA
```

**Best for:** Single-model deployments on homogeneous hardware.

### 2. WVA (Workload Variant Autoscaler)

Advanced controller that optimizes across multiple hardware variants.

```
EPP metrics → Prometheus → WVA Controller
                               ↓
                    Computes optimal replica counts per variant
                    (minimize cost while meeting latency SLO)
                               ↓
                    Emits optimization metrics → Prometheus Adapter → HPA
```

**Best for:** Multi-variant deployments (e.g., same model on A100s + L4s) where cost-aware scaling matters.

WVA uses:
- KV cache saturation (primary signal)
- Queue depth
- Energy and performance budgets
- Cost per variant (prefers cheaper hardware for scale-out)

> **Note:** We deployed and tested the HPA + IGW Metrics path in this repo. WVA was not deployed because our setup uses a single hardware type (GH200 MIG/time-sliced instances). WVA's cost-optimization requires multiple hardware variants to differentiate. See [`autoscaling-test-results.md`](autoscaling-test-results.md) for full rationale.

---

## Multi-signal HPA configuration (deployed)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  metrics:
  # Signal 1: Queue depth
  - type: External
    external:
      metric:
        name: inference_pool_queue_size        # from inference_pool_average_queue_size
      target:
        type: Value
        value: "5"                              # scale when avg queue > 5
  # Signal 2: KV cache utilization
  - type: External
    external:
      metric:
        name: inference_pool_kv_cache_util     # from inference_pool_average_kv_cache_utilization
      target:
        type: Value
        value: "800m"                           # scale when KV cache > 80% (0.8)
  # Signal 3: Running requests
  - type: External
    external:
      metric:
        name: inference_running_requests       # from inference_objective_running_requests
      target:
        type: Value
        value: "10"                             # scale when total running > 10
```

**HPA evaluates all three signals and takes the MAX desired replicas.** Whichever signal demands the most capacity wins.
