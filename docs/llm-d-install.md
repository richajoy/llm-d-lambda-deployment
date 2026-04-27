# llm-d P/D disaggregated deployment

Step-by-step deployment of the three llm-d Helm releases in prefill/decode disaggregation mode, using MIG-partitioned GPU instances.

---

## What gets deployed

Three Helm releases — the standard llm-d deployment pattern:

| # | Release | Chart | What it creates |
|---|---|---|---|
| 1 | `infra-pd` | `llm-d-infra` v1.4.0 | Gateway, AgentgatewayParameters |
| 2 | `gaie-pd` | `inferencepool` v1.4.0 | InferencePool, EPP Deployment + Service |
| 3 | `ms-pd` | `llm-d-modelservice` v0.4.9 | Prefill Deployment, Decode Deployment (+ routing sidecar), Service |

Plus a manually applied `HTTPRoute` that routes to the InferencePool.

### P/D-specific components (not present in aggregated mode)

1. **Routing sidecar** (`ghcr.io/llm-d/llm-d-routing-sidecar:v0.7.1`) — runs as an init container (with `restartPolicy: Always`, making it a sidecar) in the decode pod. Proxies requests on port 8000, forwarding to vLLM on port 8200. Handles NIXL KV cache transfer coordination via the `nixlv2` connector.

2. **NIXL connector in vLLM** — enabled via `--kv-transfer-config '{"kv_connector":"NixlConnector", "kv_role":"kv_both"}'`. Both prefill and decode pods run with `kv_role: kv_both` (can send and receive KV cache). Port 5600 is the NIXL data transfer port.

3. **EPP scheduler P/D plugins** — the GAIE values file configures these plugins:
   - `prefill-header-handler` — inspects/adds headers for P/D routing
   - `prefix-cache-scorer` — scores endpoints by prefix cache affinity (weight: 2)
   - `queue-scorer` — scores by queue depth (weight: 1)
   - `prefill-filter` / `decode-filter` — restrict candidate set to the correct role
   - `max-score-picker` — picks the highest-scored endpoint
   - `prefix-based-pd-decider` — decides whether to split into P/D or send directly to decode
   - `pd-profile-handler` — orchestrates the P/D flow using two scheduling profiles

### How the EPP P/D routing works

```
Request arrives at EPP
  │
  ▼
pd-profile-handler: should this request be split into P/D?
  ├── YES (long prompt, >16 non-cached tokens):
  │     1. Run "prefill" profile:
  │        prefill-filter → prefix-cache-scorer(2) + queue-scorer(1) → max-score-picker
  │        → route to best prefill pod
  │     2. Prefill pod computes KV cache, transfers via NIXL to decode pod
  │     3. Run "decode" profile:
  │        decode-filter → prefix-cache-scorer(2) + queue-scorer(1) �� max-score-picker
  │        → route to best decode pod
  │     4. Decode pod generates tokens using transferred KV cache
  │
  └── NO (short prompt, mostly cached):
        Run "decode" profile directly → skip prefill, save transfer overhead
```

The `prefix-based-pd-decider` uses `nonCachedTokens: 16` as threshold — if fewer than 16 tokens are uncached, it skips prefill entirely (the decode pod can handle the small prefill locally).

---

## Prerequisites completed before this step

- [x] k3s cluster running with `nvidia.com/gpu: 2` (MIG)
- [x] Gateway API CRDs v1.5.1 installed
- [x] GAIE CRDs v1.4.0 installed
- [x] agentgateway deployed (`GatewayClass: agentgateway, Accepted: True`)
- [x] Namespace `llm-d-pd` created
- [x] HF token secret `llm-d-hf-token` created

---

## Installation

### 1. Clone the llm-d repo

```bash
git clone https://github.com/llm-d/llm-d.git /tmp/llm-d
cd /tmp/llm-d/guides/pd-disaggregation
```

### 2. Create the MIG values file

Copy [`helm/values_gh200_pd.yaml`](../helm/values_gh200_pd.yaml) into the ms-pd directory:

```bash
cp <this-repo>/helm/values_gh200_pd.yaml ms-pd/values_gh200.yaml
```

Key differences from the upstream `values.yaml` (which targets 120B on 8×H200):

| Setting | Upstream | This deployment (MIG, single-GPU) |
|---|---|---|
| Model | openai/gpt-oss-120b | Qwen/Qwen2.5-7B-Instruct |
| Model size | 250Gi | 30Gi |
| Prefill TP | 1 (with 4 replicas) | 1 (with 1 replica) |
| Decode TP | 4 (with 1 replica) | 1 (with 1 replica) |
| RDMA | `rdma/ib: 1` | Removed (MIG instances on same GPU) |
| runtimeClassName | (default) | `nvidia` (required for k3s GPU access) |
| Memory requests | 64Gi | 32Gi request, 64Gi limit |
| max-model-len | 32000 | 8192 |
| gpu-memory-utilization | (default 0.90) | 0.90 |
| ServiceMonitor | enabled | disabled (no Prometheus Operator) |

### 3. Patch the helmfile to use our values

```bash
sed -i 's|ms-pd/values.yaml|ms-pd/values_gh200.yaml|' helmfile.yaml.gotmpl
```

### 4. Disable ServiceMonitor in GAIE values

Without Prometheus Operator, the `ServiceMonitor` CRD doesn't exist and the chart fails:

```bash
sed -i 's/enabled: true/enabled: false/' gaie-pd/values.yaml
```

### 5. Install the HTTPRoute

```bash
kubectl apply -f httproute.yaml -n llm-d-pd
```

### 6. Deploy via helmfile

```bash
helmfile apply -e agentgateway -n llm-d-pd
```

This installs all three releases in dependency order:
1. `infra-pd` (Gateway infrastructure)
2. `gaie-pd` (InferencePool + EPP scheduler)
3. `ms-pd` (vLLM prefill + decode Deployments)

---

## What happens after deployment

### Image pulls (~5-10 minutes)
The `ghcr.io/llm-d/llm-d-cuda:v0.6.0` image is ~5-10 GB (ARM64 variant). First pull takes time.

### Model download (~3-5 minutes)
Qwen2.5-7B-Instruct weights (~14 GB FP16) download from Hugging Face into the EmptyDir volume.

### vLLM startup (~2-3 minutes)
- Initializes CUDA context on the MIG instance
- Loads model weights into GPU memory
- Captures CUDA graphs (if not using `--enforce-eager`)
- Initializes NIXL connector (registers with the routing sidecar)
- Starts serving on port 8000 (prefill) or 8200 (decode, behind sidecar on 8000)

### EPP discovers pods
Once vLLM pods pass readiness probes (`/v1/models`), the EPP:
1. Reconciles the InferencePool
2. Starts metric refreshers for each pod (scrapes `/metrics` every 10s)
3. Begins routing requests through the P/D pipeline

---

## Verify

```bash
# Three Helm releases
helm list -n llm-d-pd

# All pods running
kubectl get pods -n llm-d-pd

# HTTPRoute points at InferencePool
kubectl get httproute -n llm-d-pd -o yaml | grep -A4 backendRefs

# EPP is watching pods
kubectl logs -n llm-d-pd deploy/gaie-pd-epp --tail=20 | grep -E "Reconciling|Starting refresher|Pod being"

# Gateway is programmed
kubectl get gateway -n llm-d-pd
```

---

## Architecture (as deployed)

```
Client → agentgateway (port 80, LoadBalancer / NodePort)
       ↓
       HTTPRoute  backendRef: InferencePool/gaie-pd
       ↓
       EPP (gaie-pd-epp)
         pd-profile-handler → decides P/D split
       ↓
       ┌──────────────────────────────────────┐
       │ Prefill pod (MIG Dev 0, 46.5GB)      │
       │ vllm serve Qwen/Qwen2.5-7B-Instruct │
       │ --kv-transfer-config NixlConnector    │
       │ Port 8000 (vLLM API)                 │
       │ Port 5600 (NIXL transfer)            │
       └────────────────┬─────────────────────┘
                        │ NIXL KV transfer (TCP via host memory)
       ┌────────────────▼─────────────────────┐
       │ Decode pod (MIG Dev 1, 46.5GB)        │
       │ routing-sidecar :8000 → vllm :8200   │
       │ vllm serve Qwen/Qwen2.5-7B-Instruct │
       │ --kv-transfer-config NixlConnector    │
       │ Port 8200 (vLLM API, behind sidecar) │
       │ Port 5600 (NIXL transfer)            │
       └───────���──────────────────────────────┘
```
