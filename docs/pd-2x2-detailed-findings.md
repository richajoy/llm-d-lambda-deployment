# P/D 2×2 deployment — detailed findings

Comprehensive analysis of llm-d P/D disaggregated inference with 2 prefill + 2 decode pods on a time-sliced GH200, using `disagg-profile-handler` + `precise-prefix-cache-scorer`.

---

## Deployment state

| Pod | Role | IP | NIXL | Traffic (prompt tokens) |
|---|---|---|---|---|
| `decode-5lz4h` | decode | 10.42.0.73 | ✅ Available | 57 |
| `decode-5s2zm` | decode | 10.42.0.75 | ✅ Available | 38 |
| `prefill-4ht5m` | prefill | 10.42.0.76 | ✅ Available | 0 |
| `prefill-pbnt7` | prefill | 10.42.0.74 | ✅ Available | 0 |

**GPU:** GH200 with time-slicing (4 replicas), 88.7 GB / 97.8 GB used. `--gpu-memory-utilization=0.20` per pod.

**EPP:** v0.7.1 with `disagg-profile-handler`, `precise-prefix-cache-scorer`, tokenizer sidecar.

---

## EPP plugin chain (verified from logs)

```
Plugins loaded:
  1. prefix-based-pd-decider        ← P/D split decision
  2. disagg-profile-handler          ← orchestrates prefill/decode profiles (replaces deprecated pd-profile-handler)
  3. disagg-headers-handler          ← sets x-prefiller-host-port header for sidecar (replaces prefill-header-handler)
  4. tokenizer                       ← tokenizes request for precise scorer (UDS socket to sidecar)
  5. precise-prefix-cache-scorer     ← real-time KV block tracking via ZMQ events
  6. kv-cache-utilization-scorer     ← KV cache fill ratio scoring
  7. queue-scorer                    ← queue depth scoring
  8. prefill-filter                  ← restricts to prefill pods
  9. decode-filter                   ← restricts to decode pods
  10. max-score-picker               ← picks highest weighted score

Scheduling profiles:
  decode:  [decode-filter → precise-prefix-cache(3) → kv-util(2) → queue(2) → max-picker]
  prefill: [prefill-filter → precise-prefix-cache(3) → kv-util(2) → queue(2) → max-picker]
```

---

## What works

### 1. Multi-decode-pod routing

The EPP routes across both decode pods. With 2 decode pods at equal load:

```
Decode 5lz4h: prompt_tokens=57, generation_tokens=30
Decode 5s2zm: prompt_tokens=38, generation_tokens=15
```

Distribution is ~60/40, influenced by the prefix-cache-scorer giving slight affinity to whichever pod was picked first.

### 2. Multi-signal scoring (all 3 scorers confirmed)

From EPP verbose logs, every request runs all three scorers on both decode pods:

```
Request a6e99560:
  Decode 5lz4h: precise-prefix=? kv-cache-util=1 queue=1 → Score=4
  Decode 5s2zm: precise-prefix=? kv-cache-util=1 queue=1 → Score=4
```

The `kv-cache-utilization-scorer` and `queue-scorer` run and score correctly. The `precise-prefix-cache-scorer` runs but returns 0 (no KV events received — see below).

### 3. Selective PD for short requests

For short inputs (< 16 tokens), the EPP correctly bypasses P/D:

```
"Input is shorter than the nonCachedToken, no disaggregated PD"
```

This is the `prefix-based-pd-decider` working correctly — short requests go directly to decode without NIXL overhead.

### 4. NIXL initialization on all 4 pods

All 4 pods report `"NIXL is available"` with UCX backend initialized. The transport stack (`tcp,sm,cuda_copy,cuda_ipc`) is functional on time-sliced GPU.

### 5. disagg-profile-handler + disagg-headers-handler

The new (non-deprecated) handlers loaded and run successfully. The execution flow is:

```
1. Decode profile runs → scores both decode pods
2. disagg-profile-handler.Pick() → calls prefix-based-pd-decider
3. Decider attempts to read cache state → fails (see below)
4. Falls back to direct-to-decode (no P/D split)
5. disagg-headers-handler runs as PreRequest plugin
6. precise-prefix-cache-scorer runs as PreRequest plugin
7. Request forwarded to selected decode pod
```

---

## What doesn't work

### 1. P/D split never triggers (prefill pods receive zero traffic)

Both prefill pods have `prompt_tokens_total: 0`. ALL requests go directly to decode. The `prefix-based-pd-decider` reports:

```
"unable to read prefix cache state"
  at prefix_based_pd_decider.go:124
  called from DisaggProfileHandler.Pick()
```

**Root cause:** The decider reads `PrefixCacheMatchInfoKey` from the selected decode endpoint. This key is populated by the `precise-prefix-cache-scorer` during the decode profile's scoring phase. The key IS populated (the scorer runs), but the decider can't read it — either because:
- The key is written to a different endpoint reference than the one the decider reads
- Or the `PrefixCacheMatchInfo` struct returned is nil/empty because no KV events have been received

### 2. Precise prefix cache scorer returns score=0

The `precise-prefix-cache-scorer` runs on both decode pods but returns `score=0` for all requests. This means the real-time KV block index is empty — no KV events from vLLM pods are reaching the EPP.

Possible causes:
- The `--kv-events-config` topic format may not match the EPP's `topicFilter: "kv@"`
- The ZMQ endpoint may not be reachable from vLLM pods to EPP
- The `discoverPods: true` mode may not be discovering the vLLM endpoints

### 3. External prefix cache hit rate = 0%

Both decode pods show:
```
external_prefix_cache_queries_total: 57 / 38  (queries made)
external_prefix_cache_hits_total: 0           (zero hits)
```

The NIXL connector is QUERYING for external cache on every request (via the NixlConnector configured with `kv_role: kv_both`), but never finding anything — because no NIXL KV transfer has happened (P/D split never triggered).

---

## Feature matrix: what can be proved

| Feature | llm-d component | Status | Evidence |
|---|---|---|---|
| **Multi-pod decode routing** | EPP + InferencePool | ✅ Proven | 60/40 split across 2 decode pods |
| **KV-cache-utilization scoring** | `kv-cache-utilization-scorer` | ✅ Proven | score=1 on both pods in EPP logs |
| **Queue-depth scoring** | `queue-scorer` | ✅ Proven | score=1 on both pods in EPP logs |
| **Selective PD (short bypass)** | `prefix-based-pd-decider` | ✅ Proven | "no disaggregated PD" for short requests |
| **NIXL transport init (time-slicing)** | NixlConnector + UCX | ✅ Proven | "NIXL is available" on all 4 pods |
| **disagg-profile-handler** | v0.7.1 plugin | ✅ Proven | Loaded and executing, replaces deprecated pd-profile-handler |
| **disagg-headers-handler** | v0.7.1 plugin | ✅ Proven | Runs as PreRequest, replaces prefill-header-handler |
| **Precise prefix cache scoring** | `precise-prefix-cache-scorer` | ⚠️ Loads but score=0 | Plugin runs, but KV events not reaching EPP index |
| **P/D split for long prompts** | `prefix-based-pd-decider` | ❌ Not working | "unable to read prefix cache state" |
| **NIXL KV transfer (prefill→decode)** | NixlConnector + routing sidecar | ❌ Not triggered | P/D split never happens, so no NIXL transfer |
| **Prefix cache hit rate improvement** | vLLM APC + EPP routing | ❌ 0% on all pods | No repeated-prefix routing, no NIXL transfers |

---

## Known upstream issues

| Issue | Reference | Impact |
|---|---|---|
| Automatic P/D path doesn't produce effective KV reuse in v0.7.1 | [Issue #1189](https://github.com/llm-d/llm-d/issues/1189) | Affects all P/D configurations |
| `pd-profile-handler` deprecated | PRs #732, #758 in scheduler repo | Replaced by `disagg-profile-handler` (which we use) |
| Precise KV scorer + adaptive P/D handler on roadmap | [RFC #535](https://github.com/llm-d/llm-d-inference-scheduler/issues/535) | v0.5-v0.6 goal |
| P/D + precise prefix routing not documented as combined feature | Official docs | Separate guides, no combined reference |

---

## vLLM-level features in this deployment

| Feature | Flag | Status |
|---|---|---|
| V1 engine | auto-detected | ✅ Active (v0.17.1) |
| BF16 dtype | auto-detected on Hopper | ✅ Active |
| FlashAttention v3 | auto-detected on Hopper | ✅ Active |
| Automatic Prefix Caching (APC) | `--enable-prefix-caching` | ✅ Enabled (but 0% hit rate — no repeated routing) |
| Chunked prefill | auto-enabled in V1 | ✅ Active |
| Enforce eager (no CUDA graphs) | `--enforce-eager` | ✅ Active (to save GPU memory with 4 pods) |
| NIXL KV connector | `--kv-transfer-config NixlConnector` | ✅ Initialized (not triggered) |
| KV events publisher | `--kv-events-config` | ✅ Configured (ZMQ to EPP port 5557) |
| Max model length | `--max-model-len=4096` | ✅ Set |
| GPU memory utilization | `--gpu-memory-utilization=0.20` | ✅ Set (4 pods sharing 96GB) |

---

## What to test next

1. **Force P/D split** by setting `nonCachedTokens: 0` (always disaggregate) — bypasses the decider's cache state check
2. **Verify NIXL transfer works** when P/D is forced — check decode pod's `KV Transfer metrics` and `External prefix cache hit rate`
3. **Test prefix affinity across 2 decode pods** — same prefix should route to the same decode pod
4. **Load test** to see queue-scorer distribute across decode pods under pressure
5. **Debug KV events pipeline** — verify ZMQ messages from vLLM reach EPP port 5557
