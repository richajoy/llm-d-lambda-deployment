#!/usr/bin/env bash
# Test the llm-d aggregated deployment on Lambda GH200
# Run this ON the Lambda instance (not locally)
#
# Usage: ./test-aggregated.sh

set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NAMESPACE="${NAMESPACE:-llm-d-pd}"
MODEL="Qwen/Qwen2.5-7B-Instruct"
GATEWAY="http://localhost:31458"

echo "============================================"
echo "  llm-d Aggregated Deployment Test Suite"
echo "============================================"
echo ""

echo "=== 1. Cluster health ==="
sudo kubectl get pods -n ${NAMESPACE}
echo ""

echo "=== 2. Helm releases (should show 3) ==="
sudo KUBECONFIG=${KUBECONFIG} helm list -n ${NAMESPACE}
echo ""

echo "=== 3. Architectural signature: HTTPRoute → InferencePool ==="
sudo kubectl get httproute -n ${NAMESPACE} -o yaml | grep -A5 backendRefs
echo ""

echo "=== 4. EPP discovered pods (Starting refresher logs) ==="
sudo kubectl logs -n ${NAMESPACE} deploy/gaie-pd-epp --tail=50 | grep "Starting refresher" | tail -5
echo ""

echo "=== 5. MIG / GPU status ==="
nvidia-smi --query-gpu=index,name,memory.used,memory.total,mig.mode.current --format=csv
echo ""

echo "=== 6. Baseline prefix cache metrics ==="
for POD in $(sudo kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=decode -o name); do
  HITS=$(sudo kubectl exec -n ${NAMESPACE} ${POD} -c vllm -- curl -sS http://localhost:8000/metrics 2>/dev/null | grep "^vllm:prefix_cache_hits_total" | awk '{print $2}')
  QUERIES=$(sudo kubectl exec -n ${NAMESPACE} ${POD} -c vllm -- curl -sS http://localhost:8000/metrics 2>/dev/null | grep "^vllm:prefix_cache_queries_total" | awk '{print $2}')
  KV=$(sudo kubectl exec -n ${NAMESPACE} ${POD} -c vllm -- curl -sS http://localhost:8000/metrics 2>/dev/null | grep "^vllm:gpu_cache_usage_perc" | awk '{print $2}')
  echo "  ${POD}: hits=${HITS} queries=${QUERIES} kv_cache=${KV}"
done
echo ""

SYSTEM_PROMPT="You are an AI inference expert who understands PagedAttention, KV cache management, prefix caching, and GPU memory optimization in production LLM serving systems."

echo "=== 7. Request A — cold cache ==="
RESP_A=$(curl -sS --max-time 30 -X POST ${GATEWAY}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"system\",\"content\":\"${SYSTEM_PROMPT}\"},{\"role\":\"user\",\"content\":\"What is prefix caching?\"}],\"max_tokens\":60}")
echo "Response: $(echo ${RESP_A} | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"][:120])')"
echo "Tokens: $(echo ${RESP_A} | python3 -c 'import json,sys; print(json.load(sys.stdin)["usage"])')"
echo ""

echo "=== 8. Request B — warm cache (same system prompt) ==="
RESP_B=$(curl -sS --max-time 30 -X POST ${GATEWAY}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"system\",\"content\":\"${SYSTEM_PROMPT}\"},{\"role\":\"user\",\"content\":\"How does KV cache eviction work?\"}],\"max_tokens\":60}")
echo "Response: $(echo ${RESP_B} | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"][:120])')"
echo "Tokens: $(echo ${RESP_B} | python3 -c 'import json,sys; print(json.load(sys.stdin)["usage"])')"
echo ""

echo "=== 9. EPP routing proof ==="
sudo kubectl logs -n ${NAMESPACE} deploy/gaie-pd-epp --tail=20 | grep -E "EPP received|sent request body" | tail -6
echo ""

echo "=== 10. Updated prefix cache metrics ==="
for POD in $(sudo kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=decode -o name); do
  HITS=$(sudo kubectl exec -n ${NAMESPACE} ${POD} -c vllm -- curl -sS http://localhost:8000/metrics 2>/dev/null | grep "^vllm:prefix_cache_hits_total" | awk '{print $2}')
  QUERIES=$(sudo kubectl exec -n ${NAMESPACE} ${POD} -c vllm -- curl -sS http://localhost:8000/metrics 2>/dev/null | grep "^vllm:prefix_cache_queries_total" | awk '{print $2}')
  KV=$(sudo kubectl exec -n ${NAMESPACE} ${POD} -c vllm -- curl -sS http://localhost:8000/metrics 2>/dev/null | grep "^vllm:gpu_cache_usage_perc" | awk '{print $2}')
  RUNNING=$(sudo kubectl exec -n ${NAMESPACE} ${POD} -c vllm -- curl -sS http://localhost:8000/metrics 2>/dev/null | grep "^vllm:num_requests_running" | awk '{print $2}')
  WAITING=$(sudo kubectl exec -n ${NAMESPACE} ${POD} -c vllm -- curl -sS http://localhost:8000/metrics 2>/dev/null | grep "^vllm:num_requests_waiting" | awk '{print $2}')
  echo "  ${POD}:"
  echo "    prefix_cache: hits=${HITS} queries=${QUERIES}"
  echo "    kv_cache_usage: ${KV}"
  echo "    requests: running=${RUNNING} waiting=${WAITING}"
done
echo ""

echo "=== 11. KV cache utilization (what EPP scrapes for routing) ==="
for POD in $(sudo kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=decode -o name); do
  echo "  ${POD}:"
  sudo kubectl exec -n ${NAMESPACE} ${POD} -c vllm -- curl -sS http://localhost:8000/metrics 2>/dev/null \
    | grep -E "^vllm:(gpu_cache_usage_perc|kv_cache_usage_perc|num_requests|prefix_cache)" \
    | sed 's/^/    /'
done
echo ""

echo "============================================"
echo "  Test complete"
echo "============================================"
