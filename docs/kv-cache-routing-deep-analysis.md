# KV-cache-aware routing — deep analysis

Analysis of llm-d's prefix-cache-aware routing architecture, validated against the [official blog](https://llm-d.ai/blog/kvcache-wins-you-can-see), [docs](https://llm-d.ai/docs/architecture/Components/kv-cache), and [Red Hat article](https://developers.redhat.com/articles/2025/10/07/master-kv-cache-aware-routing-llm-d-efficient-ai-inference), cross-referenced with our live cluster observations.

---

## Terminology

The llm-d ecosystem uses two terms interchangeably depending on context:

| Term | Where used | What it refers to |
|---|---|---|
| **Prefix-cache-aware routing** | Blog, scorer plugin names | The scheduling feature that routes based on token prefix locality |
| **KV-cache-aware routing** | Docs (llm-d-kv-cache library), Red Hat article | The broader routing capability built on the KV-Cache Indexer |

The distinction: "prefix cache" is the reuse mechanism (hash-based block matching in vLLM). "KV cache" is the underlying GPU memory structure. The routing feature scores pods by prefix cache affinity, hence "prefix-cache-aware routing." The infrastructure layer that enables it is the `llm-d-kv-cache` library, hence "KV-cache-aware routing."

Both terms describe the same system. The scorer plugins are named `prefix-cache-scorer` (approximate) and `precise-prefix-cache-scorer` (precise).

---

## The four routing strategies

From the official blog benchmark:

| Strategy | Scorers used | How it works |
|---|---|---|
| **Random** | None | Naive round-robin (control group) |
| **Load-aware** | queue-scorer + kv-cache-utilization-scorer | Routes to least-loaded pod by queue depth and KV cache fill |
| **Approximate** | prefix-cache-scorer + queue + kv-util | Extends load-aware with routing-history-based prefix locality |
| **Precise** | precise-prefix-cache-scorer + queue + kv-util | Uses real-time KV events from vLLM for exact cache state |

### Official benchmark results

| Metric | Precise | Approximate | Load-only | Random |
|---|---|---|---|---|
| Output tokens/sec | **8,730** | 6,944 | 4,429 | 4,429 |
| TTFT P90 (sec) | **0.54** | 31.08 | 94.87 | 92.55 |
| TTFT Mean (sec) | **0.30** | 13.32 | 46.99 | 45.28 |
| vLLM Wait Queue (mean) | **0.1** | 8.1 | 28.9 | 27.3 |

Headlines:
- Precise is **57× faster** P90 TTFT than approximate
- Precise delivers **2× throughput** vs cache-blind strategies
- Precise keeps wait queue near zero (0.1 vs 28.9 for random)

From the Red Hat article (separate benchmark): **87.4% cache hit rate** with warm cache TTFT of **340 ms** vs cold **2,850 ms** (88% reduction).

---

## KV-Cache Indexer architecture

The precise scorer uses a two-layer indexing system (from official docs):

### Layer 1: `kvevents.Pool` (low-level KV block tracking)

"Consumes the high-throughput stream of events. Continuously updates a low-level KV-Block Index, which maintains a simple, real-time map of block-hashes to the pod and memory-medium (GPU/CPU) it resides on."

### Layer 2: `kvcache.Index` (prefix-level scoring)

"The higher-level index used by the scheduler. Uses the underlying KV-Block Index to map logical sequences of tokens (prefixes) to the pods that hold them."

### Read path (when a request arrives)

1. Scheduler asks the KV-Cache Indexer to score pods for a given prompt
2. Indexer calculates KV-block keys from the prompt tokens
3. Queries the KV-Block Index to find which pods have those blocks
4. Returns a map of pods → cache-hit scores using **longest consecutive prefix matching**

### Write path (when vLLM stores/evicts blocks)

1. vLLM pods emit `KVEvents` (`BlockStored`, `BlockRemoved`) via ZMQ
2. Event subscriber in the EPP consumes events and updates the KV-Block Index in near-real-time

---

## What we proved in our deployment

### Aggregated mode (2 pods, MIG or time-sliced)

| Feature | Result | Evidence |
|---|---|---|
| Approximate prefix routing | **73% hit rate**, same prefix → same pod | Metrics: `prefix_cache_hits/queries = 768/1053` |
| Queue-depth distribution | **18/12 split** under 30 concurrent | EPP logs: `num_requests_running` per pod |
| KV-cache-utilization scoring | **Runs and scores** every request | EPP logs: `kv-cache-utilization-scorer score=1` |
| Multi-model routing | **Routes by model name** (7B + 0.5B) | EPP logs: distinct `modelName` → `targetModelName` |
| HPA autoscaling | **1→2→3→4 pods, then scale-down** | HPA events: `SuccessfulRescale` with `inference_pool_queue_size` |

### P/D disaggregated mode (2 prefill + 2 decode, time-sliced)

| Feature | Result | Evidence |
|---|---|---|
| NIXL init on all pods | **✅ Works** on time-sliced GPU | All 4 pods: `"NIXL is available"` |
| Multi-signal scoring | **✅ All 3 scorers run** | EPP logs: precise + kv-util + queue on both decode pods |
| Selective PD (short requests) | **✅ Bypasses prefill** | EPP: `"no disaggregated PD"` for <16 token inputs |
| disagg-profile-handler | **✅ Loads and runs** | EPP startup logs confirm |
| Precise scorer loading | **⚠️ Loads but score=0** | No KV events reaching EPP index |
| P/D split for long prompts | **❌ Never triggers** | `"unable to read prefix cache state"` |
| NIXL KV transfer | **❌ Not triggered** | Prefill pods: `prompt_tokens_total=0` |
| Prefix cache hit rate | **❌ 0% on all pods** | No routing history, no NIXL transfers |

### NIXL KV transfer (proven earlier with 1+1 config)

When P/D DID work (earlier 1 prefill + 1 decode with approximate mode):

```
External prefix cache hit rate: 54.3%
KV Transfer: Num successful=1, Avg xfer=17.3ms, 7.0 MB, 403.8 MB/s
56 KV block descriptors transferred
```

This proved NIXL transport works on time-sliced GPU. The current 2+2 config doesn't trigger P/D split, so NIXL isn't exercised.

---

## Gap: P/D + precise is not integrated (v0.7.1)

### The interface IS compatible

Both `prefix-cache-scorer` (approximate) and `precise-prefix-cache-scorer` populate the same `PrefixCacheMatchInfoKey` on endpoints. The `prefix-based-pd-decider` reads this key. They're interchangeable at the interface level.

### The implementation has a gap

The `prefix-based-pd-decider` at line 124 tries to read `PrefixCacheMatchInfoKey` from the selected decode endpoint. Even though the precise scorer populates this key during the decode profile's scoring phase, the decider can't read it — resulting in `"unable to read prefix cache state"`.

### Upstream tracking

| Reference | Description |
|---|---|
| [Issue #1189](https://github.com/llm-d/llm-d/issues/1189) | Automatic P/D path doesn't produce effective KV reuse in v0.7.1 |
| [RFC #535](https://github.com/llm-d/llm-d-inference-scheduler/issues/535) | Roadmap: "precise KV scorer + adaptive P/D handler" as v0.5-v0.6 goal |
| PRs #732, #758 | `pd-profile-handler` deprecated → `disagg-profile-handler` |

### P/D + precise is mentioned but not benchmarked

The official blog mentions DaoCloud adopting "P/D disaggregation and advanced KV-cache architectures via Kubernetes, vLLM, and llm-d" — confirming the intent to combine these features. No combined benchmark exists.

---

## Relationship between KV cache, prefix cache, and routing

```
                          vLLM Instance
                    ┌─────────────────────────┐
Request arrives →   │  Tokenize prompt         │
                    │  Hash token blocks       │
                    │        ↓                 │
                    │  Check Prefix Cache      │ ← "Do I have these KV blocks?"
                    │  (hash-based lookup)     │
                    │        ↓                 │
                    │  HIT: reuse KV tensors   │ ← skip compute, use cached
                    │  MISS: compute attention │ ← full prefill computation
                    │        ↓                 │
                    │  Store in KV Cache       │ ← GPU memory (PagedAttention blocks)
                    │  Publish KVEvent (ZMQ)   │ ← "I now have block X" (precise mode only)
                    └─────────────────────────┘

                          EPP Scheduler
                    ┌─────────────────────────┐
                    │  Receive KVEvent         │ ← "Pod A has block X"
                    │  Update KV-Block Index   │
                    │        ↓                 │
New request →       │  Score pods for request  │
                    │  prefix-cache: "Pod A    │ ← "Pod A has 80% of this prefix cached"
                    │    has best match"       │
                    │  kv-util: "Pod B has     │ ← "Pod B has 90% cache fill — penalize"
                    │    more headroom"        │
                    │  queue: "Pod A has 2     │ ← "Pod A is lightly loaded"
                    │    requests running"     │
                    │        ↓                 │
                    │  Weighted score:         │
                    │    Pod A = 3×0.8 + 2×1.0 + 2×0.9 = 6.2  ← PICK
                    │    Pod B = 3×0.1 + 2×0.5 + 2×1.0 = 3.3
                    │        ↓                 │
                    │  Route to Pod A          │
                    └─────────────────────────┘
```

The KV cache is the **memory structure**. The prefix cache is the **reuse mechanism**. The routing uses prefix cache state (which blocks are where) to make placement decisions. In precise mode, the EPP knows the exact cache state via real-time events. In approximate mode, it infers from routing history.
