# shellcheck shell=bash
# Supported Ansible runtime and project playbook execution helpers.

get_supported_ansible_playbook() {
  local candidate version minor python_cmd venv_dir

  if [[ -n "${AAP_ANSIBLE_PLAYBOOK:-}" ]]; then
    [[ -x "${AAP_ANSIBLE_PLAYBOOK}" ]] || {
      err "AAP_ANSIBLE_PLAYBOOK is not executable: ${AAP_ANSIBLE_PLAYBOOK}"
      return 1
    }
    printf '%s' "${AAP_ANSIBLE_PLAYBOOK}"
    return 0
  fi

  venv_dir="${SCRIPT_DIR}/.venv-aap27-runtime"
  if [[ -x "${venv_dir}/bin/ansible-playbook" ]]; then
    version="$("${venv_dir}/bin/ansible-playbook" --version 2>/dev/null | head -n1 || true)"
    minor="$(sed -nE 's/.*core 2\.([0-9]+).*/\1/p' <<< "${version}")"
    if [[ "${minor}" == "16" ]]; then
      printf '%s' "${venv_dir}/bin/ansible-playbook"
      return 0
    fi
    warn "Rebuilding unsupported AAP runtime at ${venv_dir}: ${version:-unknown version}." >&2
    rm -rf "${venv_dir}"
  fi

  candidate="$(command -v ansible-playbook -i "${SCRIPT_DIR}/aap_workflow_project/inventory/controller.ini" ${ANSIBLE_VERBOSITY:-} 2>/dev/null || true)"
  if [[ -n "${candidate}" ]]; then
    version="$(${candidate} --version 2>/dev/null | head -n1 || true)"
    minor="$(sed -nE 's/.*core 2\.([0-9]+).*/\1/p' <<< "${version}")"
    if [[ "${minor}" == "14" || "${minor}" == "16" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  fi

  if [[ "${AAP_AUTO_CREATE_ANSIBLE_VENV:-true}" != "true" ]]; then
    err "AAP 2.7 requires ansible-core 2.14 or 2.16. Set AAP_ANSIBLE_PLAYBOOK to a supported executable."
    return 1
  fi

  python_cmd="$(command -v python3.11 2>/dev/null || true)"
  if [[ -z "${python_cmd}" ]]; then
    err "python3.11 is required to create the isolated ansible-core 2.16 runtime."
    return 1
  fi

  log "Creating isolated ansible-core 2.16 runtime at ${venv_dir}."
  "${python_cmd}" -m venv "${venv_dir}"
  "${venv_dir}/bin/python" -m pip install --disable-pip-version-check \
    -r "${SCRIPT_DIR}/requirements-runtime.txt"
  printf '%s' "${venv_dir}/bin/ansible-playbook"
}

run_project_playbook() {
  local playbook="$1"
  local extra_vars_file="${2:-}"
  local ansible_playbook inventory config
  local -a command

  ansible_playbook="$(get_supported_ansible_playbook)" || return 1
  inventory="${SCRIPT_DIR}/aap_workflow_project/inventory/controller.ini"
  config="${SCRIPT_DIR}/aap_workflow_project/ansible.cfg"

  [[ -f "${inventory}" ]] || { err "Generated inventory not found: ${inventory}"; return 1; }
  [[ -f "${playbook}" ]] || { err "Project playbook not found: ${playbook}"; return 1; }

  # Ensure vault password file exists (create if missing) so playbooks can
  # encrypt/decrypt the shared env.yml without interactive prompts.
  if [[ -n "${VAULT_PASS_FILE:-}" ]]; then
    vault_dir="$(dirname "${VAULT_PASS_FILE}")"
    if [[ ! -d "${vault_dir}" ]]; then
      mkdir -p "${vault_dir}" && chmod 700 "${vault_dir}" || true
    fi
    if [[ ! -f "${VAULT_PASS_FILE}" ]]; then
      # Create a random 32-char alphanumeric vault password
      head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32 > "${VAULT_PASS_FILE}" || true
      chmod 600 "${VAULT_PASS_FILE}" || true
      log "Created vault password file: ${VAULT_PASS_FILE}"
    fi
  fi

  command=("${ansible_playbook}" -i "${inventory}")

  # Include repository-wide env file if present
  if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    command+=(--extra-vars "@${ENV_FILE}")
  fi

  # Pass vault password file when available to allow decrypting encrypted vars
  if [[ -n "${VAULT_PASS_FILE:-}" && -f "${VAULT_PASS_FILE}" ]]; then
    command+=(--vault-password-file "${VAULT_PASS_FILE}")
  fi

  command+=("${playbook}")
  if [[ -n "${extra_vars_file}" ]]; then
    command+=(--extra-vars "@${extra_vars_file}")
  fi

  (
    cd "${SCRIPT_DIR}/aap_workflow_project" || exit 1
    ANSIBLE_CONFIG="${config}" "${command[@]}"
  )
}
