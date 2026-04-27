# llm-d Feature Testing — Aggregated & P/D Disaggregated Inference

Systematic testing of [llm-d](https://github.com/llm-d/llm-d) inference features across two deployment modes: **aggregated** (multi-replica with intelligent routing) and **prefill/decode disaggregated** (NIXL KV cache transfer with GPU time-slicing). Reproducible on a single Hopper-class GPU node running k3s.

---

## Features tested

| Feature | Mode | Status | Details |
|---|---|---|---|
| Approximate prefix-cache-aware routing | Aggregated | Pass — 73% hit rate, same prefix → same pod | [prefix-cache-testing.md](docs/prefix-cache-testing.md) |
| Precise prefix-cache-aware routing | Aggregated | Pass — EPP KV block index populated via ZMQ events, score=1 on cached pod, score=0 on other | [precise-aggregated-testing.md](docs/precise-aggregated-testing.md) |
| Approximate prefix-cache-aware routing | P/D | Pass — routes across decode pods using routing history | [pd-timeslicing-breakthrough.md](docs/pd-timeslicing-breakthrough.md) |
| Precise prefix-cache-aware routing | P/D | Fail — decider can't read precise cache state (v0.7.1 gap) | [precise-prefix-routing-findings.md](docs/precise-prefix-routing-findings.md) |
| Queue-depth load balancing | Aggregated | Pass — 30 concurrent requests split 18/12 across pods | [aggregated-test-results.md](docs/aggregated-test-results.md) |
| KV-cache-utilization scoring | Both | Pass — weighted scorer runs on every routing decision | [precise-aggregated-testing.md](docs/precise-aggregated-testing.md) |
| Multi-model routing | Aggregated | Pass — 7B + 0.5B models routed by model name | [multi-model-test-results.md](docs/multi-model-test-results.md) |
| HPA autoscaling (inference pool metrics) | Aggregated | Pass — scales 1→4 pods, drains on scale-down | [autoscaling-test-results.md](docs/autoscaling-test-results.md) |
| Selective P/D (prefix-based-pd-decider) | P/D | Pass — short requests skip prefill, long requests trigger split | [pd-timeslicing-breakthrough.md](docs/pd-timeslicing-breakthrough.md) |
| NIXL KV transfer on time-sliced GPU | P/D | Pass — 403 MB/s via cuda_ipc, 54.3% external cache hit | [pd-timeslicing-breakthrough.md](docs/pd-timeslicing-breakthrough.md) |
| NIXL KV transfer on MIG | P/D | Fail — CUDA IPC blocked between MIG instances | [pd-timeslicing-breakthrough.md](docs/pd-timeslicing-breakthrough.md) |
| 2×2 P/D (2 prefill + 2 decode) | P/D | Partial — pods run, multi-decode routing works, P/D split blocked by precise scorer gap | [pd-2x2-detailed-findings.md](docs/pd-2x2-detailed-findings.md) |

---

## Deployment variants tested

### Variant 1: Aggregated (2 replicas, MIG 3g.48gb)

Standard llm-d deployment with two vLLM pods on MIG-partitioned GPU. EPP routes using prefix-cache affinity + queue depth + KV utilization. Tested: prefix routing, queue balancing, multi-model, autoscaling.

→ [Aggregated test results](docs/aggregated-test-results.md) | [Prefix cache testing](docs/prefix-cache-testing.md) | [Multi-model](docs/multi-model-test-results.md) | [Autoscaling](docs/autoscaling-test-results.md)

### Variant 2: Aggregated (4 replicas, MIG 1g.24gb)

Smaller MIG partitions to demonstrate autoscaling under queue pressure. HPA with multi-signal `inference_pool_average_queue_size` + `kv_cache_utilization` + `running_requests`. Scaled 1→2→3→4 pods and back down.

→ [Autoscaling results](docs/autoscaling-test-results.md) | [Metrics reference](docs/autoscaling-metrics-reference.md)

### Variant 3: P/D disaggregated (1+1, time-sliced, approximate routing)

First working P/D on single GPU. NIXL KV transfer confirmed: 403 MB/s, 17ms per transfer, 54.3% external prefix cache hit rate. Uses approximate `prefix-cache-scorer`.

→ [P/D time-slicing](docs/pd-timeslicing-breakthrough.md)

### Variant 4: Aggregated (2 replicas, time-sliced, precise prefix routing)

Precise prefix-cache-aware routing with real-time KV events via ZMQ. The EPP's `precise-prefix-cache-scorer` builds a live index of which KV blocks are on which pod. Scored pod with 2 cached blocks at `score=1`, pod without at `score=0`. 71.1% prefix cache hit rate on the cached pod.

→ [Precise aggregated testing](docs/precise-aggregated-testing.md)

### Variant 5: P/D disaggregated (1+1, time-sliced, precise routing attempt)

Upgraded to `precise-prefix-cache-scorer` with tokenizer sidecar and KV events in P/D mode. Scorer loads but `prefix-based-pd-decider` reports `"unable to read prefix cache state"`. Upstream gap: [Issue #1189](https://github.com/llm-d/llm-d/issues/1189). Approximate routing works as fallback for P/D.

→ [Precise prefix findings](docs/precise-prefix-routing-findings.md)

### Variant 5: P/D disaggregated (2+2, time-sliced, disagg-profile-handler)

Full 2 prefill + 2 decode with `disagg-profile-handler` (v0.7.1, replaces deprecated `pd-profile-handler`). All 4 pods + NIXL initialized. Multi-decode routing works. P/D split decision still blocked by same precise scorer gap.

→ [2×2 detailed findings](docs/pd-2x2-detailed-findings.md)

---

## Architecture

### Aggregated mode

```
Client → agentgateway → HTTPRoute → InferencePool → EPP scheduler
                                                        │
                                    prefix-cache-scorer (weight 2)
                                    queue-scorer (weight 1)
                                    kv-cache-utilization-scorer (weight 2)
                                                        │
                                         ┌──────────────┴──────────────┐
                                         ▼                             ▼
                                    vLLM Pod A                    vLLM Pod B
```

### P/D disaggregated mode

```
Client → agentgateway → HTTPRoute → InferencePool → EPP scheduler
                                                        │
                                     disagg-profile-handler decides P/D split
                                                        │
                              ┌─────────────────────────┴────────────────────────┐
                              ▼                                                  ▼
                    Prefill pod(s)                                     Decode pod(s)
                    vLLM (NixlConnector)                               routing-sidecar → vLLM
                              │                                                  │
                              └──── NIXL KV transfer (cuda_ipc + tcp) ──────────┘
```

**Why time-slicing, not MIG:** MIG blocks CUDA IPC between instances. NIXL requires CUDA IPC. Time-slicing shares GPU memory space, keeping CUDA IPC functional. Requires `UCX_TLS=tcp,sm,cuda_copy,cuda_ipc` and `hostIPC: true`.

---

## Infrastructure

| Component | Version / Details |
|---|---|
| GPU | NVIDIA GH200 (96 GB HBM3, Hopper compute 9.0, ARM64) |
| Kubernetes | k3s v1.34.6 (ARM64) |
| Gateway | agentgateway v1.0.0 |
| llm-d charts | infra v1.4.0, inferencepool v1.4.0, modelservice v0.4.9 |
| EPP scheduler | v0.7.0 (aggregated), v0.7.1 (P/D with disagg-profile-handler) |
| Model server | `ghcr.io/llm-d/llm-d-cuda:v0.6.0` (ARM64) |
| Model | Qwen/Qwen2.5-7B-Instruct (BF16, V1 engine, FlashAttention v3) |

---

## Documentation index

### Test results

| Document | Variant | Description |
|---|---|---|
| [prefix-cache-testing.md](docs/prefix-cache-testing.md) | Aggregated | 73% hit rate, block-aligned caching analysis |
| [aggregated-test-results.md](docs/aggregated-test-results.md) | Aggregated | Prefix routing, queue balancing, load distribution tests |
| [multi-model-test-results.md](docs/multi-model-test-results.md) | Aggregated | Qwen 7B + 0.5B model-name-based routing |
| [autoscaling-test-results.md](docs/autoscaling-test-results.md) | Aggregated | HPA + EPP metrics, 1→4 pod scaling with drain |
| [precise-aggregated-testing.md](docs/precise-aggregated-testing.md) | Aggregated | Precise prefix scorer with ZMQ KV events, block_size alignment, 71% hit rate |
| [pd-timeslicing-breakthrough.md](docs/pd-timeslicing-breakthrough.md) | P/D (1+1) | NIXL on time-sliced GPU, MIG failure analysis, UCX config |
| [precise-prefix-routing-findings.md](docs/precise-prefix-routing-findings.md) | P/D (1+1) | Precise scorer + P/D: config, limitations, approximate vs precise |
| [pd-2x2-detailed-findings.md](docs/pd-2x2-detailed-findings.md) | P/D (2+2) | Full 2 prefill + 2 decode state, plugin chain, feature matrix |

### Deep dives

| Document | Description |
|---|---|
| [autoscaling-metrics-reference.md](docs/autoscaling-metrics-reference.md) | 54 EPP metrics, HPA config, WVA vs HPA+IGW comparison |
| [kv-cache-routing-deep-analysis.md](docs/kv-cache-routing-deep-analysis.md) | Official blog/docs analysis: 4 routing strategies, KV-Cache Indexer architecture, performance numbers |

### Deployment reference

| Document | Description |
|---|---|
| [k3s-gpu-setup.md](docs/k3s-gpu-setup.md) | k3s GPU setup with MIG and time-slicing partitioning paths |
| [llm-d-install.md](docs/llm-d-install.md) | Three Helm releases, P/D architecture |

### Helm values

| File | Variant | Status |
|---|---|---|
| [values_gh200_agg.yaml](helm/values_gh200_agg.yaml) | Aggregated (2 replicas) | Working |
| [values_gh200_pd.yaml](helm/values_gh200_pd.yaml) | P/D with MIG | Non-functional (MIG blocks CUDA IPC) |
| [values_gh200_ts_pd.yaml](helm/values_gh200_ts_pd.yaml) | P/D with time-slicing | Working |

---

## Known issues and gaps

- **Precise prefix routing + P/D is not integrated in v0.7.1.** The `precise-prefix-cache-scorer` loads and scores, but the `prefix-based-pd-decider` cannot read the precise cache index. Tracked in [Issue #1189](https://github.com/llm-d/llm-d/issues/1189) and [RFC #535](https://github.com/llm-d/llm-d-inference-scheduler/issues/535). Approximate routing works as fallback.

- **MIG is incompatible with NIXL on a single GPU.** CUDA IPC is blocked across MIG instances by design. P/D requires time-slicing or multi-GPU with RDMA/InfiniBand.

- **`block_size` must match between vLLM and EPP.** The EPP's `tokenProcessorConfig.blockSize` and vLLM's `--block-size` must be identical (default: 64). A mismatch causes the KV block index to produce zero matches — the scorer returns `score=0` for all endpoints even when events flow correctly. This was the root cause of our initial precise routing failure.

- **Prompts shorter than `block_size` produce 0% cache hits.** vLLM's prefix cache operates at the block level. A prompt must be at least `block_size` tokens long for a complete block to form and be cached.

- **Time-slicing has no memory isolation.** All pods share GPU memory. Requires careful `--gpu-memory-utilization` tuning (0.40 for 2 pods, 0.20 for 4 pods).

- **Routing sidecar is experimental.** Per official docs, the `llm-d-routing-sidecar` "will be removed in an upcoming iteration."

---

## Reproducing

1. Provision a Hopper-class GPU node and install k3s → [k3s-gpu-setup.md](docs/k3s-gpu-setup.md)
2. Install llm-d Helm charts → [llm-d-install.md](docs/llm-d-install.md)
3. **Aggregated:** use [values_gh200_agg.yaml](helm/values_gh200_agg.yaml), run [test-aggregated.sh](scripts/test-aggregated.sh)
4. **P/D:** configure time-slicing per [pd-timeslicing-breakthrough.md](docs/pd-timeslicing-breakthrough.md), use [values_gh200_ts_pd.yaml](helm/values_gh200_ts_pd.yaml)

---

## License

Apache 2.0
