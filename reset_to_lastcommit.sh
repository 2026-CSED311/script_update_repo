#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAST_CHECKPOINT="${SCRIPT_DIR}/LAST_CHECKPOINT"

if [[ ! -f "$LAST_CHECKPOINT" ]]; then
    echo "LAST_CHECKPOINT file not found: $LAST_CHECKPOINT" >&2
    exit 1
fi

HASH="$(tr -d '[:space:]' < "$LAST_CHECKPOINT")"
if [[ -z "$HASH" ]]; then
    echo "LAST_CHECKPOINT is empty: $LAST_CHECKPOINT" >&2
    exit 1
fi

if ! git rev-parse --verify "$HASH^{commit}" >/dev/null 2>&1; then
    echo "Invalid commit hash in LAST_CHECKPOINT: $HASH" >&2
    exit 1
fi

echo "Resetting to commit: $HASH"
git reset --hard "$HASH"
