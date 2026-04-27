# k3s GPU setup for llm-d (MIG and time-slicing)

Reproducible steps to get k3s running on a single GPU node with one of two GPU partitioning strategies:

- **Path A — MIG:** hardware-isolated partitions, dedicated memory + SMs per instance
- **Path B — Time-slicing:** the same physical GPU exposed as N virtual replicas, shared memory and SMs

The shared sections (k3s install, container runtime, common prerequisites) are identical for both paths — pick a partitioning path at Step 4.

---

## Choosing between MIG and time-slicing

| Property | MIG | Time-slicing |
|---|---|---|
| Memory isolation | Hardware-partitioned | Shared (no isolation) |
| SM isolation | Dedicated SMs per instance | Shared (time-multiplexed) |
| CUDA IPC across pods | Blocked between instances | Works (same device) |
| NIXL compatibility | Backend fails | UCX backend works |
| `nvidia.com/gpu` count in k8s | Number of MIG instances | Number of time-slicing replicas |
| Best for | Aggregated, multi-tenant (isolation matters) | P/D disaggregation, dev / PoC, anything needing NIXL |

**Pick MIG** when memory and SM isolation matter, you have multi-tenant pods, and you don't need cross-pod CUDA IPC.

**Pick time-slicing** when you need NIXL on a single GPU (P/D disaggregation), or when you want to oversubscribe a GPU for development without strict isolation.

---

## Shared prerequisites

- Linux VM with a Hopper- or Ampere-class GPU (MIG path requires a MIG-capable GPU)
- SSH access as a sudo-capable user
- Docker may be pre-installed by the cloud image — not used directly, but its containerd config can conflict

---

## Step 1: Remove conflicting CNI configs

Many cloud Ubuntu images pre-install Docker and Podman. Podman's CNI config uses a `tuning` plugin that is not bundled with k3s and breaks pod networking.

```bash
sudo mv /etc/cni/net.d/87-podman-bridge.conflist /tmp/
```

---

## Step 2: Install k3s

Standard single-server install. We disable Traefik (we use a Gateway API implementation instead) and klipper-lb (not needed for NodePort access).

```bash
curl -sfL https://get.k3s.io | sudo sh -s - server \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  --disable=servicelb
```

Verify:
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
sudo kubectl get nodes    # should show Ready within 10s
sudo kubectl get pods -A  # coredns, metrics-server, local-path-provisioner Running within 30s
```

---

## Step 3: Configure NVIDIA container runtime for k3s

k3s uses its own embedded containerd, separate from Docker's. The NVIDIA container runtime must be registered there.

> Do NOT pre-create `config.toml.tmpl` before k3s starts — it replaces the entire config. Instead, copy the generated config and patch it.

```bash
# Copy the working generated config as the template
sudo cp /var/lib/rancher/k3s/agent/etc/containerd/config.toml \
        /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl

# Use nvidia-ctk to add the nvidia runtime to the template
sudo nvidia-ctk runtime configure --runtime=containerd \
  --config=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl

# Fix cgroup driver: nvidia-ctk writes SystemdCgroup=true (detects systemd)
# but k3s uses cgroupfs driver. Mismatch causes OCI runtime errors.
sudo sed -i '/nvidia-container-runtime/,+1 s/SystemdCgroup = true/SystemdCgroup = false/' \
  /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl

# Apply by restarting k3s
sudo systemctl restart k3s
```

---

# Path A — MIG partitioning

MIG physically partitions the GPU into isolated instances with dedicated memory and SMs.

## A1. Enable MIG mode

```bash
# Enable MIG mode (requires no active GPU processes)
sudo nvidia-smi -i 0 -mig 1

# GPU reset to apply the mode change
sudo nvidia-smi -i 0 -r

# Verify
nvidia-smi --query-gpu=mig.mode.current --format=csv
# Should show: Enabled
```

## A2. Create GPU and Compute Instances

For aggregated 2-pod or P/D 1+1 layouts, create 2× `3g.48gb` (profile ID 9):

```bash
# Create two GPU Instances
sudo nvidia-smi mig -cgi 9,9

# Create Compute Instances inside each GI
sudo nvidia-smi mig -cci
```

Verify:
```bash
sudo nvidia-smi mig -lgi
# GPU instances:
#   0  MIG 3g.48gb  ID 1  Placement 0:4
#   0  MIG 3g.48gb  ID 2  Placement 4:4

nvidia-smi
# MIG devices:
#   0    1   0   0  |  48MiB / 47616MiB  | 60 SMs
#   0    2   0   1  |  48MiB / 47616MiB  | 60 SMs
```

### MIG profile reference (Hopper, 96 GB)

| Profile | Instances | Memory | SMs | Use case |
|---|---|---|---|---|
| `7g.96gb` (ID 0) | 1 | 93 GB | 132 | Full GPU, no partition |
| `3g.48gb` (ID 9) | **2** | **46.5 GB** | **60** | **2-pod aggregated, P/D 1+1** |
| `2g.24gb` (ID 14) | 3 | 23 GB | 32 | Multi-tenant small models |
| `1g.12gb` (ID 19) | 7 | 11 GB | 16 | Maximum isolation |

## A3. Install NVIDIA device plugin with MIG strategy

With `migStrategy=single` (all instances are the same profile), each MIG instance is registered as one `nvidia.com/gpu`.

```bash
# Label node so the device plugin's nodeAffinity matches
sudo kubectl label node $(hostname) nvidia.com/gpu.present=true

# Install via helm
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm install nvdp nvdp/nvidia-device-plugin -n kube-system \
  --set migStrategy=single \
  --set mps.enabled=false \
  --set runtimeClassName=nvidia
```

**Key flags:**
- `migStrategy=single` — all MIG instances are the same profile, exposed as `nvidia.com/gpu`
- `mps.enabled=false` — MPS (Multi-Process Service) not needed; would require additional node labels
- `runtimeClassName=nvidia` — the device plugin pod itself must run with the nvidia runtime to detect GPUs

Verify:
```bash
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
# Expected: 2
```

---

# Path B — GPU time-slicing

Time-slicing exposes a single physical GPU as N virtual `nvidia.com/gpu` replicas. All replicas share memory and SMs but, crucially, can use **CUDA IPC across pods** — required for NIXL KV cache transfer in llm-d P/D mode.

## B1. (If switching from MIG) Disable MIG and tear down instances

If MIG mode is currently enabled, disable it before applying the time-slicing config. Otherwise skip to B2.

```bash
# Tear down compute instances and GPU instances
sudo nvidia-smi mig -dci
sudo nvidia-smi mig -dgi

# Disable MIG mode
sudo nvidia-smi -i 0 -mig 0

# Reset GPU to apply
sudo nvidia-smi -i 0 -r

# Verify
nvidia-smi --query-gpu=mig.mode.current --format=csv
# Should show: Disabled
```

## B2. Apply the time-slicing ConfigMap

This ConfigMap tells the NVIDIA device plugin to expose the GPU as N replicas. Adjust `replicas:` to match the number of pods you want to share the GPU.

```yaml
# time-slicing-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: kube-system
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        resources:
          - name: nvidia.com/gpu
            replicas: 4    # exposes the GPU as 4× nvidia.com/gpu
```

Apply it:
```bash
sudo kubectl apply -f time-slicing-config.yaml
```

> Choose `replicas` based on memory math: with `--gpu-memory-utilization=0.40` per pod, 2 replicas fit comfortably on a 96 GB GPU; with `0.20` per pod, 4 replicas fit. There is no hardware enforcement — pods will OOM the GPU if the sum exceeds total memory.

## B3. Install (or reinstall) the NVIDIA device plugin in time-slicing mode

If the device plugin from Path A is already installed, uninstall it first so the new config takes effect cleanly:

```bash
helm uninstall nvdp -n kube-system
```

Install with the time-slicing ConfigMap referenced:

```bash
sudo kubectl label node $(hostname) nvidia.com/gpu.present=true --overwrite

helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm install nvdp nvdp/nvidia-device-plugin -n kube-system \
  --set migStrategy=none \
  --set mps.enabled=false \
  --set runtimeClassName=nvidia \
  --set config.name=time-slicing-config
```

**Key differences from Path A:**
- `migStrategy=none` (not `single`) — MIG is not in use
- `config.name=time-slicing-config` — points the plugin at the ConfigMap from B2

## B4. Verify GPU shows up as N replicas

```bash
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
# Expected: matches `replicas:` from the ConfigMap (e.g. 4)
```

## Pod-level requirements for time-slicing + NIXL

If you intend to run llm-d P/D disaggregation (NIXL KV cache transfer) on top of time-slicing, every pod that participates needs:

```yaml
spec:
  hostIPC: true              # CUDA IPC requires shared /dev/shm
  runtimeClassName: nvidia
  containers:
    - name: vllm
      env:
        - name: UCX_TLS
          value: "tcp,sm,cuda_copy,cuda_ipc"   # tcp is required for the UCX control channel
        - name: UCX_MEMTYPE_CACHE
          value: "n"
      args:
        - "--gpu-memory-utilization=0.40"      # tune to fit (replicas × utilization ≤ 1.0)
```

See `pd-timeslicing-breakthrough.md` for the rationale behind each setting.

---

## End state (either path)

```
$ sudo kubectl get nodes -o wide
NAME             STATUS   ROLES           VERSION        CONTAINER-RUNTIME
192-222-50-112   Ready    control-plane   v1.34.6+k3s1   containerd://2.2.2

$ sudo kubectl get pods -A
NAMESPACE     NAME                                      READY   STATUS
kube-system   coredns-76c974cb66-4d94s                  1/1     Running
kube-system   local-path-provisioner-8686667995-p8k59   1/1     Running
kube-system   metrics-server-c8774f4f4-ncbp2            1/1     Running
kube-system   nvdp-nvidia-device-plugin-b8jhx           1/1     Running

$ kubectl get nodes -o json | jq '.items[0].status.allocatable["nvidia.com/gpu"]'
# Path A: "2"  (two MIG instances)
# Path B: "4"  (four time-slicing replicas — or whatever the ConfigMap says)
```

Ready for llm-d Helm releases.
