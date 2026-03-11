"""
CLIP-ReID → CoreML Converter for Kaggle
========================================
Run this as a Kaggle notebook (GPU not needed, CPU is fine).

Steps:
1. Create new Kaggle notebook
2. Paste this entire file into a single cell
3. Run it (~5 min)
4. Download the output: CLIPReID.mlpackage.zip (~45-50MB)
5. Give the zip to Claude to add to Haya/Resources/

Output: CLIPReID.mlpackage (INT4 quantized, ~45-50MB)
Input spec: 256x128 RGB image, mean/std=[0.5,0.5,0.5]
Output spec: 512-dim L2-normalized embedding
"""

import subprocess, sys, os

# --- Step 1: Install dependencies ---
print("=" * 60)
print("STEP 1: Installing dependencies...")
print("=" * 60)
subprocess.check_call([sys.executable, "-m", "pip", "install", "-q",
                       "coremltools>=8.0", "gdown", "yacs", "timm==0.9.16",
                       "ftfy", "regex"])

import os, sys, shutil, math
from pathlib import Path
import torch
import torch.nn as nn
import numpy as np

# --- Step 2: Clone CLIP-ReID repo ---
print("\n" + "=" * 60)
print("STEP 2: Cloning CLIP-ReID repository...")
print("=" * 60)

CLIPREID_DIR = Path("CLIP-ReID")
if not CLIPREID_DIR.exists():
    subprocess.run(["git", "clone", "-q", "https://github.com/Syliz517/CLIP-ReID.git", str(CLIPREID_DIR)], check=True)
    print("Cloned successfully")
else:
    print("Already exists")
sys.path.insert(0, str(CLIPREID_DIR))

# --- Step 3: Download checkpoint ---
print("\n" + "=" * 60)
print("STEP 3: Downloading MSMT17 checkpoint (~330MB)...")
print("=" * 60)

CHECKPOINT_PATH = Path("ViT-CLIP-ReID-MSMT17.pth")
GDRIVE_FILE_ID = "1sPZbWTv2_stXBGutjHMvE87pAbSAgVaz"

if not CHECKPOINT_PATH.exists():
    import gdown
    gdown.download(id=GDRIVE_FILE_ID, output=str(CHECKPOINT_PATH), quiet=False)
    print(f"Downloaded: {CHECKPOINT_PATH} ({CHECKPOINT_PATH.stat().st_size / 1e6:.1f} MB)")
else:
    print(f"Already exists: {CHECKPOINT_PATH}")

# --- Step 4: Build model ---
print("\n" + "=" * 60)
print("STEP 4: Building CLIP-ReID model...")
print("=" * 60)

INPUT_H, INPUT_W = 256, 128

from model.make_model import make_model
from config import cfg

# Skip yml merge entirely — it has DATASETS: with all sub-keys commented out,
# which YAML parses as null, causing yacs type mismatch. Set only the keys
# that build_transformer.__init__ actually reads.
cfg.MODEL.NAME = "ViT-B-16"
cfg.MODEL.STRIDE_SIZE = [12, 12]  # checkpoint trained with overlapping patches
cfg.MODEL.PRETRAIN_CHOICE = "self"
cfg.MODEL.SIE_CAMERA = True
cfg.MODEL.SIE_VIEW = False
cfg.MODEL.SIE_COE = 3.0
cfg.MODEL.COS_LAYER = False
cfg.MODEL.NECK = "bnneck"
cfg.TEST.NECK_FEAT = "before"
cfg.TEST.WEIGHT = ""
cfg.INPUT.SIZE_TRAIN = [INPUT_H, INPUT_W]
cfg.INPUT.SIZE_TEST = [INPUT_H, INPUT_W]

model = make_model(cfg, num_class=1041, camera_num=15, view_num=1)  # MSMT17 has 1041 identities
checkpoint = torch.load(str(CHECKPOINT_PATH), map_location="cpu")
model.load_state_dict(checkpoint, strict=False)
model.cpu().float()
model.train(False)

class CLIPReIDImageEncoder(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # In eval mode, build_transformer.forward(x) returns image features
        # It may return a tuple (feat, feat_proj) — we want the projected 512-dim
        out = self.model(x)
        if isinstance(out, (tuple, list)):
            feat = out[-1]  # projected features (512-dim)
        else:
            feat = out
        feat = feat / (feat.norm(dim=-1, keepdim=True) + 1e-8)
        return feat

encoder = CLIPReIDImageEncoder(model)
encoder.train(False)

with torch.no_grad():
    test_out = encoder(torch.randn(1, 3, INPUT_H, INPUT_W))
    print(f"Output shape: {test_out.shape}")
    assert test_out.shape == (1, 512), f"Expected [1, 512], got {test_out.shape}"
print("Model built successfully!")

# --- Step 5: Monkey-patch attention for tracing ---
print("\n" + "=" * 60)
print("STEP 5: Tracing model...")
print("=" * 60)

original_forward = nn.MultiheadAttention.forward

def traceable_forward(self, query, key, value, key_padding_mask=None,
                      need_weights=True, attn_mask=None, average_attn_weights=True):
    embed_dim = self.embed_dim
    num_heads = self.num_heads
    head_dim = embed_dim // num_heads
    scale = head_dim ** -0.5
    qkv = torch.nn.functional.linear(query, self.in_proj_weight, self.in_proj_bias)
    q, k, v = qkv.chunk(3, dim=-1)
    seq_len, batch_size = query.shape[0], query.shape[1]
    q = q.reshape(seq_len, batch_size, num_heads, head_dim).permute(1, 2, 0, 3)
    k = k.reshape(seq_len, batch_size, num_heads, head_dim).permute(1, 2, 0, 3)
    v = v.reshape(seq_len, batch_size, num_heads, head_dim).permute(1, 2, 0, 3)
    attn_weights = torch.matmul(q, k.transpose(-2, -1)) * scale
    attn_weights = torch.nn.functional.softmax(attn_weights, dim=-1)
    attn_output = torch.matmul(attn_weights, v)
    attn_output = attn_output.permute(2, 0, 1, 3).reshape(seq_len, batch_size, embed_dim)
    attn_output = torch.nn.functional.linear(attn_output, self.out_proj.weight, self.out_proj.bias)
    return attn_output, None

nn.MultiheadAttention.forward = traceable_forward

if hasattr(torch.backends.cuda, "enable_flash_sdp"):
    torch.backends.cuda.enable_flash_sdp(False)
if hasattr(torch.backends.cuda, "enable_mem_efficient_sdp"):
    torch.backends.cuda.enable_mem_efficient_sdp(False)

example_input = torch.randn(1, 3, INPUT_H, INPUT_W)
with torch.no_grad():
    traced = torch.jit.trace(encoder, example_input, check_trace=False)
    ref_out = encoder(example_input)
    traced_out = traced(example_input)
    diff = (ref_out - traced_out).abs().max().item()
    print(f"Trace verification — max diff: {diff:.2e}")
    assert diff < 1e-4, f"Trace diverged: {diff}"

nn.MultiheadAttention.forward = original_forward
print("Traced successfully!")

# --- Step 6: Convert to CoreML ---
print("\n" + "=" * 60)
print("STEP 6: Converting to CoreML FP16...")
print("=" * 60)

import coremltools as ct

OUTPUT_FP16 = Path("CLIPReID_fp16.mlpackage")
OUTPUT_INT4 = Path("CLIPReID.mlpackage")

mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(
        name="body_image",
        shape=(1, 3, INPUT_H, INPUT_W),
        scale=1.0 / (0.5 * 255.0),
        bias=[-0.5 / 0.5, -0.5 / 0.5, -0.5 / 0.5],
        color_layout="RGB",
    )],
    outputs=[ct.TensorType(name="embedding")],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.author = "Haya"
mlmodel.short_description = "CLIP-ReID ViT-B/16 body re-identification encoder (MSMT17)"
mlmodel.version = "1.0"
mlmodel.save(str(OUTPUT_FP16))

fp16_size = sum(f.stat().st_size for f in OUTPUT_FP16.rglob("*") if f.is_file()) / 1e6
print(f"FP16 saved: {OUTPUT_FP16} ({fp16_size:.1f} MB)")

# --- Step 7: Quantize to INT4 ---
print("\n" + "=" * 60)
print("STEP 7: Quantizing to INT4...")
print("=" * 60)

try:
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights,
    )
    op_config = OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype="int4",
        granularity="per_block", block_size=32,
    )
    config = OptimizationConfig(global_config=op_config)
    mlmodel_int4 = linear_quantize_weights(mlmodel, config=config)
    mlmodel_int4.save(str(OUTPUT_INT4))
    int4_size = sum(f.stat().st_size for f in OUTPUT_INT4.rglob("*") if f.is_file()) / 1e6
    print(f"INT4 saved: {OUTPUT_INT4} ({int4_size:.1f} MB)")
except Exception as e:
    print(f"INT4 quantization failed ({e}), using FP16 instead")
    shutil.copytree(str(OUTPUT_FP16), str(OUTPUT_INT4))

# --- Step 8: Zip for download ---
print("\n" + "=" * 60)
print("STEP 8: Zipping for download...")
print("=" * 60)

shutil.make_archive("CLIPReID.mlpackage", "zip", ".", "CLIPReID.mlpackage")
zip_size = Path("CLIPReID.mlpackage.zip").stat().st_size / 1e6
print(f"\nZipped: CLIPReID.mlpackage.zip ({zip_size:.1f} MB)")

print("\n" + "=" * 60)
print("DONE!")
print("=" * 60)
print(f"""
Download 'CLIPReID.mlpackage.zip' from the Output tab.

Specs:
  Input:  256x128 RGB image (body crop)
  Output: 512-dim L2-normalized embedding
  Size:   ~{zip_size:.0f} MB
  Format: CoreML mlpackage (iOS 17+)
""")
