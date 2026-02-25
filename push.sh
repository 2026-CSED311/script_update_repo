#!/usr/bin/env bash
set -euo pipefail

# Test?
# ============================================================
# push.sh
# - Uses ~/.CSED311_key as the SSH private key only for this push
# - Works even if you have other ssh keys loaded
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
#Cur Branch
BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD)}" 

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

echo "[INFO] Using key: $KEY_PATH"
echo "[INFO] Remote   : $REMOTE ($REMOTE_URL)"
echo "[INFO] Branch   : $BRANCH"

STRICT_OPT="-o StrictHostKeyChecking=accept-new"
SSH_CMD="ssh -i \"$KEY_PATH\" -o IdentitiesOnly=yes -o IdentityAgent=none -o PreferredAuthentications=publickey -F /dev/null $STRICT_OPT"

run_git_ssh() {
  GIT_SSH_COMMAND="$SSH_CMD" git "$@"
}

run_git_ssh push "$REMOTE" "$BRANCH"

echo "[OK] git push completed."
