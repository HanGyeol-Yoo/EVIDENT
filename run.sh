#!/bin/bash

echo "[INFO] Starting evaluation..."
source .venv/bin/activate

python3 main_eval.py \
  --tasks-json ./task/150_ko_metadata.json \
  --results-root ./results \
  --max-images 0 \
  --image-chunk-size 8 \
  --port 8005 \
  --workers 64 \
  --request-timeout 120

echo "[INFO] Evaluation finished."