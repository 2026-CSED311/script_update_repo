#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# push_checker.sh
# - Clone current upstream(remote/branch) into ~/CSED311_test/<timestamp>
# - Reset hard to user-provided commit hash
# - Remove *.sh and .git from copied directory for safety
# ============================================================

KEY_PATH="$HOME/.CSED311_key"
HASH="${1:-}"

if [[ -z "$HASH" ]]; then
  echo "Usage: $0 <commit_hash>" >&2
  exit 1
fi

if [[ ! -f "$KEY_PATH" ]]; then
  echo "[ERROR] SSH key not found: $KEY_PATH" >&2
  exit 1
fi

chmod 600 "$KEY_PATH" || true

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[ERROR] Not inside a git repository." >&2
  exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
upstream_ref="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"

if [[ -n "$upstream_ref" ]]; then
  REMOTE="${upstream_ref%%/*}"
  BRANCH="${upstream_ref#*/}"
else
  REMOTE="origin"
  BRANCH="$current_branch"
fi

REMOTE_URL="$(git remote get-url "$REMOTE" 2>/dev/null || true)"
if [[ -z "$REMOTE_URL" ]]; then
  echo "[ERROR] Remote not found: $REMOTE" >&2
  exit 1
fi

if [[ "$REMOTE_URL" =~ ^https?:// ]]; then
  echo "[ERROR] Remote URL is HTTPS, not SSH:" >&2
  echo "        $REMOTE_URL" >&2
  echo "        Change remote to SSH first." >&2
  exit 1
fi

STRICT_OPT="-o StrictHostKeyChecking=accept-new"
SSH_CMD="ssh -i \"$KEY_PATH\" -o IdentitiesOnly=yes -o IdentityAgent=none -o PreferredAuthentications=publickey -F /dev/null $STRICT_OPT"

timestamp="$(date '+%Y%m%d_%H%M%S')"
target_root="$HOME/CSED311_test/$timestamp"
repo_name="$(basename -s .git "$REMOTE_URL")"
clone_dir="$target_root/$repo_name"

mkdir -p "$target_root"

echo "[INFO] Clone target : $clone_dir"
echo "[INFO] Remote/Branch: $REMOTE/$BRANCH"
echo "[INFO] Commit hash  : $HASH"

GIT_SSH_COMMAND="$SSH_CMD" git clone --branch "$BRANCH" "$REMOTE_URL" "$clone_dir"

(
  cd "$clone_dir"
  GIT_SSH_COMMAND="$SSH_CMD" git fetch --all --tags --prune
  git reset --hard "$HASH"
)

# Remove all shell scripts in the copied test directory.
find "$target_root" -type f -name "*.sh" -delete

# Remove git metadata to prevent accidental push.
find "$target_root" -type d -name ".git" -prune -exec rm -rf {} +

echo "[OK] Test copy created at: $clone_dir"
echo "[OK] Base directory      : $target_root"
