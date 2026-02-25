# Handoff — Haya Pipeline: InternVL3.5-4B INT8

## STATUS: READY FOR TESTING — InternVL3.5-4B INT8 with 1Q Modesty Checklist

## What's Done
1. Model switched from Qwen3-VL-2B → InternVL3.5-4B INT8
2. Single Q_MODESTY prompt — 6-area concise checklist (2-3 words per area)
3. cell9.py fully updated — prompts + VLM functions for InternVL3.5 HF API
4. Cell 16 (model loading) — BitsAndBytesConfig(load_in_8bit=True), device_map='auto', SDPA
5. Cell 18 synced with cell9.py in all 3 notebooks
6. Cell 1 markdown updated in all notebooks
7. No trust_remote_code needed (-HF model is native HF transformers)

## InternVL3.5-4B INT8 Loading Code
```python
vlm_id = "OpenGVLab/InternVL3_5-4B-HF"
from transformers import AutoProcessor, AutoModelForImageTextToText, BitsAndBytesConfig

quantization_config = BitsAndBytesConfig(load_in_8bit=True)
vlm_model = AutoModelForImageTextToText.from_pretrained(
    vlm_id,
    quantization_config=quantization_config,
    attn_implementation='sdpa',
    device_map='auto',
    low_cpu_mem_usage=True,
).eval()
vlm_processor = AutoProcessor.from_pretrained(vlm_id)
```

## Why 4B INT8 over 2B FP16
- MMMU 66.6 vs 59.0 (much smarter)
- POPE 88.9 vs 87.2 (better hallucination resistance)
- Same decode speed: 4B×1byte = 2B×2bytes = same memory bandwidth
- ~5GB VRAM (fits T4 16GB easily)
- iPhone: 4B INT4 (~2-2.5GB) fits 6GB via mlx-vlm

## Key Facts
- T4: FP16 + SDPA (no BF16, no flash_attention_2)
- BnB INT8 requires device_map='auto' (no manual .cuda())
- No torch_dtype needed — BnB manages dtype internally (FP16 for non-quantized parts)
- Prompt: single Q_MODESTY with self-verification, describe-then-judge
