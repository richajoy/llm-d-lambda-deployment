# Precise prefix-cache-aware routing — aggregated mode

Deployment and testing of `precise-prefix-cache-scorer` in aggregated mode with 2 vLLM pods on a time-sliced GH200. Demonstrates real-time KV-cache-aware routing where the EPP knows exactly which pod has which prefix blocks cached, and routes accordingly.

---

## Result: working

```
Got endpoint scores: {"10.42.0.98:8000": 2}         ← EPP knows pod has 2 cached blocks

precise-prefix-cache-scorer  endpoint=89bgk  score=1  ← HAS cache → routed here
precise-prefix-cache-scorer  endpoint=ztkbs  score=0  ← no cache → skipped

Pod 89bgk: hits=1152 queries=1620 → 71.1% prefix cache hit rate
Pod ztkbs: hits=0    queries=0    → no traffic (EPP routes to cached pod)
```

The precise scorer correctly identifies which pod holds the prefix blocks and routes all same-prefix requests there. The other pod receives zero traffic for this prefix.

---

## Configuration

### EPP (v0.7.1) — GAIE values

```yaml
inferenceExtension:
  image:
    name: llm-d-inference-scheduler
    hub: ghcr.io/llm-d
    tag: v0.7.1
  extProcPort: 9002
  extraContainerPorts:
    - name: zmq
      containerPort: 5557
      protocol: TCP
  extraServicePorts:
    - name: zmq
      port: 5557
      targetPort: 5557
      protocol: TCP
  env:
    - name: HF_TOKEN
      valueFrom:
        secretKeyRef:
          name: llm-d-hf-token
          key: HF_TOKEN
  sidecar:
    enabled: true
    image: ghcr.io/llm-d/llm-d-uds-tokenizer:v0.7.1
    name: tokenizer-uds
    env:
      - name: TOKENIZERS_DIR
        value: /tokenizers
      - name: HF_HOME
        value: /tokenizers
    volumeMounts:
      - mountPath: /tokenizers
        name: tokenizers
      - mountPath: /tmp/tokenizer
        name: tokenizer-uds
  pluginsCustomConfig:
    precise-agg-config.yaml: |
      apiVersion: inference.networking.x-k8s.io/v1alpha1
      kind: EndpointPickerConfig
      plugins:
        - type: single-profile-handler
        - type: tokenizer
          parameters:
            modelName: Qwen/Qwen2.5-7B-Instruct
            udsTokenizerConfig:
              socketFile: /tmp/tokenizer/tokenizer-uds.socket
        - type: precise-prefix-cache-scorer
          parameters:
            tokenProcessorConfig:
              blockSize: 64                    # MUST match vLLM --block-size
            indexerConfig:
              speculativeIndexing: true
              tokenizersPoolConfig:
                modelName: Qwen/Qwen2.5-7B-Instruct
                uds:
                  socketFile: /tmp/tokenizer/tokenizer-uds.socket
            kvEventsConfig:
              topicFilter: "kv@"
              concurrency: 4
              discoverPods: false              # centralized mode: EPP binds, vLLM connects
              zmqEndpoint: "tcp://*:5557"
        - type: kv-cache-utilization-scorer
        - type: queue-scorer
        - type: max-score-picker
      schedulingProfiles:
        - name: default
          plugins:
            - pluginRef: precise-prefix-cache-scorer
              weight: 3.0
            - pluginRef: kv-cache-utilization-scorer
              weight: 2.0
            - pluginRef: queue-scorer
              weight: 2.0
            - pluginRef: max-score-picker
```

**Plugin chain explained:**

| Plugin | Type | Purpose |
|---|---|---|
| `single-profile-handler` | ProfileHandler | Aggregated mode — single "default" profile, no P/D split |
| `tokenizer` | Utility | Tokenizes incoming prompts via UDS socket to the tokenizer sidecar |
| `precise-prefix-cache-scorer` | Scorer | Queries the KV block index built from ZMQ events; scores pods by prefix block match |
| `kv-cache-utilization-scorer` | Scorer | Scores pods by KV cache fill ratio (lower usage = more headroom) |
| `queue-scorer` | Scorer | Scores pods by queue depth (fewer requests = better) |
| `max-score-picker` | Picker | Selects the pod with the highest weighted score |

**Scoring weights:** precise prefix (3.0) + KV utilization (2.0) + queue depth (2.0). The prefix scorer has the highest weight — cache affinity is the primary routing signal.

### vLLM pods (llm-d-cuda:v0.6.0)

```yaml
containers:
  - name: vllm
    image: ghcr.io/llm-d/llm-d-cuda:v0.6.0
    args:
      - "--disable-uvicorn-access-log"
      - "--gpu-memory-utilization=0.40"
      - "--max-model-len=4096"
      - "--enable-prefix-caching"
      - "--block-size=64"                    # MUST match EPP blockSize
      - "--kv-events-config"
      - '{"enable_kv_cache_events": true, "publisher": "zmq",
          "endpoint": "tcp://gaie-pd-epp.llm-d-pd.svc.cluster.local:5557",
          "topic": "kv@$(POD_IP):8000@Qwen/Qwen2.5-7B-Instruct"}'
    env:
      - name: POD_IP
        valueFrom:
          fieldRef:
            fieldPath: status.podIP
```

**KV events config explained:**

| Field | Value | Purpose |
|---|---|---|
| `enable_kv_cache_events` | `true` | Enables KV block storage/eviction event publishing |
| `publisher` | `"zmq"` | Uses ZeroMQ PUB socket for event delivery |
| `endpoint` | `tcp://gaie-pd-epp...:5557` | EPP service address — vLLM PUB connects here |
| `topic` | `kv@$(POD_IP):8000@model` | Topic prefix for ZMQ filtering. Format: `kv@<pod-ip>:<port>@<model-name>` |

The `$(POD_IP)` is a Kubernetes env var substitution — resolved at container start time from the downward API.

---

## How it works end-to-end

```
1. vLLM pod processes a request
   → KV cache blocks are stored in GPU memory (PagedAttention)
   → vLLM publishes BlockStored event via ZMQ PUB to EPP:5557
   → Topic: kv@10.42.0.98:8000@Qwen/Qwen2.5-7B-Instruct
   → Payload: block hash, pod identifier, storage medium

2. EPP receives the event
   → ZMQ SUB bound on tcp://*:5557, subscribed to "kv@"
   → Event processing pool (4 workers) ingests the event
   → Updates the KV-Block Index: "block hash X is on pod 10.42.0.98"

3. New request arrives at EPP
   → tokenizer plugin tokenizes the prompt into block-aligned chunks (block_size=64)
   → precise-prefix-cache-scorer queries the KV-Block Index:
     "Which pods have blocks matching this prompt's prefix?"
   → Returns scores: pod 89bgk has 2 matching blocks (score=1), pod ztkbs has 0 (score=0)
   → Combined with kv-cache-utilization (score=1 each) and queue (score=1 each)
   → Weighted total: 89bgk = 3×1 + 2×1 + 2×1 = 7, ztkbs = 3×0 + 2×1 + 2×1 = 4
   → max-score-picker selects 89bgk

4. Request routed to pod 89bgk
   → vLLM finds matching blocks in its local prefix cache → HIT
   → Skips KV computation for cached prefix → lower TTFT
```

---

## Critical configuration: block_size MUST match

| Component | Field | Value | Must match? |
|---|---|---|---|
| vLLM | `--block-size` | 64 | ✅ YES |
| EPP | `tokenProcessorConfig.blockSize` | 64 | ✅ YES |

**If these don't match, the EPP hashes prompts into different block boundaries than vLLM reports. Every index lookup misses, producing `"Got endpoint scores": {}` (empty). This was the root cause of our initial failure — we had vLLM at 128 and EPP at 64.**

The official llm-d precise prefix guide uses `block_size=64` everywhere.

---

## Issue encountered and resolved

### Issue: EPP index always empty (`"Got endpoint scores": null`)

**Symptom:** After 30+ requests, the precise-prefix-cache-scorer returned `score=0` for all endpoints. `"Got endpoint scores": null` then `{}`.

**Investigation steps:**
1. Verified TCP connectivity vLLM → EPP:5557 ✅
2. Verified EPP ZMQ subscriber bound on `tcp://*:5557` ✅
3. Verified vLLM ZMQ publisher thread started ✅
4. Verified topic format matches topicFilter ✅
5. Tested with `discoverPods: true` and `false` — no difference
6. Tested with and without `--kv-events-config` — prefix caching works without it (72% hit rate), so vLLM is functioning
7. **Discovered:** vLLM `--block-size=128` vs EPP `blockSize: 64` — mismatch

**Root cause:** Block size mismatch. vLLM publishes KV events with block indices computed at 128-token boundaries. The EPP tokenizer hashes incoming prompts at 64-token boundaries. Block hashes never match → every lookup returns empty.

**Fix:** Aligned both to `block_size=64` (the official guide default). After alignment, the first request populated the index and subsequent requests scored correctly.

### Issue: Prompts shorter than block_size produce 0% hit rate

**Symptom:** Short system prompts (~35 tokens) gave 0% prefix cache hit rate even on the same pod.

**Root cause:** vLLM's prefix caching operates at the block level. With `block_size=64`, a prompt must be at least 64 tokens long for a complete block to form. Prompts shorter than one block produce zero cached blocks and zero hits.

**Fix:** Use prompts longer than `block_size`. In testing, a ~230 token system prompt spans 3-4 blocks and achieves 71% hit rate.

---

## Proof from EPP logs

### Before fix (block_size mismatch)
```json
{"msg": "Got endpoint scores", "scores": null}
{"plugin": "precise-prefix-cache-scorer", "endpoint": "89bgk", "score": 0}
{"plugin": "precise-prefix-cache-scorer", "endpoint": "ztkbs", "score": 0}
```

### After fix (block_size aligned to 64)
```json
{"msg": "Got endpoint scores", "scores": {"10.42.0.98:8000": 2}}
{"plugin": "precise-prefix-cache-scorer", "endpoint": "89bgk", "score": 1}
{"plugin": "precise-prefix-cache-scorer", "endpoint": "ztkbs", "score": 0}
```

The scorer sees 2 cached blocks on pod 89bgk (`10.42.0.98`) and zero on ztkbs. The EPP routes the request to 89bgk where the KV blocks are reused.

### Multi-signal scoring (all 3 scorers)
```
Pod 89bgk: precise=1 × 3 + kv-util=1 × 2 + queue=1 × 2 = 7  ← PICKED
Pod ztkbs: precise=0 × 3 + kv-util=1 × 2 + queue=1 × 2 = 4
```

### vLLM prefix cache metrics
```
Pod 89bgk: hits=1152 queries=1620 → 71.1% hit rate  (receives all same-prefix traffic)
Pod ztkbs: hits=0    queries=0    → 0%                (no traffic for this prefix)
```

---

## Tokenizer sidecar

The precise scorer requires a tokenizer to convert incoming prompts into token sequences, then hash them into block-aligned keys for index lookup.

```
EPP pod (2/2 containers):
  1. epp (llm-d-inference-scheduler:v0.7.1) — scheduler + ZMQ subscriber
  2. tokenizer-uds (llm-d-uds-tokenizer:v0.7.1) — gRPC tokenizer over Unix Domain Socket

Startup log:
  "Successfully initialized tokenizer for model: Qwen/Qwen2.5-7B-Instruct"
```

The tokenizer downloads and caches the model's tokenizer from Hugging Face (requires `HF_TOKEN` env var). Communication is via UDS socket at `/tmp/tokenizer/tokenizer-uds.socket`.

---

## ZMQ event pipeline

```
vLLM pod                           EPP pod
┌────────────┐                     ┌────────────────────┐
│ Engine Core │                     │ ZMQ SUB            │
│     ↓       │                     │ tcp://*:5557       │
│ KV Cache    │  ZMQ PUB            │     ↓              │
│ BlockStored │ ──────────────────→ │ kvevents.Pool      │
│             │  topic: kv@ip:port  │ (4 workers)        │
│             │  payload: msgpack   │     ↓              │
└────────────┘                     │ KV-Block Index     │
                                    │     ↓              │
                                    │ precise-prefix-    │
                                    │ cache-scorer       │
                                    │ queries index      │
                                    └────────────────────┘
```

- **vLLM PUB CONNECTS** to EPP's ZMQ endpoint (client → server)
- **EPP SUB BINDS** on `tcp://*:5557` (server)
- Topic: `kv@<pod-ip>:<port>@<model-name>` — filtered by EPP's `topicFilter: "kv@"`
- Events are processed by a sharded pool with configurable concurrency (default 4 workers)
