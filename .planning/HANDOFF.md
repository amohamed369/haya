# Handoff — Haya Pipeline: Qwen3.5-4B (Native Multimodal)

## STATUS: READY FOR KAGGLE TESTING — Qwen3.5-4B with 1Q Modesty Checklist

## What Changed
1. Model switched from InternVL3.5-4B INT8 → Qwen3.5-4B (INT8 or FP16)
2. Qwen3.5 is natively multimodal (Image-Text-to-Text) — NOT text-only
3. MMMU 77.6 (beats InternVL3.5-4B at 66.6 by 11 points)
4. Same Q_MODESTY prompt — 6-area concise checklist (2-3 words per area)
5. iPhone app already updated to `mlx-community/Qwen3.5-4B-MLX-4bit` (3.03GB)
6. mlx-swift-lm supports `qwen3_5` architecture (PR #120, rev bc3c20ef)

## Qwen3.5-4B Loading Code (Kaggle/T4)
```python
vlm_id = "Qwen/Qwen3.5-4B"
from transformers import AutoProcessor, AutoModelForImageTextToText, BitsAndBytesConfig

# Option A: INT8 (recommended, same speed as InternVL3.5-4B INT8)
quantization_config = BitsAndBytesConfig(load_in_8bit=True)

# Option B: FP16 (if T4 VRAM allows — ~10GB)
# quantization_config = None; torch_dtype = torch.float16

vlm_model = AutoModelForImageTextToText.from_pretrained(
    vlm_id,
    quantization_config=quantization_config,
    attn_implementation='sdpa',
    device_map='auto',
    low_cpu_mem_usage=True,
).eval()
vlm_processor = AutoProcessor.from_pretrained(vlm_id)
```

## Why Qwen3.5-4B over InternVL3.5-4B
- MMMU 77.6 vs 66.6 (+11 points — massive improvement)
- OCRBench 85.0 vs unknown
- Native multimodal (vision trained from scratch, not bolted on)
- Same iPhone deployment path (mlx-swift-lm qwen3_5) — InternVL has NO iPhone path
- Same ~5GB VRAM on T4 with INT8
- architecture: `Qwen3_5ForConditionalGeneration`, model_type: `qwen3_5`

## Prompt (unchanged)
```python
Q_MODESTY = """Check this person for Islamic modesty. Describe what you see for each area, then judge:

HEAD/HAIR: [2-3 words] → covered?
NECK: [2-3 words] → covered?
ARMS: [2-3 words] → covered to wrists?
CHEST/TORSO: [2-3 words] → loose, not form-fitting?
LEGS: [2-3 words] → covered?
FIT: [2-3 words] → loose overall?

SELF-CHECK: Re-read your area descriptions. Any bare skin or hair visible?

VERDICT: YES (all covered) or NO (any bare skin/hair visible)"""

SYSTEM = "You check Islamic modesty in photos. Focus ONLY on THIS person. Be extremely concise."
```

## Generation Config
- max_new_tokens=200
- StopOnVerdict min_tokens=15 (halt on YES/NO after 15 tokens)
- JPEG compress crops (quality=85) before VLM
- `_parse_verdict` fallback only scans LAST LINE

## Key Facts
- T4: FP16 + SDPA (no BF16, no flash_attention_2 — T4 is SM75)
- BnB INT8 requires device_map='auto' (no manual .cuda())
- HuggingFace class: `Qwen3_5ForConditionalGeneration` (NOT Qwen3VL)
- No trust_remote_code needed
- No qwen_vl_utils needed

## Previous Model (for reference)
- InternVL3.5-4B INT8: `OpenGVLab/InternVL3_5-4B-HF`, MMMU 66.6, POPE 88.9
