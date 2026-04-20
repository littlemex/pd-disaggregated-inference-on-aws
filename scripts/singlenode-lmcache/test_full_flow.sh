#!/bin/bash
# Prefill-Decode Disaggregated Inference Full Flow Test
set -e

echo "====================================="
echo "Step 1: Prefill request (port 8100)"
echo "====================================="
PREFILL_START=$(date +%s%N)
PREFILL_RESULT=$(curl -s -X POST http://localhost:8100/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "/model", "messages": [{"role": "user", "content": "What is the capital of France? Answer in one word."}], "max_tokens": 10, "temperature": 0.0}')
PREFILL_END=$(date +%s%N)
PREFILL_MS=$(( (PREFILL_END - PREFILL_START) / 1000000 ))
echo "Prefill response: $PREFILL_RESULT"
echo "Prefill latency: ${PREFILL_MS} ms"

echo ""
echo "====================================="
echo "Step 2: Wait for KV cache to be stored (5s)"
echo "====================================="
sleep 5

echo ""
echo "====================================="
echo "Step 3: Decode request (port 8200) - same prompt"
echo "====================================="
DECODE_START=$(date +%s%N)
DECODE_RESULT=$(curl -s -X POST http://localhost:8200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "/model", "messages": [{"role": "user", "content": "What is the capital of France? Answer in one word."}], "max_tokens": 10, "temperature": 0.0}')
DECODE_END=$(date +%s%N)
DECODE_MS=$(( (DECODE_END - DECODE_START) / 1000000 ))
echo "Decode response: $DECODE_RESULT"
echo "Decode latency: ${DECODE_MS} ms"

echo ""
echo "====================================="
echo "Step 4: Multiple requests for stability"
echo "====================================="
for i in 1 2 3; do
  START=$(date +%s%N)
  RESULT=$(curl -s -X POST http://localhost:8200/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"/model\", \"messages\": [{\"role\": \"user\", \"content\": \"What is $i + $i?\"}], \"max_tokens\": 10, \"temperature\": 0.0}")
  END=$(date +%s%N)
  MS=$(( (END - START) / 1000000 ))
  echo "Request $i: ${MS} ms - $RESULT"
  sleep 1
done

echo ""
echo "====================================="
echo "Step 5: Error handling test (invalid model)"
echo "====================================="
ERROR_RESULT=$(curl -s -X POST http://localhost:8200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "nonexistent-model", "messages": [{"role": "user", "content": "test"}], "max_tokens": 10}')
echo "Error response: $ERROR_RESULT"

echo ""
echo "====================================="
echo "Step 6: Check Decode server cache logs"
echo "====================================="
docker logs vllm-decode 2>&1 | grep -iE "hit|retrieve|LMCache hit" | tail -15 || echo "No cache hit logs found"

echo ""
echo "====================================="
echo "Step 7: Check Prefill server cache logs"
echo "====================================="
docker logs vllm-prefill 2>&1 | grep -iE "store|save|put|LMCache" | tail -15 || echo "No cache store logs found"

echo ""
echo "====================================="
echo "Step 8: TTFT Benchmark"
echo "====================================="
echo "--- Cold TTFT (new prompt, no cache) ---"
for i in 1 2 3 4 5; do
  START=$(date +%s%N)
  curl -s -X POST http://localhost:8200/v1/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"/model\", \"prompt\": \"Explain quantum computing in detail for run number $i:\", \"max_tokens\": 1, \"temperature\": 0.0}" > /dev/null
  END=$(date +%s%N)
  MS=$(( (END - START) / 1000000 ))
  echo "  Cold TTFT run $i: ${MS} ms"
  sleep 1
done

echo ""
echo "--- L2 TTFT (same prompt, from ElastiCache) ---"
CACHE_PROMPT="Explain the theory of relativity in simple terms for benchmarking purposes"
# First request to populate cache via Prefill
curl -s -X POST http://localhost:8100/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"/model\", \"prompt\": \"$CACHE_PROMPT\", \"max_tokens\": 1, \"temperature\": 0.0}" > /dev/null
sleep 3

# Measure L2 TTFT from Decode server
for i in 1 2 3 4 5; do
  START=$(date +%s%N)
  curl -s -X POST http://localhost:8200/v1/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"/model\", \"prompt\": \"$CACHE_PROMPT\", \"max_tokens\": 1, \"temperature\": 0.0}" > /dev/null
  END=$(date +%s%N)
  MS=$(( (END - START) / 1000000 ))
  echo "  L2 TTFT run $i: ${MS} ms"
  sleep 1
done

echo ""
echo "====================================="
echo "Test complete!"
echo "====================================="
