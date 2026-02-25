#!/usr/bin/env python3
"""Export YOLO11n-seg to CoreML format for iOS person detection + segmentation."""

import os
import shutil
from ultralytics import YOLO
from config import MODEL_DIR

# Load YOLO11n-seg (instance segmentation — per-person masks)
print("Loading YOLO11n-seg...")
model = YOLO("yolo11n-seg.pt")

# Export to CoreML
# nms=True bakes Non-Maximum Suppression into the model (simpler Swift code)
# half=True exports as FP16 (smaller + faster on Neural Engine)
print("Exporting to CoreML...")
model.export(format="coreml", nms=True, half=True, imgsz=640)

# Move to models directory
src = "yolo11n-seg.mlpackage"
dst = os.path.join(MODEL_DIR, "YOLO11nSeg.mlpackage")
if os.path.exists(dst):
    shutil.rmtree(dst)
if os.path.exists(src):
    shutil.move(src, dst)
    print(f"Saved CoreML model to: {dst}")
else:
    print(f"ERROR: Expected {src} but not found. Check ultralytics output.")

print(f"Input: 640x640 RGB image")
print(f"Output: Bounding boxes + instance masks with class labels + confidence (person = class 0)")
