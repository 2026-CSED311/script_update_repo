#!/usr/bin/env bash

# Resolve the current script path for both bash and zsh.
SCRIPT_SELF=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_SELF="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
    SCRIPT_SELF="${(%):-%N}"
else
    SCRIPT_SELF="$0"
fi

SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SELF")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$SCRIPT_SELF")"
SCRIPT_NAME="$(basename "$SCRIPT_SELF")"
INTERVAL="${INTERVAL:-10}"
MAX_ADD_BYTES="${MAX_ADD_BYTES:-1048576}" # 1MB
LOG_FILE="${SCRIPT_DIR}/auto_commit.log"
PID_FILE="${SCRIPT_DIR}/.auto_commit.pid"
LAST_CHECKPOINT="${SCRIPT_DIR}/LAST_CHECKPOINT"
GITIGNORE_REMOTE="${GITIGNORE_REMOTE:-script_update_repo}"
GITIGNORE_REMOTE_URL="${GITIGNORE_REMOTE_URL:-https://github.com/2026-CSED311/script_update_repo.git}"
GITIGNORE_BRANCH="${GITIGNORE_BRANCH:-system}"
AUTO_COMMIT_TZ="${AUTO_COMMIT_TZ:-Asia/Seoul}"
IS_SOURCED=0
# Track already-logged oversized files to avoid repetitive log spam.
# Keep a newline-delimited set for bash 3.2 compatibility (no associative arrays).
LARGE_FILE_WARNED_LIST=""
LAST_FILTER_SUMMARY=""

export TZ="$AUTO_COMMIT_TZ"

if [[ -n "${ZSH_VERSION:-}" ]]; then
    case "${ZSH_EVAL_CONTEXT:-}" in
        *:file) IS_SOURCED=1 ;;
    esac
elif [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
    IS_SOURCED=1
fi

is_running() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

read_pid() {
    cat "$PID_FILE" 2>/dev/null || true
}

cleanup_pid() {
    local pid
    pid="$(read_pid)"
    if [[ "$pid" == "$$" ]]; then
        rm -f "$PID_FILE"
    fi
}

ensure_safe_directory() {
    local repo_path="$1"
    git config --global --add safe.directory "$repo_path" >/dev/null 2>&1 || true
}

ensure_runtime_paths_writable() {
    local fallback_base="/tmp/auto_commit_${USER:-user}_$(basename "$SCRIPT_DIR")"

    if ! (touch "$LOG_FILE" >/dev/null 2>&1); then
        LOG_FILE="${fallback_base}.log"
        touch "$LOG_FILE" >/dev/null 2>&1 || true
    fi

    if ! (touch "$PID_FILE" >/dev/null 2>&1); then
        PID_FILE="${fallback_base}.pid"
        touch "$PID_FILE" >/dev/null 2>&1 || true
    fi
}

get_file_size_bytes() {
    local path="$1"
    stat -c%s "$path" 2>/dev/null || wc -c < "$path" 2>/dev/null || echo 0
}

unstage_large_files() {
    local ts="$1"
    local path=""
    local entries=()
    LAST_FILTER_SUMMARY=""

    while IFS= read -r -d '' path; do
        [[ -f "$path" ]] || continue
        local size
        size="$(get_file_size_bytes "$path")"
        [[ "$size" =~ ^[0-9]+$ ]] || continue

        if (( size > MAX_ADD_BYTES )); then
            git restore --staged -- "$path" >/dev/null 2>&1 || true
            local mtime
            mtime="$(stat -c %Y "$path" 2>/dev/null || echo 0)"
            entries+=("${mtime}|${path}")
            if [[ -z "${LARGE_FILE_WARNED["$path"]+x}" ]]; then
                echo "[$ts] Skip large file (> $MAX_ADD_BYTES bytes): $path ($size bytes)" >> "$LOG_FILE"
                LARGE_FILE_WARNED["$path"]=1
            fi
        fi
    done < <(git diff --cached --name-only -z --diff-filter=ACMR -- . ':(exclude)LAST_CHECKPOINT')

    if (( ${#entries[@]} > 0 )); then
        local top_paths=()
        mapfile -t top_paths < <(
            printf "%s\n" "${entries[@]}" \
            | sort -t'|' -k1,1nr \
            | cut -d'|' -f2- \
            | head -n 5
        )
        LAST_FILTER_SUMMARY="$(IFS=', '; echo "${top_paths[*]}")"
    fi
}
absorb_submodules() {
    local ts="$1"
    # clone/fetch/pull 등과 경합할 수 있으므로 항상 best-effort로 처리
    while read -r sub_git; do
        local sub_dir
        sub_dir=$(dirname "$sub_git")
        
        echo "[$ts] Submodule detected at $sub_dir. Absorbing..." >> "$LOG_FILE"
        
        git rm --cached "$sub_dir" >/dev/null 2>&1 || true
        
        if rm -rf "$sub_git" >/dev/null 2>&1; then
            echo "[$ts] $sub_dir is now a regular directory." >> "$LOG_FILE"
        else
            echo "[$ts] Skip absorbing $sub_dir (.git busy/in-use)." >> "$LOG_FILE"
        fi
    done < <(find . -mindepth 2 -name ".git" -type d 2>/dev/null || true)

    return 0
}

enforce_gitignore_from_remote() {
    local ts="$1"
    local remote_ref="refs/remotes/${GITIGNORE_REMOTE}/${GITIGNORE_BRANCH}"

    if git remote get-url "$GITIGNORE_REMOTE" >/dev/null 2>&1; then
        git remote set-url "$GITIGNORE_REMOTE" "$GITIGNORE_REMOTE_URL" >/dev/null 2>&1 || true
    else
        git remote add "$GITIGNORE_REMOTE" "$GITIGNORE_REMOTE_URL" >/dev/null 2>&1 || true
    fi

    if ! git fetch --prune "$GITIGNORE_REMOTE" "$GITIGNORE_BRANCH" >/dev/null 2>&1; then
        echo "[$ts] failed to fetch ${GITIGNORE_REMOTE}/${GITIGNORE_BRANCH}" >> "$LOG_FILE"
        return 0
    fi

    if ! git show-ref --verify --quiet "$remote_ref"; then
        echo "[$ts] remote ref not found: ${GITIGNORE_REMOTE}/${GITIGNORE_BRANCH}" >> "$LOG_FILE"
        return 0
    fi

    if ! git cat-file -e "${GITIGNORE_REMOTE}/${GITIGNORE_BRANCH}:.gitignore" >/dev/null 2>&1; then
        echo "[$ts] .gitignore not found in ${GITIGNORE_REMOTE}/${GITIGNORE_BRANCH}" >> "$LOG_FILE"
        return 0
    fi

    if git checkout "${GITIGNORE_REMOTE}/${GITIGNORE_BRANCH}" -- .gitignore >/dev/null 2>&1; then
        if ! git diff --quiet -- .gitignore; then
            echo "[$ts] .gitignore restored from ${GITIGNORE_REMOTE}/${GITIGNORE_BRANCH}" >> "$LOG_FILE"
        fi
    else
        echo "[$ts] failed to restore .gitignore from ${GITIGNORE_REMOTE}/${GITIGNORE_BRANCH}" >> "$LOG_FILE"
    fi

    return 0
}

prepare_with_system_branch_once() {
    local timestamp
    local merge_target=""
    timestamp="$(date "+%Y-%m-%d %H:%M:%S")"

    if git show-ref --verify --quiet refs/heads/system; then
        merge_target="system"
    elif git show-ref --verify --quiet refs/remotes/origin/system; then
        merge_target="origin/system"
    else
        return 0
    fi

    {
        echo "[$timestamp] system branch detected ($merge_target). Preparing reset+merge before loop."

        if [[ -x "${SCRIPT_DIR}/reset_to_lastcommit.sh" ]]; then
            if bash "${SCRIPT_DIR}/reset_to_lastcommit.sh"; then
                echo "[$timestamp] reset_to_lastcommit.sh succeeded."
            else
                echo "[$timestamp] reset_to_lastcommit.sh failed. Continuing to merge attempt."
            fi
        else
            echo "[$timestamp] reset_to_lastcommit.sh not found or not executable. Skipping reset."
        fi

        if git merge --no-edit "$merge_target"; then
            echo "[$timestamp] Merge from $merge_target succeeded."
        else
            echo "[$timestamp] Merge from $merge_target failed. Continuing loop."
            git merge --abort >/dev/null 2>&1 || true
        fi
    } >> "$LOG_FILE" 2>&1
}

run_worker() {
    set -euo pipefail
    cd "$SCRIPT_DIR"
    ensure_runtime_paths_writable
    echo "$$" > "$PID_FILE"
    trap cleanup_pid EXIT

    ensure_safe_directory "$SCRIPT_DIR"
    echo "Auto commit daemon started at $(date '+%Y-%m-%d %H:%M:%S %Z')" >> "$LOG_FILE"
    prepare_with_system_branch_once

    while true; do
        local timestamp
        local status_out
        timestamp="$(date "+%Y-%m-%d %H:%M:%S")"

        absorb_submodules "$timestamp" || true
        enforce_gitignore_from_remote "$timestamp" || true

        if ! status_out="$(git status --porcelain 2>&1)"; then
            echo "[$timestamp] git status failed: $status_out" >> "$LOG_FILE"
            sleep "$INTERVAL"
            continue
        fi
        status_out="$(printf '%s\n' "$status_out" | grep -Ev '^[ MADRCU?!]{1,2} LAST_CHECKPOINT$' || true)"

        {
            if [[ -n "$status_out" ]]; then
                if ! git add -A -- .; then
                    echo "[$timestamp] git add failed. Retrying in next loop."
                else
                    # Keep checkpoint bookkeeping file out of auto commits.
                    git restore --staged -- LAST_CHECKPOINT >/dev/null 2>&1 || true
                    unstage_large_files "$timestamp" || true
                    if git diff --cached --quiet -- .; then
                        if [[ -n "$LAST_FILTER_SUMMARY" ]]; then
                            echo "[$timestamp] after filter [$LAST_FILTER_SUMMARY]"
                        else
                            echo "[$timestamp] after filter []"
                        fi
                    elif git commit -m "auto snapshot $timestamp"; then
                        local last_hash
                        last_hash="$(git rev-parse HEAD)"
                        echo "$last_hash" > "$LAST_CHECKPOINT"
                        echo "----------------------------------------"
                        echo "[$timestamp] Commit done. hash=$last_hash"
                        echo "----------------------------------------"
                    else
                        echo "[$timestamp] Commit skipped or failed."
                    fi
                fi
            else
                echo "[$timestamp] No changes."
            fi
        } >> "$LOG_FILE" 2>&1

        sleep "$INTERVAL"
    done
}

start_bg() {
    ensure_runtime_paths_writable
    if is_running; then
        echo "Already running (PID $(read_pid))."
        return 0
    fi

    nohup bash "$SCRIPT_PATH" --worker >/dev/null 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    echo "Started in background (PID $pid). Log: $LOG_FILE"
}

stop_bg() {
    ensure_runtime_paths_writable
    if ! is_running; then
        rm -f "$PID_FILE"
        echo "Not running."
        return 0
    fi

    local pid
    pid="$(read_pid)"
    kill "$pid" 2>/dev/null || true
    sleep 0.2

    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    echo "Stopped (PID $pid)."
}

status_bg() {
    ensure_runtime_paths_writable
    if is_running; then
        echo "running (PID $(read_pid))"
    else
        echo "stopped"
    fi
}

prompt_segment() {
    ensure_runtime_paths_writable
    if is_running; then
        printf "(auto-commit)"
    fi
}

hook_code() {
    cat <<EOF
__auto_commit_strip_legacy_markers() {
  local ps1="\$1"

  while true; do
    case "\${ps1}" in
      '\[\033[31m\]\$(__auto_commit_dynamic_prefix)\[\033[0m\]'*)
        ps1="\${ps1#'\[\033[31m\]\$(__auto_commit_dynamic_prefix)\[\033[0m\]'}"
        ;;
      '\$(__auto_commit_dynamic_prefix)'*)
        ps1="\${ps1#'\$(__auto_commit_dynamic_prefix)'}"
        ;;
      '(auto-commit) '*)
        ps1="\${ps1#'(auto-commit) '}"
        ;;
      *' | (auto-commit)\\$ ')
        ps1="\${ps1% | (auto-commit)\\\\$ }"
        ;;
      *' | (auto-commit)\\$')
        ps1="\${ps1% | (auto-commit)\\\\$}"
        ;;
      *' | (auto-commit)$ ')
        ps1="\${ps1%' | (auto-commit)$ '}"
        ;;
      *' | (auto-commit)$')
        ps1="\${ps1%' | (auto-commit)$'}"
        ;;
      *)
        break
        ;;
    esac
  done

  printf "%s" "\${ps1}"
}

__auto_commit_dynamic_prefix() {
  local tag
  tag="\$("$SCRIPT_PATH" prompt)"
  if [[ -n "\${tag}" ]]; then
    # \001/\002 mark non-printing sequences for readline prompt length accounting.
    printf '\001\033[31m\002%s\001\033[0m\002 ' "\${tag}"
  fi
}

# Remove legacy hook entries from older versions.
if [[ -n "\${PROMPT_COMMAND-}" ]]; then
  PROMPT_COMMAND="\${PROMPT_COMMAND//__auto_commit_prompt_hook; /}"
  PROMPT_COMMAND="\${PROMPT_COMMAND//; __auto_commit_prompt_hook/}"
  PROMPT_COMMAND="\${PROMPT_COMMAND//__auto_commit_prompt_hook/}"
fi

if [[ -n "\${__AUTO_COMMIT_BASE_PS1-}" ]]; then
  __AUTO_COMMIT_BASE_PS1="\$(__auto_commit_strip_legacy_markers "\${__AUTO_COMMIT_BASE_PS1}")"
else
  __AUTO_COMMIT_BASE_PS1="\$(__auto_commit_strip_legacy_markers "\${PS1}")"
fi

PS1='\$(__auto_commit_dynamic_prefix)'"\${__AUTO_COMMIT_BASE_PS1}"
EOF
}

unhook_code() {
        cat <<'EOF'
# Remove legacy prompt hook entry from this shell
if [[ -n "${PROMPT_COMMAND-}" ]]; then
    PROMPT_COMMAND="${PROMPT_COMMAND//__auto_commit_prompt_hook; /}"
    PROMPT_COMMAND="${PROMPT_COMMAND//; __auto_commit_prompt_hook/}"
    PROMPT_COMMAND="${PROMPT_COMMAND//__auto_commit_prompt_hook/}"
fi

if [[ -n "${__AUTO_COMMIT_BASE_PS1-}" ]]; then
    PS1="${__AUTO_COMMIT_BASE_PS1}"
else
    while true; do
        case "${PS1}" in
            '\[\033[31m\]$(__auto_commit_dynamic_prefix)\[\033[0m\]'*)
                PS1="${PS1#'\[\033[31m\]$(__auto_commit_dynamic_prefix)\[\033[0m\]'}"
                ;;
            '$(__auto_commit_dynamic_prefix)'*)
                PS1="${PS1#'$(__auto_commit_dynamic_prefix)'}"
                ;;
            '(auto-commit) '*)
                PS1="${PS1#'(auto-commit) '}"
                ;;
            *' | (auto-commit)\$ ')
                PS1="${PS1% | (auto-commit)\\$ }"
                ;;
            *' | (auto-commit)\$')
                PS1="${PS1% | (auto-commit)\\$}"
                ;;
            *' | (auto-commit)$ ')
                PS1="${PS1%' | (auto-commit)$ '}"
                ;;
            *' | (auto-commit)$')
                PS1="${PS1%' | (auto-commit)$'}"
                ;;
            *)
                break
                ;;
        esac
    done
fi

unset AUTO_COMMIT_TAG 2>/dev/null || true
unset __AUTO_COMMIT_BASE_PS1 2>/dev/null || true
unset -f __auto_commit_prompt_hook 2>/dev/null || true
unset -f __auto_commit_dynamic_prefix 2>/dev/null || true
unset -f __auto_commit_strip_legacy_markers 2>/dev/null || true
unset -f __auto_commit_strip_injected_tag 2>/dev/null || true
unset -f __auto_commit_strip_prefix_tag 2>/dev/null || true
unset -f __auto_commit_strip_prompt_char 2>/dev/null || true
EOF
}

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [start|stop|status|prompt|hook|unhook]
Default when executed: start
Default when sourced: hook + start
EOF
}

dispatch() {
    case "${1:-start}" in
        start)
            start_bg
            ;;
        --worker|worker)
            run_worker
            ;;
        stop)
            stop_bg
            ;;
        unhook)
            unhook_code
            ;;
        status)
            status_bg
            ;;
        prompt)
            prompt_segment
            ;;
        hook)
            hook_code
            ;;
        *)
            usage
            return 1
            ;;
    esac
}

if [[ "$IS_SOURCED" -eq 1 ]]; then
    if [[ "$#" -eq 0 ]]; then
        eval "$("$SCRIPT_PATH" hook)"
        "$SCRIPT_PATH" start
        return 0
    fi
    # stop keeps the hook active; tag disappears automatically when daemon is stopped
    if [[ "${1:-}" == "stop" ]]; then
        dispatch stop
        return $?
    fi
    if [[ "${1:-}" == "unhook" ]]; then
        eval "$("$SCRIPT_PATH" unhook)"
        return $?
    fi
    dispatch "${1:-}"
    return $?
fi

dispatch "${1:-start}"
