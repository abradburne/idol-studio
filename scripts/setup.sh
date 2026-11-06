#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

engine=.local/engine/mlx-serve-macos-arm64
archive=.local/mlx-serve.tar.gz
mkdir -p .local/engine

if [[ ! -x "$engine/mlx-serve" ]]; then
    curl --fail --location --retry 3 --continue-at - --output "$archive" \
        https://github.com/ddalcu/mlx-serve/releases/download/v26.11.2/mlx-serve-bin-macos-arm64.tar.gz
    printf '%s  %s\n' 550561d8bee59c40163da5e356d107fc290544c5f5d07d5add9943571b6930b5 "$archive" | shasum -a 256 -c
    tar -xzf "$archive" -C .local/engine
fi

./scripts/build.sh
