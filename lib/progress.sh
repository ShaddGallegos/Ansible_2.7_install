#!/usr/bin/env bash
# Lightweight progress spinner and wrapper for long-running shell commands.
# Usage:
#   source lib/progress.sh
#   run_with_spinner "Downloading bundle" curl -L --fail -o /tmp/foo URL

progress__spinpid=""
progress__stty=""

progress_start() {
  local msg="${1:-Working...}"
  printf "%s " "${msg}"
  # Run spinner in background
  ( while :; do for c in '|/-\\'; do printf '%s' "${c}"; sleep 0.2; printf '\b'; done; done ) &
  progress__spinpid=$!
  disown ${progress__spinpid} 2>/dev/null || true
}

progress_stop() {
  local rc=${1:-0}
  if [[ -n "${progress__spinpid}" ]]; then
    kill "${progress__spinpid}" 2>/dev/null || true
    wait "${progress__spinpid}" 2>/dev/null || true
    unset progress__spinpid
  fi
  if [[ ${rc} -eq 0 ]]; then
    echo "OK"
  else
    echo "FAILED"
  fi
}

# Run a command with an inline spinner. First arg is a human message.
run_with_spinner() {
  local label="${1:-Working...}"; shift
  local _out; _out=$(mktemp) || _out=/tmp/prog_out_$$
  local _err; _err=$(mktemp) || _err=/tmp/prog_err_$$

  progress_start "${label}"
  "$@" >"${_out}" 2>"${_err}" &
  local _pid=$!
  local _rc=0
  # Wait for process to finish while spinner runs
  while kill -0 "${_pid}" 2>/dev/null; do sleep 0.2; done
  wait "${_pid}" || _rc=$?
  progress_stop ${_rc}

  if [[ ${_rc} -ne 0 ]]; then
    echo "Command failed: $*" >&2
    echo "Stdout:" >&2
    sed 's/^/  /' "${_out}" >&2 || true
    echo "Stderr:" >&2
    sed 's/^/  /' "${_err}" >&2 || true
  fi

  rm -f "${_out}" "${_err}" 2>/dev/null || true
  return ${_rc}
}

export -f run_with_spinner progress_start progress_stop
