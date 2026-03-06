#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_SCRIPT="${SCRIPT_DIR}/fetch.sh"
UPDATE_REMOTE="${UPDATE_REMOTE:-script_update_repo}"
UPDATE_URL="${UPDATE_URL:-https://github.com/2026-CSED311/script_update_repo.git}"
SYSTEM_BRANCH="${1:-system}"
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

# Ensure the public update remote exists.
current_update_url="$(git remote get-url "$UPDATE_REMOTE" 2>/dev/null || true)"
if [[ -z "$current_update_url" ]]; then
  echo "[$TIMESTAMP] Adding remote '$UPDATE_REMOTE' -> $UPDATE_URL"
  git remote add "$UPDATE_REMOTE" "$UPDATE_URL"
  current_update_url="$UPDATE_URL"
elif [[ "$current_update_url" != "$UPDATE_URL" ]]; then
  echo "[$TIMESTAMP] Updating remote '$UPDATE_REMOTE' URL"
  echo "[$TIMESTAMP]   old: $current_update_url"
  echo "[$TIMESTAMP]   new: $UPDATE_URL"
  git remote set-url "$UPDATE_REMOTE" "$UPDATE_URL"
  current_update_url="$UPDATE_URL"
fi

echo "[$TIMESTAMP] Fetching latest data from $UPDATE_REMOTE/$SYSTEM_BRANCH..."
if [[ "$current_update_url" =~ ^https?:// ]]; then
  git fetch --prune "$UPDATE_REMOTE" "$SYSTEM_BRANCH"
else
  # Reuse SSH-key based fetch helper for SSH remotes.
  bash "$FETCH_SCRIPT" "$UPDATE_REMOTE" "$SYSTEM_BRANCH"
fi

merge_target=""
if git show-ref --verify --quiet "refs/heads/${SYSTEM_BRANCH}"; then
  merge_target="${SYSTEM_BRANCH}"
elif git show-ref --verify --quiet "refs/remotes/${UPDATE_REMOTE}/${SYSTEM_BRANCH}"; then
  merge_target="${UPDATE_REMOTE}/${SYSTEM_BRANCH}"
else
  echo "[ERROR] No update branch found (checked: refs/heads/${SYSTEM_BRANCH}, refs/remotes/${UPDATE_REMOTE}/${SYSTEM_BRANCH})." >&2
  exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
echo "[$TIMESTAMP] Current branch: $current_branch"
echo "[$TIMESTAMP] Merging from  : $merge_target"

if git merge --no-edit "$merge_target"; then
  echo "[OK] Merge succeeded: $merge_target -> $current_branch"
  exit 0
fi

echo "[ERROR] Merge failed. Aborting merge."
git merge --abort >/dev/null 2>&1 || true
exit 1
