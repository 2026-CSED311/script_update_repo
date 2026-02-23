#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_SCRIPT="${SCRIPT_DIR}/fetch.sh"
REMOTE="${1:-origin}"
SYSTEM_BRANCH="${2:-system}"
TIMESTAMP="$(date "+%Y-%m-%d %H:%M:%S")"

cd "$SCRIPT_DIR"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[ERROR] Not inside a git repository: $SCRIPT_DIR" >&2
  exit 1
fi

if [[ ! -f "$FETCH_SCRIPT" ]]; then
  echo "[ERROR] fetch.sh not found: $FETCH_SCRIPT" >&2
  exit 1
fi

echo "[$TIMESTAMP] Fetching latest data from $REMOTE..."
bash "$FETCH_SCRIPT" "$REMOTE"

merge_target=""
if git show-ref --verify --quiet "refs/heads/${SYSTEM_BRANCH}"; then
  merge_target="$SYSTEM_BRANCH"
elif git show-ref --verify --quiet "refs/remotes/${REMOTE}/${SYSTEM_BRANCH}"; then
  merge_target="${REMOTE}/${SYSTEM_BRANCH}"
else
  echo "[ERROR] No system branch found (checked: refs/heads/${SYSTEM_BRANCH}, refs/remotes/${REMOTE}/${SYSTEM_BRANCH})." >&2
  exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
echo "[$TIMESTAMP] Current branch: $current_branch"
echo "[$TIMESTAMP] Merging from: $merge_target"

if git merge --no-edit "$merge_target"; then
  echo "[OK] Merge succeeded: $merge_target -> $current_branch"
  exit 0
fi

echo "[ERROR] Merge failed. Aborting merge."
git merge --abort >/dev/null 2>&1 || true
exit 1
