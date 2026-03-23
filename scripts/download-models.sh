#!/bin/bash
set -euo pipefail

# Model download script for Caddie
# Downloads FluidAudio ML models from HuggingFace into Resources/Models/
# Idempotent: skips files that already exist with correct size

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MODELS_DIR="${SRCROOT}/Resources/Models"
HF_BASE="https://huggingface.co"

# ASR: Parakeet TDT v3
PARAKEET_REPO="FluidInference/parakeet-tdt-0.6b-v3-coreml"
PARAKEET_DIR="${MODELS_DIR}/parakeet-tdt-0.6b-v3-coreml"

# Diarization: Sortformer V2
SORTFORMER_REPO="FluidInference/diar-streaming-sortformer-coreml"
SORTFORMER_DIR="${MODELS_DIR}/sortformer"

download_file() {
    local repo="$1" path="$2" dest="$3" expected_size="${4:-0}"

    if [ -f "$dest" ]; then
        if [ "$expected_size" -gt 0 ]; then
            local actual_size
            actual_size=$(stat -f%z "$dest" 2>/dev/null || echo 0)
            if [ "$actual_size" -eq "$expected_size" ]; then
                return 0
            fi
            echo "Size mismatch for $dest (expected $expected_size, got $actual_size), re-downloading"
        else
            return 0
        fi
    fi

    mkdir -p "$(dirname "$dest")"
    echo "Downloading: $path"
    curl -sL "${HF_BASE}/${repo}/resolve/main/${path}" -o "$dest"
}

echo "=== Downloading ASR Models ==="

# Weight files (large, with size validation)
download_file "$PARAKEET_REPO" "Encoder.mlmodelc/weights/weight.bin" \
    "$PARAKEET_DIR/Encoder.mlmodelc/weights/weight.bin" 445187200
download_file "$PARAKEET_REPO" "Decoder.mlmodelc/weights/weight.bin" \
    "$PARAKEET_DIR/Decoder.mlmodelc/weights/weight.bin" 23604992
download_file "$PARAKEET_REPO" "JointDecision.mlmodelc/weights/weight.bin" \
    "$PARAKEET_DIR/JointDecision.mlmodelc/weights/weight.bin" 12642764
download_file "$PARAKEET_REPO" "Preprocessor.mlmodelc/weights/weight.bin" \
    "$PARAKEET_DIR/Preprocessor.mlmodelc/weights/weight.bin" 491072

# Metadata and MIL files (small, existence check only)
for model in Encoder Decoder JointDecision Preprocessor; do
    download_file "$PARAKEET_REPO" "${model}.mlmodelc/coremldata.bin" \
        "$PARAKEET_DIR/${model}.mlmodelc/coremldata.bin"
    download_file "$PARAKEET_REPO" "${model}.mlmodelc/metadata.json" \
        "$PARAKEET_DIR/${model}.mlmodelc/metadata.json"
    download_file "$PARAKEET_REPO" "${model}.mlmodelc/model.mil" \
        "$PARAKEET_DIR/${model}.mlmodelc/model.mil"
    # Create analytics directory (may be empty but expected by CoreML)
    mkdir -p "$PARAKEET_DIR/${model}.mlmodelc/analytics"
done

# Vocabulary
download_file "$PARAKEET_REPO" "parakeet_vocab.json" \
    "$PARAKEET_DIR/parakeet_vocab.json" 151122

echo "=== Downloading Diarization Models ==="

# Sortformer V2 weight files (large, with size validation)
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model0/weights/0-weight.bin" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model0/weights/0-weight.bin" 8948544
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model1/weights/1-weight.bin" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model1/weights/1-weight.bin" 230428224

# Sortformer V2 metadata (small, existence check only)
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/coremldata.bin" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/coremldata.bin"
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/metadata.json" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/metadata.json"
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model0/coremldata.bin" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model0/coremldata.bin"
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model0/model.mil" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model0/model.mil"
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model1/coremldata.bin" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model1/coremldata.bin"
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model1/model.mil" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model1/model.mil"

# Create analytics directories (may be empty but expected by CoreML)
mkdir -p "$SORTFORMER_DIR/SortformerV2.mlmodelc/analytics"
mkdir -p "$SORTFORMER_DIR/SortformerV2.mlmodelc/model0/analytics"
mkdir -p "$SORTFORMER_DIR/SortformerV2.mlmodelc/model1/analytics"

echo "=== Models Ready ==="
