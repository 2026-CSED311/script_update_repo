#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL="${INTERVAL:-10}"
MAX_ADD_BYTES="${MAX_ADD_BYTES:-1048576}"
LOG_FILE="${SCRIPT_DIR}/auto_commit.log"
touch "$LOG_FILE" 2>/dev/null || true
LAST_CHECKPOINT="${SCRIPT_DIR}/LAST_CHECKPOINT"
GITIGNORE_REMOTE="${GITIGNORE_REMOTE:-script_update_repo}"
GITIGNORE_REMOTE_URL="${GITIGNORE_REMOTE_URL:-https://github.com/2026-CSED311/script_update_repo.git}"
GITIGNORE_BRANCH="${GITIGNORE_BRANCH:-system}"

#
# Append all stdout/stderr to auto_commit.log,
# while still showing output in the terminal.
#
exec > >(tee -a "$LOG_FILE") 2>&1

get_file_size_bytes() {
    local path="$1"
    stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || wc -c < "$path" 2>/dev/null || echo 0
}

unstage_large_files() {
    local path=""
    while IFS= read -r -d '' path; do
        [[ -f "$path" ]] || continue
        local size
        size="$(get_file_size_bytes "$path")"
        [[ "$size" =~ ^[0-9]+$ ]] || continue

        if (( size > MAX_ADD_BYTES )); then
            git restore --staged -- "$path" >/dev/null 2>&1 || true
            printf '[%s] skip large file: %s (%s bytes > %s)\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$path" "$size" "$MAX_ADD_BYTES"
        fi
    done < <(git diff --cached --name-only -z --diff-filter=ACMR -- . ':(exclude)LAST_CHECKPOINT')
}

restore_gitignore_from_remote() {
    local timestamp="$1"
    local remote_ref="refs/remotes/${GITIGNORE_REMOTE}/${GITIGNORE_BRANCH}"

    if git remote get-url "$GITIGNORE_REMOTE" >/dev/null 2>&1; then
        git remote set-url "$GITIGNORE_REMOTE" "$GITIGNORE_REMOTE_URL" >/dev/null 2>&1 || true
    else
        git remote add "$GITIGNORE_REMOTE" "$GITIGNORE_REMOTE_URL" >/dev/null 2>&1 || true
    fi

    if ! git fetch --prune "$GITIGNORE_REMOTE" "$GITIGNORE_BRANCH" >/dev/null 2>&1; then
        printf '[%s] failed to fetch %s/%s\n' "$timestamp" "$GITIGNORE_REMOTE" "$GITIGNORE_BRANCH"
        return 0
    fi

    if ! git show-ref --verify --quiet "$remote_ref"; then
        printf '[%s] remote ref not found: %s/%s\n' "$timestamp" "$GITIGNORE_REMOTE" "$GITIGNORE_BRANCH"
        return 0
    fi

    if ! git cat-file -e "${GITIGNORE_REMOTE}/${GITIGNORE_BRANCH}:.gitignore" >/dev/null 2>&1; then
        printf '[%s] .gitignore not found in %s/%s\n' "$timestamp" "$GITIGNORE_REMOTE" "$GITIGNORE_BRANCH"
        return 0
    fi

    if git checkout "${GITIGNORE_REMOTE}/${GITIGNORE_BRANCH}" -- .gitignore >/dev/null 2>&1; then
        if ! git diff --quiet -- .gitignore; then
            printf '[%s] .gitignore restored from %s/%s\n' "$timestamp" "$GITIGNORE_REMOTE" "$GITIGNORE_BRANCH"
        fi
    else
        printf '[%s] failed to restore .gitignore from %s/%s\n' "$timestamp" "$GITIGNORE_REMOTE" "$GITIGNORE_BRANCH"
    fi
}

main() {
    cd "$SCRIPT_DIR"

    trap 'printf "\nStopped.\n"; exit 0' INT TERM HUP

    while true; do
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

        restore_gitignore_from_remote "$timestamp"

        if ! git add -A -- .; then
            printf '[%s] git add failed\n' "$timestamp"
            sleep "$INTERVAL"
            continue
        fi

        git restore --staged -- LAST_CHECKPOINT >/dev/null 2>&1 || true
        unstage_large_files

        if git diff --cached --quiet -- .; then
            printf '[%s] no staged changes\n' "$timestamp"
            sleep "$INTERVAL"
            continue
        fi

        if git commit -m "auto snapshot $timestamp"; then
            git rev-parse HEAD > "$LAST_CHECKPOINT"
            printf '[%s] commit done\n' "$timestamp"
        else
            printf '[%s] commit skipped or failed\n' "$timestamp"
        fi

        sleep "$INTERVAL"
    done
}

main "$@"