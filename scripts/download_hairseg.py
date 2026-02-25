#!/usr/bin/env python3
"""Download MediaPipe hair segmenter model for iOS."""

import os
import urllib.request
from config import MODEL_DIR

URL = "https://storage.googleapis.com/mediapipe-models/image_segmenter/hair_segmenter/float32/latest/hair_segmenter.tflite"
output_path = os.path.join(MODEL_DIR, "hair_segmenter.tflite")

print(f"Downloading hair_segmenter.tflite...")
urllib.request.urlretrieve(URL, output_path)
print(f"Saved to: {output_path}")
print(f"Size: {os.path.getsize(output_path) / 1024:.1f} KB")
print(f"Input: 512x512 RGBA, normalized 0-1")
print(f"Output: 512x512x2 (channel 0=background, channel 1=hair)")
