#!/bin/bash
# Long prompt test for KV cache verification
set -e

LONG_PROMPT="Write a comprehensive, detailed technical analysis of the following topics in order. First, explain the fundamental principles of distributed computing, including but not limited to the CAP theorem, consistency models, and partition tolerance. Then, discuss the evolution of machine learning from traditional statistical methods to modern deep learning approaches, covering key milestones such as the perceptron, backpropagation, convolutional neural networks, recurrent neural networks, and the transformer architecture. After that, analyze the intersection of distributed computing and machine learning, focusing on data parallelism, model parallelism, pipeline parallelism, and tensor parallelism. Provide specific examples of systems that implement these paradigms, such as Megatron-LM, DeepSpeed, and PyTorch Distributed. Finally, discuss the challenges and future directions of scaling large language models, including memory efficiency, communication overhead, and the trade-offs between different parallelism strategies. This comprehensive analysis should demonstrate a deep understanding of both theoretical foundations and practical implementations in the field of distributed machine learning systems."

echo "Prompt token count estimate: ~$(echo $LONG_PROMPT | wc -w) words"
echo ""

echo "====================================="
echo "Step 1: Send long prompt to Prefill server"
echo "====================================="
PREFILL_START=$(date +%s%N)
PREFILL_RESULT=$(curl -s -X POST http://localhost:8100/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"/model\", \"prompt\": \"$LONG_PROMPT\", \"max_tokens\": 1, \"temperature\": 0.0}")
PREFILL_END=$(date +%s%N)
PREFILL_MS=$(( (PREFILL_END - PREFILL_START) / 1000000 ))
echo "Prefill latency: ${PREFILL_MS} ms"
echo "Prefill usage: $(echo $PREFILL_RESULT | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get(\"usage\",{})))' 2>/dev/null || echo 'parse error')"

echo ""
echo "====================================="
echo "Step 2: Wait for KV cache store (10s)"
echo "====================================="
sleep 10

echo ""
echo "====================================="
echo "Step 3: Check Prefill cache store logs"
echo "====================================="
docker logs --since 30s vllm-prefill 2>&1 | grep -iE "store|put|save|remote|hit|token" | tail -20 || echo "No relevant logs"

echo ""
echo "====================================="
echo "Step 4: Send same prompt to Decode server"
echo "====================================="
DECODE_START=$(date +%s%N)
DECODE_RESULT=$(curl -s -X POST http://localhost:8200/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"/model\", \"prompt\": \"$LONG_PROMPT\", \"max_tokens\": 1, \"temperature\": 0.0}")
DECODE_END=$(date +%s%N)
DECODE_MS=$(( (DECODE_END - DECODE_START) / 1000000 ))
echo "Decode latency: ${DECODE_MS} ms"
echo "Decode usage: $(echo $DECODE_RESULT | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get(\"usage\",{})))' 2>/dev/null || echo 'parse error')"

echo ""
echo "====================================="
echo "Step 5: Check Decode cache hit logs"
echo "====================================="
docker logs --since 30s vllm-decode 2>&1 | grep -iE "hit|retrieve|load|token|cache" | tail -20 || echo "No relevant logs"

echo ""
echo "====================================="
echo "Step 6: Check Prefill full LMCache logs after request"
echo "====================================="
docker logs --since 60s vllm-prefill 2>&1 | grep -iE "LMCache" | tail -20 || echo "No LMCache logs"

echo ""
echo "====================================="
echo "Step 7: Cold TTFT on Decode (new prompt)"
echo "====================================="
for i in 1 2 3; do
  START=$(date +%s%N)
  curl -s -X POST http://localhost:8200/v1/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"/model\", \"prompt\": \"$LONG_PROMPT Please also discuss item number $i in more detail.\", \"max_tokens\": 1, \"temperature\": 0.0}" > /dev/null
  END=$(date +%s%N)
  MS=$(( (END - START) / 1000000 ))
  echo "  Cold TTFT run $i: ${MS} ms"
  sleep 1
done

echo ""
echo "====================================="
echo "Step 8: L2 TTFT from Decode (cached prompt)"
echo "====================================="
for i in 1 2 3; do
  START=$(date +%s%N)
  curl -s -X POST http://localhost:8200/v1/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"/model\", \"prompt\": \"$LONG_PROMPT\", \"max_tokens\": 1, \"temperature\": 0.0}" > /dev/null
  END=$(date +%s%N)
  MS=$(( (END - START) / 1000000 ))
  echo "  L2 TTFT run $i: ${MS} ms"
  sleep 1
done

echo ""
echo "====================================="
echo "Step 9: Check final cache logs"
echo "====================================="
docker logs --since 60s vllm-decode 2>&1 | grep -iE "LMCache" | tail -20 || echo "No LMCache logs"

echo ""
echo "====================================="
echo "Test complete!"
echo "====================================="
