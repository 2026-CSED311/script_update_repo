#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
INTERVAL="${INTERVAL:-10}"
LOG_FILE="${SCRIPT_DIR}/program_check.log"
PID_FILE="${SCRIPT_DIR}/.auto_commit.pid"
LAST_CHECKPOINT="${SCRIPT_DIR}/LAST_CHECKPOINT"
GITIGNORE_BASE_COMMIT="${GITIGNORE_BASE_COMMIT:-e409549e706a353ae556e65cab93a5aff2f97b69}"
IS_SOURCED=0

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
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

enforce_gitignore_from_base() {
    local ts="$1"

    if ! git cat-file -e "${GITIGNORE_BASE_COMMIT}^{commit}" >/dev/null 2>&1; then
        echo "[$ts] baseline commit not found: $GITIGNORE_BASE_COMMIT" >> "$LOG_FILE"
        return 0
    fi

    if ! git cat-file -e "${GITIGNORE_BASE_COMMIT}:.gitignore" >/dev/null 2>&1; then
        echo "[$ts] .gitignore not found in baseline commit: $GITIGNORE_BASE_COMMIT" >> "$LOG_FILE"
        return 0
    fi

    if git checkout "$GITIGNORE_BASE_COMMIT" -- .gitignore >/dev/null 2>&1; then
        if ! git diff --quiet -- .gitignore; then
            echo "[$ts] .gitignore restored from $GITIGNORE_BASE_COMMIT" >> "$LOG_FILE"
        fi
    else
        echo "[$ts] failed to restore .gitignore from $GITIGNORE_BASE_COMMIT" >> "$LOG_FILE"
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
    echo "$$" > "$PID_FILE"
    trap cleanup_pid EXIT

    echo "Auto commit daemon started at $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    prepare_with_system_branch_once

    while true; do
        local timestamp
        local status_out
        timestamp="$(date "+%Y-%m-%d %H:%M:%S")"

        absorb_submodules "$timestamp" || true
        enforce_gitignore_from_base "$timestamp" || true

        if ! status_out="$(git status --porcelain -- . ':(exclude)LAST_CHECKPOINT' 2>&1)"; then
            echo "[$timestamp] git status failed: $status_out" >> "$LOG_FILE"
            sleep "$INTERVAL"
            continue
        fi

        {
            if [[ -n "$status_out" ]]; then
                echo "----------------------------------------"
                if ! git add -A -- . ':(exclude)LAST_CHECKPOINT'; then
                    echo "[$timestamp] git add failed. Retrying in next loop."
                    echo "----------------------------------------"
                    continue
                fi
                if git commit -m "auto snapshot $timestamp"; then
                    local last_hash
                    last_hash="$(git rev-parse HEAD)"
                    echo "$last_hash" > "$LAST_CHECKPOINT"
                    echo "[$timestamp] Commit done. hash=$last_hash"
                else
                    echo "[$timestamp] Commit skipped or failed."
                fi
                echo "----------------------------------------"
            else
                echo "[$timestamp] No changes."
            fi
        } >> "$LOG_FILE" 2>&1

        sleep "$INTERVAL"
    done
}

start_bg() {
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
    if is_running; then
        echo "running (PID $(read_pid))"
    else
        echo "stopped"
    fi
}

prompt_segment() {
    if is_running; then
        printf " \033[31m(auto-commit)\033[0m"
    fi
}

hook_code() {
    cat <<EOF
__auto_commit_prompt_hook() {
  AUTO_COMMIT_TAG="\$("$SCRIPT_PATH" prompt)"
  PS1="\${__AUTO_COMMIT_BASE_PS1}\${AUTO_COMMIT_TAG}"
}
if [[ -z "\${__AUTO_COMMIT_BASE_PS1+x}" ]]; then
  __AUTO_COMMIT_BASE_PS1="\${PS1}"
fi
case "\${PROMPT_COMMAND-}" in
  *__auto_commit_prompt_hook*) ;;
  *) PROMPT_COMMAND="__auto_commit_prompt_hook\${PROMPT_COMMAND:+; \${PROMPT_COMMAND}}" ;;
esac
EOF
}

unhook_code() {
        cat <<'EOF'
# Remove the auto-commit prompt hook from this shell
if [[ -n "${PROMPT_COMMAND-}" ]]; then
    PROMPT_COMMAND="${PROMPT_COMMAND//__auto_commit_prompt_hook; /}"
    PROMPT_COMMAND="${PROMPT_COMMAND//; __auto_commit_prompt_hook/}"
    PROMPT_COMMAND="${PROMPT_COMMAND//__auto_commit_prompt_hook/}"
fi
# Restore original PS1 if we saved one.
if [[ -n "${__AUTO_COMMIT_BASE_PS1-}" ]]; then
    PS1="${__AUTO_COMMIT_BASE_PS1}"
fi
unset AUTO_COMMIT_TAG 2>/dev/null || true
unset __AUTO_COMMIT_BASE_PS1 2>/dev/null || true
unset -f __auto_commit_prompt_hook 2>/dev/null || true
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
