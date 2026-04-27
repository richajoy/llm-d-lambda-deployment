# Precise prefix-cache-aware routing — findings and limitations

Attempt to configure precise prefix-cache-aware routing in P/D disaggregated mode on time-sliced GPU.

---

## What we tried

Upgraded the EPP from approximate `prefix-cache-scorer` to `precise-prefix-cache-scorer` with:
- Tokenizer sidecar (`llm-d-uds-tokenizer:v0.7.1`)
- KV events config on vLLM pods (`--kv-events-config` with ZMQ publisher to EPP port 5557)
- `kvEventsConfig.topicFilter: "kv@"` on the EPP
- Scoring weights: precise prefix (3) + KV util (2) + queue (2)

## What worked

- EPP v0.7.1 deployed with tokenizer sidecar (2/2 Running)
- Tokenizer initialized for `Qwen/Qwen2.5-7B-Instruct`
- `precise-prefix-cache-scorer` plugin loaded and scoring
- Short requests correctly identified as "no disaggregated PD" (below `nonCachedTokens: 16` threshold)
- Both P/D pods functional with NIXL KV transfer

## What didn't work

The `prefix-based-pd-decider` reports:
```
"unable to read prefix cache state"
```

KV events from vLLM pods are NOT reaching the EPP's precise prefix index. The precise scorer gives `score: 0` for all endpoints regardless of cache state.

## Root cause analysis

### Issue 1: KV events not publishing/receiving

The vLLM `--kv-events-config` uses `$(POD_IP)` for topic format, which requires Kubernetes env var substitution. The substitution may not be resolving correctly when the arg is a JSON string, leaving the literal `$(POD_IP)` in the topic.

Expected topic: `kv@10.42.0.65:8000@Qwen/Qwen2.5-7B-Instruct`
Actual topic: `kv@$(POD_IP):8000@Qwen/Qwen2.5-7B-Instruct` (unresolved)

### Issue 2: Combining P/D + precise is an untested integration

The llm-d guides keep P/D and precise prefix routing separate:
- **P/D disaggregation guide** → uses approximate `prefix-cache-scorer`
- **Precise prefix guide** → uses aggregated mode (no P/D, no NIXL)

Combining both requires the `prefix-based-pd-decider` to read from the `precise-prefix-cache-scorer`'s index, which triggers the "unable to read prefix cache state" error. This suggests the two plugins aren't fully wired to work together in v0.7.1.

## Approximate vs precise — when to use each

### Approximate mode (`prefix-cache-scorer`)
- **How it works:** Tracks routing history — "I sent this prefix to pod X before"
- **Infrastructure:** Zero overhead (no ZMQ, no tokenizer sidecar)
- **Best for:** Aggregated mode where routing destination = cache location
- **Limitation in P/D:** Doesn't account for NIXL transfers. After prefill→decode KV transfer, the index still records the prefill pod as the destination.
- **At scale:** Statistically effective across 100+ pods — even without exact cache state, routing history provides strong locality signals

### Precise mode (`precise-prefix-cache-scorer`)
- **How it works:** Real-time KV events from vLLM → EPP updates a live index of which blocks are on which pod
- **Infrastructure:** Requires tokenizer sidecar + ZMQ + KV events config on every vLLM pod
- **Best for:** Multi-pod aggregated deployments where exact cache affinity matters
- **In P/D (theoretical):** When decode receives KV via NIXL, it publishes `BlockStored` events → EPP knows decode has the cache → next request with same prefix bypasses prefill
- **Status:** Works for aggregated mode. Integration with P/D `prefix-based-pd-decider` needs further development.

## Clarifications after deeper review

An initial reading of the source suggested approximate mode "only records the prefill pod." Re-reading the plugin source confirmed this is partially wrong:
- The approximate plugin records routing destinations for **both** decode and prefill profiles.
- The real gap is that it does not reflect cache that arrived on a decode pod via a NIXL transfer from a different request's prefill phase.
- The `pd-profile-handler` runs the decode profile **first**, then passes the selected decode pod to the P/D decider for cache-state inspection.

## Recommendation for production

For P/D disaggregated deployments today:
1. Use **approximate mode** — it works, has zero infrastructure overhead, and for most workloads the P/D path is the correct default
2. The `selective PD` feature (`nonCachedTokens` threshold) should be tuned based on your prompt profile:
   - Short prompts (< threshold) → direct to decode (fast, cache-friendly)
   - Long prompts (> threshold) → P/D split (compute-efficient)
3. Precise mode is best suited for **aggregated multi-pod** deployments where maximizing prefix cache hits across N pods is the primary optimization target

## Open gaps in v0.7.1

- The combination of P/D + precise prefix routing is currently untested upstream and would benefit from explicit integration tests.
- The `prefix-based-pd-decider` does not read state from the `precise-prefix-cache-scorer` correctly — the "unable to read prefix cache state" error points to a missing interface between the two plugins.
- No reference helm values exist today for a combined P/D + precise deployment.
