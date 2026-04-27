# V2: Multi-model routing test results

Demonstrates the EPP routing requests to the correct vLLM pod based on model name, with two different models on separate MIG instances.

---

## Setup

| Pod | Model | MIG instance | Parameters |
|---|---|---|---|
| `t4wks` | **Qwen2.5-7B-Instruct** (14GB FP16) | MIG Dev 0, 46.5GB | BF16, V1 engine, FA3 |
| `b7p8s` | **Qwen2.5-0.5B-Instruct** (1GB FP16) | MIG Dev 1, 46.5GB | BF16, V1 engine, FA3 |

Both pods share the same InferencePool (selector: `llm-d.ai/inference-serving: true`). The EPP differentiates by the `llm-d.ai/model` label on each pod.

---

## How multi-model routing works in llm-d

1. Each vLLM pod is labelled with `llm-d.ai/model: <model-name>` 
2. vLLM's `--served-model-name` flag declares which model it serves
3. The EPP's InferencePool discovers ALL serving pods
4. When a request arrives with `"model": "Qwen/Qwen2.5-0.5B-Instruct"`, the EPP:
   - Identifies candidate pods from the InferencePool
   - Filters to pods whose model label matches the requested model
   - Scores remaining candidates with prefix-cache-scorer + queue-scorer
   - Routes to the highest-scored match

---

## Test results

### Correct model routing

```bash
# 7B request
curl ... -d '{"model":"Qwen/Qwen2.5-7B-Instruct",...}'
→ "Hello! Nice to meet you."  (model: Qwen/Qwen2.5-7B-Instruct)

# 0.5B request
curl ... -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct",...}'  
→ "Hello! How can I assist you today?"  (model: Qwen/Qwen2.5-0.5B-Instruct)

# Non-existent model
curl ... -d '{"model":"NonExistentModel",...}'
→ {"error": {"message": "The model `NonExistentModel` does not exist.", "code": 404}}
```

### EPP routing logs (proof of model-based routing)

```json
{"msg":"EPP sent request body response(s) to proxy",
 "x-request-id":"3e71a8ba","modelName":"Qwen/Qwen2.5-7B-Instruct","targetModelName":"Qwen/Qwen2.5-7B-Instruct"}

{"msg":"EPP sent request body response(s) to proxy",
 "x-request-id":"3d86a643","modelName":"Qwen/Qwen2.5-0.5B-Instruct","targetModelName":"Qwen/Qwen2.5-0.5B-Instruct"}
```

### Direct pod verification

```bash
# 0.5B pod /v1/models
{"data": [{"id": "Qwen/Qwen2.5-0.5B-Instruct", "object": "model", "max_model_len": 4096}]}

# 7B pod /v1/models  
{"data": [{"id": "Qwen/Qwen2.5-7B-Instruct", "object": "model", "max_model_len": 8192}]}
```

---

## Issue encountered: stale EPP routing cache

After deploying the 0.5B pod, the EPP initially routed ALL requests to the pre-existing 7B pod (even 0.5B model requests), causing 404 errors. The EPP had a cached routing state from when only the 7B model was deployed.

**Fix:** Restart the EPP deployment to clear stale routing:
```bash
kubectl rollout restart deploy gaie-pd-epp -n llm-d-pd
```

After restart, the EPP correctly discovered both pods and routed by model name.

**Note for production:** When adding new model pods to an existing InferencePool, the EPP may need time to reconcile. If routing fails immediately after adding a new pod, a restart clears the issue. Alternatively, the EPP's reconciliation interval (default 10s for metric scraping) should eventually pick up new pods without restart — the issue here was likely a timing race where requests arrived before the EPP's first scrape of the new pod.

---

## Architecture for multi-model

```
Client → Gateway → HTTPRoute → InferencePool (selects all serving pods)
                                    ↓
                               EPP scheduler
                          model name matching + scoring
                                    ↓
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
          Pod: Qwen2.5-7B             Pod: Qwen2.5-0.5B
          (MIG Dev 0, 46.5GB)         (MIG Dev 1, 46.5GB)
          llm-d.ai/model:             llm-d.ai/model:
          Qwen2.5-7B-Instruct         Qwen2.5-0.5B-Instruct
```

A single InferencePool + EPP handles routing to multiple models. For larger deployments with many models, separate InferencePools per model family give stronger isolation.
