# P/D disaggregation via GPU time-slicing — a novel finding

This document describes a **novel approach** to running llm-d's prefill/decode disaggregation on a **single physical GPU** using NVIDIA time-slicing instead of MIG. This combination is not documented in the llm-d guides, which target multi-node deployments with InfiniBand.

---

## Background: why MIG failed for P/D

The initial approach used MIG (Multi-Instance GPU) to partition a single GH200 into two isolated instances — one for prefill, one for decode. NIXL was configured to transfer KV cache between them.

**Result: NIXL failed on MIG.**

Root cause: MIG creates hardware-isolated GPU partitions. NVIDIA's MIG documentation explicitly states: *"CUDA IPC across GPU instances is not supported."* NIXL relies on CUDA IPC (or RDMA) for KV cache transfer. Without either, the NIXL backend initialization crashes:

```
nixl_cu12._bindings.nixlBackendError: NIXL_ERR_BACKEND
```

Even with `UCX_TLS=tcp`, the TCP transport initialized but the engine core subprocess died during NIXL connector setup — the combination of MIG isolation + containerized processes breaks assumptions in NIXL's transport stack.

---

## The time-slicing approach

**Key insight:** GPU time-slicing does NOT create hardware isolation. Both pods see the same physical GPU (`/dev/nvidia0`), the same memory space, and can use CUDA IPC between them.

### How time-slicing differs from MIG

| Property | MIG | Time-slicing |
|---|---|---|
| Memory isolation | ✅ Hardware-partitioned | ❌ **Shared** (no isolation) |
| SM isolation | ✅ Dedicated SMs per instance | ❌ **Shared** (time-multiplexed) |
| CUDA IPC | ❌ **Blocked** between instances | ✅ **Works** (same device) |
| `nvidia.com/gpu` in k8s | N (real partitions) | N (virtual replicas) |
| NIXL compatibility | ❌ Backend fails | ✅ **UCX backend works** |

### Configuration that made it work

Three critical settings:

**1. GPU time-slicing (device plugin ConfigMap)**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        resources:
        - name: nvidia.com/gpu
          replicas: 2
```

**2. Pod security: `hostIPC: true`**
```yaml
spec:
  hostIPC: true
  runtimeClassName: nvidia
```

CUDA IPC requires shared `/dev/shm`. Without `hostIPC: true`, each pod gets an isolated `/dev/shm` and `cudaIpcGetMemHandle`/`cudaIpcOpenMemHandle` fails silently.

**3. UCX transport: TCP + CUDA IPC**
```yaml
env:
  - name: UCX_TLS
    value: "tcp,sm,cuda_copy,cuda_ipc"
  - name: UCX_MEMTYPE_CACHE
    value: "n"
```

The `tcp` transport is required for UCX's **active messaging** protocol (handshakes, control messages). Without it, UCX reports `"no active messages transport"` even when `cuda_ipc` is available — `cuda_ipc` only handles bulk data transfers, not the control channel.

**4. Memory limit per pod**
```yaml
args:
  - "--gpu-memory-utilization=0.40"
```

With time-slicing there's no memory isolation. Both pods see 96GB total via `torch.cuda.mem_get_info()`. Without limiting each pod, the first allocates 86GB (0.90 × 96) and the second OOMs. At 0.40, each gets ~38GB — plenty for Qwen 7B (14GB weights + 24GB KV cache).

---

## What the logs prove

### NIXL backend initialization (SUCCEEDED)

```
NIXL version: 1.0.0 (git: 4071a532)
Discovered and loaded backend plugin: UCX
Discovered and loaded backend plugin: GDS_MT
Discovered and loaded backend plugin: POSIX
Discovered and loaded backend plugin: GDS
Backend UCX was instantiated
Initialized NIXL agent: f8be3210-bc83-41eb-b981-50bc71b02cb7
NIXL is available
```

Compare with MIG failure:
```
nixl_cu12._bindings.nixlBackendError: NIXL_ERR_BACKEND
```

### NIXL compatibility check (PASSED)

```
NIXL compatibility check passed (hash: ef506bc06b5c0f31a2f3282f3df3ce84f191f4e21a334762d41428c671823246)
```

This means the decode pod connected to the prefill pod's NIXL agent and verified model/cache compatibility — the KV transfer channel is established.

### Inference response

```json
{
  "model": "Qwen/Qwen2.5-7B-Instruct",
  "choices": [{
    "message": {
      "content": "Prefill/decode disaggregation in LLM inference refers to the practice of separating the initial token generation (prefill) from the subsequent decoding process, allowing for more efficient and flexible model inference."
    },
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 45, "completion_tokens": 40, "total_tokens": 85}
}
```

4 consecutive requests succeeded through the full P/D pipeline.

---

## Deployed state

```
PODS:
gaie-pd-epp-*                        1/1   Running   ← EPP scheduler (P/D plugins)
infra-pd-inference-gateway-*         1/1   Running   ← agentgateway
ms-pd-llm-d-modelservice-decode-*    2/2   Running   ← vLLM decode + routing sidecar (NIXL)
ms-pd-llm-d-modelservice-prefill-*   1/1   Running   ← vLLM prefill

GPU: NVIDIA GH200 480GB, MIG Disabled, 81GB/97GB used (both pods loaded)
nvidia.com/gpu: 2 (time-sliced replicas)

hostIPC: true on both pods
runtimeClassName: nvidia on both pods
UCX_TLS: tcp,sm,cuda_copy,cuda_ipc
```

---

## Failure path that led to this discovery

| Attempt | GPU sharing | NIXL result | Root cause |
|---|---|---|---|
| MIG 2×3g.48gb | Hardware isolation | ❌ `NIXL_ERR_BACKEND` | CUDA IPC blocked by MIG |
| MIG + `UCX_TLS=tcp` | Hardware isolation | ❌ Engine core crash | MIG blocks transport even with TCP fallback |
| Time-slicing + `UCX_TLS=sm,cuda_copy,cuda_ipc` | No isolation | ❌ `no active messages transport` | Missing TCP for UCX control channel |
| **Time-slicing + `UCX_TLS=tcp,sm,cuda_copy,cuda_ipc` + `hostIPC=true`** | No isolation | ✅ **WORKS** | Full transport stack available |

---

## Caveats and limitations

1. **No memory isolation** — a bug in one pod can corrupt the other pod's GPU memory. Time-slicing is cooperative, not enforced.
2. **Performance on same GPU** — P/D disaggregation's primary benefit is specializing different GPUs for compute-bound (prefill) vs memory-bound (decode) workloads. On the same GPU, the benefit is limited to batch scheduling flexibility, not hardware specialization.
3. **`hostIPC: true` is a security consideration** — it exposes the host's shared memory namespace. In multi-tenant clusters, this is a concern. For dedicated inference nodes, it's acceptable.
4. **KV transfer speed** — on the same GPU, NIXL's `cuda_ipc` transfer is effectively a device-to-device memcpy within the same GPU memory space. This is much faster than cross-node RDMA but doesn't exercise the full NIXL stack that multi-node P/D relies on.

---

## Open gaps in upstream documentation and charts

1. **Time-slicing as a P/D path is undocumented** — the llm-d P/D guide only covers multi-node with InfiniBand, but single-GPU time-slicing is a valid dev / PoC path.
2. **UCX_TLS guidance is missing** — the error `"no active messages transport"` is confusing in isolation; `tcp` is required alongside `cuda_ipc` for the control channel.
3. **MIG incompatibility is not called out** — the P/D guide should explicitly state that MIG does not support NIXL due to CUDA IPC restrictions.
4. **`hostIPC: true` is not exposed by the chart** — the llm-d-modelservice chart should accept this as a values parameter.
5. **`runtimeClassName` is not templated** — the chart does not currently template this field, so it has to be patched in via `kubectl patch deploy` after install.
