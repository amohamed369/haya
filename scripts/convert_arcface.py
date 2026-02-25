#!/usr/bin/env python3
"""Convert InsightFace ArcFace w600k_r50 from ONNX to CoreML."""

import os
import onnx
import coremltools as ct
from huggingface_hub import hf_hub_download
from config import MODEL_DIR

# Download ArcFace ONNX from HuggingFace
print("Downloading ArcFace w600k_r50.onnx from HuggingFace...")
onnx_path = hf_hub_download(
    repo_id="public-data/insightface",
    filename="models/buffalo_l/w600k_r50.onnx",
    local_dir=MODEL_DIR,
)
print(f"Downloaded to: {onnx_path}")

# Convert ONNX -> CoreML
print("Converting to CoreML...")
model = ct.convert(
    onnx_path,
    source="onnx",
    inputs=[
        ct.ImageType(
            name="face_image",
            shape=(1, 3, 112, 112),
            bias=[-1.0, -1.0, -1.0],
            scale=1.0 / 127.5,
            color_layout=ct.colorlayout.RGB,
        )
    ],
    outputs=[ct.TensorType(name="output", dtype=float)],
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
)

output_path = os.path.join(MODEL_DIR, "ArcFace.mlpackage")
model.save(output_path)
print(f"Saved CoreML model to: {output_path}")
print(f"Input: 112x112 RGB face crop, normalized to [-1, 1]")
print(f"Output: 512-dim embedding vector")
