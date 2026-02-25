#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# fetch.sh
# - Uses ~/.CSED311_key as the SSH private key only for this fetch
# - Downloads only remote updates (no merge/rebase/checkout)
# ============================================================

KEY_PATH="$HOME/.CSED311_key"

if [[ ! -f "$KEY_PATH" ]]; then
  echo "[ERROR] SSH key not found: $KEY_PATH" >&2
  exit 1
fi

chmod 600 "$KEY_PATH" || true

# repo인지 확인
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[ERROR] Not inside a git repository." >&2
  exit 1
fi

REMOTE="${1:-origin}"
BRANCH="${2:-}"

REMOTE_URL="$(git remote get-url "$REMOTE" 2>/dev/null || true)"
if [[ -z "$REMOTE_URL" ]]; then
  echo "[ERROR] Remote not found: $REMOTE" >&2
  exit 1
fi

if [[ "$REMOTE_URL" =~ ^https?:// ]]; then
  echo "[ERROR] Remote URL is HTTPS, not SSH:" >&2
  echo "        $REMOTE_URL" >&2
  echo "        This script uses SSH keys. Change remote to SSH form, e.g.:" >&2
  echo "        git remote set-url $REMOTE git@github.com:<org>/<repo>.git" >&2
  exit 1
fi

STRICT_OPT="-o StrictHostKeyChecking=accept-new"
SSH_CMD="ssh -i \"$KEY_PATH\" -o IdentitiesOnly=yes -o IdentityAgent=none -o PreferredAuthentications=publickey -F /dev/null $STRICT_OPT"

run_git_ssh() {
  GIT_SSH_COMMAND="$SSH_CMD" git "$@"
}

echo "[INFO] Using key: $KEY_PATH"
echo "[INFO] Remote   : $REMOTE ($REMOTE_URL)"

if [[ -n "$BRANCH" ]]; then
  echo "[INFO] Branch   : $BRANCH"
  run_git_ssh fetch --prune "$REMOTE" "$BRANCH"
else
  echo "[INFO] Branch   : (all tracked branches on $REMOTE)"
  run_git_ssh fetch --prune "$REMOTE"
fi

echo "[OK] git fetch completed."
