"""
gpu-sdk-example.py — OpenAI SDK chat completion against the GPU inference frontend.

Requires an active port-forward to the GPU frontend service:
    kubectl port-forward svc/dynamo-gpu-frontend -n dynamo-demo 9000:8000

Or run via the Makefile which handles the port-forward automatically:
    make gpu-sdk-example

Tuning notes for this environment (RTX 3070 Ti, 8 GiB VRAM):
  - max_tokens=128 is sufficient for a concise answer; context window is capped at
    max-model-len=2048 in the manifest due to per-process VRAM overhead constraints.
  - enable_thinking=False suppresses Qwen3's chain-of-thought reasoning tokens.
    Without it, the <think> block consumes the token budget before the answer is
    emitted. On hardware with a larger context window this can be removed to see
    Qwen3's full reasoning output.
"""

from openai import OpenAI

BASE_URL = "http://localhost:9000/v1"

client = OpenAI(base_url=BASE_URL, api_key="unused")

print(f"Connecting to Dynamo GPU frontend at {BASE_URL}")
print("Model: Qwen/Qwen3-0.6B (disaggregated vLLM — prefill + decode workers)")
print()

response = client.chat.completions.create(
    model="Qwen/Qwen3-0.6B",
    messages=[{"role": "user", "content": "What is disaggregated inference?"}],
    max_tokens=128,
    extra_body={"chat_template_kwargs": {"enable_thinking": False}},
)

print("Question: What is disaggregated inference?")
print()
print("Answer:", response.choices[0].message.content)
print()
print(f"Usage: prompt={response.usage.prompt_tokens} tokens, "
      f"completion={response.usage.completion_tokens} tokens")
