#!/usr/bin/env python3
"""Convert CLIP-ReID ViT-B/16 image encoder to CoreML with INT4 quantization.

Usage:
    python scripts/convert_clipreid.py

Produces: CLIPReID.mlpackage (~45-50MB after INT4 quantization)
Input: 256x128 RGB image (person crop)
Output: 512-dim L2-normalized embedding

Requirements:
    pip install torch torchvision coremltools gdown
    git clone https://github.com/Syliz517/CLIP-ReID.git
"""

import os
import sys
import subprocess
import math
from pathlib import Path

import torch
import torch.nn as nn
import numpy as np


# --- Configuration ---
CLIPREID_DIR = Path("CLIP-ReID")
CHECKPOINT_PATH = Path("ViT-CLIP-ReID-MSMT17.pth")
GDRIVE_FILE_ID = "1sPZbWTv2_stXBGutjHMvE87pAbSAgVaz"
OUTPUT_FP16 = Path("CLIPReID_fp16.mlpackage")
OUTPUT_INT4 = Path("CLIPReID.mlpackage")
INPUT_H, INPUT_W = 256, 128


def setup_repo():
    """Clone CLIP-ReID repo if not present."""
    if not CLIPREID_DIR.exists():
        print("Cloning CLIP-ReID repository...")
        subprocess.run(
            ["git", "clone", "-q", "https://github.com/Syliz517/CLIP-ReID.git", str(CLIPREID_DIR)],
            check=True,
        )
    sys.path.insert(0, str(CLIPREID_DIR))


def download_checkpoint():
    """Download MSMT17 checkpoint from Google Drive."""
    if CHECKPOINT_PATH.exists():
        print(f"Checkpoint already exists: {CHECKPOINT_PATH}")
        return
    import gdown
    print("Downloading CLIP-ReID MSMT17 checkpoint (~330MB)...")
    gdown.download(id=GDRIVE_FILE_ID, output=str(CHECKPOINT_PATH), quiet=False)


def monkey_patch_attention():
    """Replace nn.MultiheadAttention.forward with traceable manual QKV implementation.

    nn.MultiheadAttention uses ops that can't be traced by torch.jit.trace.
    This replaces it with a manual implementation that produces identical results.
    """
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
    return original_forward


class CLIPReIDImageEncoder(nn.Module):
    """Wrapper that returns L2-normalized 512-dim CLIP projection from the full model."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        feat = self.model(x, get_image=True)  # [B, 512]
        feat = feat / (feat.norm(dim=-1, keepdim=True) + 1e-8)
        return feat


def build_and_load_model():
    """Build CLIP-ReID model and load MSMT17 checkpoint."""
    from model.make_model import make_model
    from config import cfg

    cfg.merge_from_file(str(CLIPREID_DIR / "configs" / "person" / "vit_clipreid.yml"))
    cfg.MODEL.PRETRAIN_CHOICE = "self"
    cfg.TEST.WEIGHT = ""
    cfg.MODEL.STRIDE_SIZE = [16, 16]
    cfg.INPUT.SIZE_TRAIN = [INPUT_H, INPUT_W]
    cfg.INPUT.SIZE_TEST = [INPUT_H, INPUT_W]

    num_classes = 4101  # MSMT17
    camera_num = 15
    view_num = 1
    model = make_model(cfg, num_class=num_classes, camera_num=camera_num, view_num=view_num)

    checkpoint = torch.load(str(CHECKPOINT_PATH), map_location="cpu")
    model.load_state_dict(checkpoint, strict=False)
    model.float()
    model.train(False)

    return model


def trace_model(encoder: nn.Module) -> torch.jit.ScriptModule:
    """Trace the encoder with example input."""
    example_input = torch.randn(1, 3, INPUT_H, INPUT_W)
    print("Tracing model...")

    # Disable flash SDP for clean tracing
    if hasattr(torch.backends.cuda, "enable_flash_sdp"):
        torch.backends.cuda.enable_flash_sdp(False)
    if hasattr(torch.backends.cuda, "enable_mem_efficient_sdp"):
        torch.backends.cuda.enable_mem_efficient_sdp(False)

    with torch.no_grad():
        traced = torch.jit.trace(encoder, example_input, check_trace=False)

    # Verify
    with torch.no_grad():
        ref_out = encoder(example_input)
        traced_out = traced(example_input)
        diff = (ref_out - traced_out).abs().max().item()
        print(f"Trace verification — max diff: {diff:.2e}")
        assert diff < 1e-4, f"Trace diverged: {diff}"

    return traced


def convert_to_coreml(traced_model: torch.jit.ScriptModule):
    """Convert traced model to CoreML FP16, then quantize to INT4."""
    import coremltools as ct

    print("Converting to CoreML FP16...")
    mlmodel = ct.convert(
        traced_model,
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
    print(f"FP16 model saved: {OUTPUT_FP16} ({fp16_size:.1f} MB)")

    # INT4 quantization
    print("Quantizing to INT4 (per-block, block_size=32)...")
    try:
        from coremltools.optimize.coreml import (
            OpLinearQuantizerConfig,
            OptimizationConfig,
            linear_quantize_weights,
        )
        op_config = OpLinearQuantizerConfig(
            mode="linear_symmetric",
            dtype="int4",
            granularity="per_block",
            block_size=32,
        )
        config = OptimizationConfig(global_config=op_config)
        mlmodel_int4 = linear_quantize_weights(mlmodel, config=config)
    except ImportError:
        print("WARNING: coremltools.optimize not available, falling back to FP16 only")
        mlmodel.save(str(OUTPUT_INT4))
        return mlmodel, None

    mlmodel_int4.save(str(OUTPUT_INT4))
    int4_size = sum(f.stat().st_size for f in OUTPUT_INT4.rglob("*") if f.is_file()) / 1e6
    print(f"INT4 model saved: {OUTPUT_INT4} ({int4_size:.1f} MB)")

    return mlmodel, mlmodel_int4


def verify_coreml(encoder: nn.Module):
    """Compare PyTorch FP32 vs CoreML INT4 embeddings."""
    import coremltools as ct
    from torchvision import transforms
    from PIL import Image

    mlmodel = ct.models.MLModel(str(OUTPUT_INT4))

    print("\nVerifying CoreML output vs PyTorch...")
    transform = transforms.Compose([
        transforms.Resize((INPUT_H, INPUT_W)),
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.5, 0.5, 0.5], std=[0.5, 0.5, 0.5]),
    ])

    n_samples = 5
    cosine_sims = []
    for i in range(n_samples):
        random_img = np.random.randint(0, 255, (INPUT_H, INPUT_W, 3), dtype=np.uint8)
        pil_img = Image.fromarray(random_img)

        # PyTorch
        inp = transform(pil_img).unsqueeze(0)
        with torch.no_grad():
            pt_emb = encoder(inp).numpy().flatten()

        # CoreML
        cm_out = mlmodel.predict({"body_image": pil_img})
        cm_emb = np.array(cm_out["embedding"]).flatten()

        cos_sim = np.dot(pt_emb, cm_emb) / (np.linalg.norm(pt_emb) * np.linalg.norm(cm_emb) + 1e-8)
        cosine_sims.append(cos_sim)
        print(f"  Sample {i+1}: cosine_sim={cos_sim:.6f}")

    avg_sim = np.mean(cosine_sims)
    print(f"\nAverage cosine similarity: {avg_sim:.6f}")
    if avg_sim > 0.95:
        print("PASS: CoreML INT4 output closely matches PyTorch FP32")
    else:
        print("WARNING: Significant divergence between CoreML and PyTorch")


def main():
    setup_repo()
    download_checkpoint()

    print("\nBuilding CLIP-ReID model...")
    model = build_and_load_model()
    encoder = CLIPReIDImageEncoder(model)
    encoder.train(False)

    # Quick shape check
    with torch.no_grad():
        test_out = encoder(torch.randn(1, 3, INPUT_H, INPUT_W))
        print(f"Output shape: {test_out.shape}")  # Should be [1, 512]
        assert test_out.shape == (1, 512), f"Expected [1, 512], got {test_out.shape}"

    print("\nMonkey-patching attention for tracing...")
    original_forward = monkey_patch_attention()

    traced = trace_model(encoder)

    # Restore original attention
    nn.MultiheadAttention.forward = original_forward

    convert_to_coreml(traced)
    verify_coreml(encoder)

    print("\nDone! Copy CLIPReID.mlpackage to Haya/Resources/ for the iOS app.")


if __name__ == "__main__":
    main()
