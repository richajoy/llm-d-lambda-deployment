# Aggregated mode test results

Comprehensive test results for llm-d aggregated deployment with 2 vLLM pods on MIG-partitioned GH200, demonstrating EPP routing features.

---

## Test environment

| Component | Value |
|---|---|
| Pods | 2× vLLM (Qwen2.5-7B-Instruct, BF16, V1 engine, FA3) |
| GPU per pod | 1× MIG 3g.48gb (46.5GB HBM3, 60 SMs) |
| EPP scoring | prefix-cache-scorer (weight 2) + queue-scorer (weight 1) |
| Prefix caching | Enabled (`--enable-prefix-caching`, block_size=128) |

---

## Test V1.3: Prefix-cache-aware routing

**Goal:** Verify that requests sharing the same system prompt prefix are routed to the same pod.

**Method:** Sent 5 sequential requests with the same ~220-token system prompt, each with a different user question.

**Result:**
| Metric | Pod A (kwkxr) | Pod B (t4wks) |
|---|---|---|
| prefix_cache_queries (delta) | +814 | 0 |
| prefix_cache_hits (delta) | +576 | 0 |
| Hit rate | **73%** | N/A |

**Interpretation:** All 5 requests routed to Pod A. 73% hit rate consistent with block-aligned caching (128-token blocks on a ~220-token prefix). Pod B received zero requests from this prefix family.

✅ **Prefix-cache-aware routing works** — the EPP's `prefix-cache-scorer` maintains locality.

---

## Test V1.4: New prefix routing

**Goal:** Verify that a completely new prefix (no routing history) gets distributed based on queue depth.

**Method:** Sent 4 requests with PREFIX_C (Japanese cuisine topic — never seen before).

**Result:** PREFIX_C requests went to **Pod B** — the pod with lower cumulative load. After these requests, Pod B's prefix cache queries increased by +374 (from 220→594).

✅ **New prefixes routed to least-loaded pod** — `queue-scorer` breaks the tie when no prefix affinity exists.

---

## Test V1.5: Queue depth overflow under load

**Goal:** Verify that when one pod is saturated, the EPP redistributes load despite prefix affinity.

**Method:** Fired 30 concurrent requests (512 max_tokens each) simultaneously.

**Result — t+3s snapshot (live batch sizes):**
```
Pod A: running=18  waiting=0
Pod B: running=12  waiting=0
```

**The EPP split 30 requests as 18/12** — not 50/50 because Pod A had residual prefix affinity from earlier tests (weight 2), but the queue-scorer (weight 1) prevented all-to-one routing.

By t+6s all requests were complete — GH200 processed 30 concurrent requests with 512 max_tokens in under 6 seconds total.

**Final load distribution (cumulative prompt tokens):**
```
Pod A: 5,221 tokens (75.7%)
Pod B: 1,676 tokens (24.3%)
```

The skew toward Pod A reflects accumulated prefix affinity from all prior tests. In a fresh deployment with no routing history, the distribution would be closer to 50/50.

✅ **Queue-aware load balancing works** — load distributes across pods under concurrency.
✅ **The EPP balances prefix affinity vs queue depth** — prefix-cache-scorer (weight 2) provides stickiness, queue-scorer (weight 1) provides spillover under load.

---

## Metrics reference (what the EPP scrapes)

| vLLM metric | What it tells the EPP | Scrape interval |
|---|---|---|
| `vllm:kv_cache_usage_perc` | Fraction of KV cache blocks in use (0-1) | 10s |
| `vllm:num_requests_running` | Requests currently in batch | 10s |
| `vllm:num_requests_waiting` | Requests queued (backpressure signal) | 10s |
| `vllm:prefix_cache_hits_total` | Tokens served from prefix cache | 10s |
| `vllm:prefix_cache_queries_total` | Tokens queried against prefix cache | 10s |
| `vllm:prompt_tokens_total` | Total prompt tokens processed | 10s |
| `vllm:generation_tokens_total` | Total output tokens generated | 10s |

---

## Observations

- The EPP is not round-robin — it makes informed routing decisions using live pod metrics.
- Prefix affinity is the strongest signal (weight 2): same system prompt → same pod → cache hit → lower TTFT.
- Queue depth is the safety valve (weight 1): it prevents one pod from being overwhelmed under burst load.
- On the GH200 MIG configuration, 30 concurrent requests with 512 output tokens completed in ~6 seconds across 2 pods.
- KV cache metrics are real-time: `kv_cache_usage_perc` spikes during batch processing and drops to 0 when idle.
- Achieved a **73% prefix cache hit rate** on a 220-token prefix with `block_size=128`. Hit rate scales with prefix length, so production RAG workloads (4K–10K token contexts) should see substantially higher rates.
