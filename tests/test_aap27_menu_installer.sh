#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export ROOT_DIR
# shellcheck disable=SC1091
source "${ROOT_DIR}/aap27_menu_installer.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

cat >"${tmpdir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_SSH_LOG}"
stdin_payload=""
if [[ -p /dev/stdin ]]; then
  stdin_payload="$(cat)"
  printf '%s' "${stdin_payload}" > "${TEST_SSH_STDIN_LOG}"
else
  : > "${TEST_SSH_STDIN_LOG}"
fi
if [[ "${TEST_REMOTE_FAIL_DOWNLOAD:-0}" == "1" ]]; then
  if [[ "${stdin_payload}" == *"REMOTE_BUNDLE_PATH="* ]]; then
    exit 1
  fi
fi
if [[ "${TEST_REMOTE_FAIL_EXISTING_BUNDLE:-0}" == "1" ]]; then
  if [[ "$*" == *"tar -tzf"* ]] && [[ "$*" == *"/home/admin/Downloads/"* ]]; then
    exit 1
  fi
  if [[ "$*" == *"test -d"* ]] && [[ "$*" == *"inventory-growth"* ]]; then
    exit 1
  fi
fi
if [[ "${TEST_REMOTE_EMIT_CHECKSUM:-0}" == "1" ]]; then
  if [[ "$*" == *"sha256sum"* ]] && [[ "$*" == *"/home/admin/Downloads/"* ]]; then
    if [[ -n "${TEST_REMOTE_BUNDLE_SHA256:-}" ]]; then
      printf '%s\n' "${TEST_REMOTE_BUNDLE_SHA256}"
    fi
    exit 0
  fi
fi
if [[ "${TEST_REMOTE_FAIL_BOOTSTRAP:-0}" == "1" ]]; then
  if [[ "$*" == *"root@${TEST_REMOTE_IP}"* ]]; then
    exit 1
  fi
fi
if [[ "${TEST_REMOTE_FAIL_ADMIN:-0}" == "1" ]]; then
  if [[ "$*" == *"admin@${TEST_REMOTE_IP}"* ]]; then
    exit 1
  fi
fi
exit 0
EOF
chmod +x "${tmpdir}/ssh"

cat >"${tmpdir}/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target_host="${!#}"
printf '%s ssh-ed25519 AAAAnewkey\n' "${target_host}"
EOF
chmod +x "${tmpdir}/ssh-keyscan"

cat >"${tmpdir}/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_SCP_LOG}"
if [[ "${TEST_SCP_FAIL:-0}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "${tmpdir}/scp"

export PATH="${tmpdir}:${PATH}"
export TEST_SSH_LOG="${tmpdir}/ssh.log"
export TEST_SSH_STDIN_LOG="${tmpdir}/ssh.stdin.log"
export TEST_SCP_LOG="${tmpdir}/scp.log"
export AAP_INSTALL_SCOPE="remote"
export AAP_REMOTE_USER="sgallego"
export HOME="${tmpdir}"
export ENV_FILE="${HOME}/.ansible/conf/env.yml"
mkdir -p "${HOME}/.ssh"
REMOTE_IP_TEST_OCTET="$(cksum <<<"${ROOT_DIR}" | awk '{print ($1 % 200) + 1}')"
REMOTE_IP_TEST_VALUE="192.168.122.${REMOTE_IP_TEST_OCTET}"
printf '%s ssh-ed25519 AAAAoldkey\n' "${REMOTE_IP_TEST_VALUE}" > "${HOME}/.ssh/known_hosts"
BUNDLE_URL_ERROR_TEST_VALUE="https://access.redhat.com/downloads/content/error?code=403&uri=/content/origin/files/sha256/e5/e554eb7fa63caad0ed756e458e2909f211839d2031ee27df742b18fb3800eb53/ansible-automation-platform-containerized-setup-bundle-2.7-3-x86_64.tar.gz"
save_env_kv "AAP_REMOTE_IP" "${REMOTE_IP_TEST_VALUE}"
save_env_kv "BUNDLE_URL" "${BUNDLE_URL_ERROR_TEST_VALUE}"

RHSM_PASSWORD_TEST_VALUE="$(openssl rand -base64 18 | tr -d '/+=[:space:]' | cut -c1-18)"
AAP_REMOTE_PASSWORD_TEST_VALUE="$(openssl rand -base64 18 | tr -d '/+=[:space:]' | cut -c1-18)"
RHSM_OFFLINE_TOKEN_TEST_VALUE="$(openssl rand -base64 24 | tr -d '/+=[:space:]')"
save_env_kv "RHSM_PASSWORD" "${RHSM_PASSWORD_TEST_VALUE}"
save_env_kv "AAP_REMOTE_PASSWORD" "${AAP_REMOTE_PASSWORD_TEST_VALUE}"
save_env_kv "RHSM_OFFLINE_TOKEN" "${RHSM_OFFLINE_TOKEN_TEST_VALUE}"

(
  export AAP_INSTALL_SCOPE="local"
  unset AAP_CONTROLLER_IP AAP_REMOTE_IP REMOTE_IP AAP_REMOTE_HOST REMOTE_HOST AAP_CONTROLLER_FQDN
  if is_remote_install_scope; then
    echo "local scope incorrectly inferred remote mode" >&2
    exit 1
  fi
)

save_env_kv "TEST_VALUE" '$HOME'
load_env
if [[ "${TEST_VALUE:-}" != '$HOME' ]]; then
  echo "env values were not preserved literally" >&2
  exit 1
fi
RHSM_PASSWORD_FIXTURE="${RHSM_PASSWORD:-}"
BUNDLE_URL_ERROR_FIXTURE="${BUNDLE_URL:-}"
AAP_REMOTE_IP_FIXTURE="${AAP_REMOTE_IP:-}"
AAP_REMOTE_PASSWORD_FIXTURE="${AAP_REMOTE_PASSWORD:-}"
RHSM_OFFLINE_TOKEN_FIXTURE="${RHSM_OFFLINE_TOKEN:-}"
export TEST_REMOTE_IP="${AAP_REMOTE_IP_FIXTURE:-}"

export AAP_INSTALL_SCOPE="local"
export DOWNLOAD_DIR="${tmpdir}/url-guard"
mkdir -p "${DOWNLOAD_DIR}"
BUNDLE_URL="${BUNDLE_URL_ERROR_FIXTURE}"
if download_bundle; then
  echo "download_bundle accepted a Red Hat error-page URL" >&2
  exit 1
fi

export AAP_INSTALL_SCOPE="remote"
export AAP_REMOTE_USER="sgallego"
export AAP_REMOTE_PASSWORD="${AAP_REMOTE_PASSWORD_FIXTURE:-}"
export AAP_REMOTE_IP="${AAP_REMOTE_IP_FIXTURE:-}"

ensure_admin_user_exists

if [[ ! -f "${TEST_SSH_LOG}" ]]; then
  echo "expected ssh invocation log" >&2
  exit 1
fi

if ! grep -q "${TEST_REMOTE_IP}" "${TEST_SSH_LOG}"; then
  echo "remote target host was not passed to ssh" >&2
  exit 1
fi
if ! grep -q 'NOPASSWD: ALL' "${TEST_SSH_LOG}"; then
  echo "remote provisioning did not configure passwordless sudo for admin" >&2
  exit 1
fi
if ! grep -q '/home/admin/Downloads' "${TEST_SSH_LOG}"; then
  echo "remote provisioning did not create the admin Downloads directory" >&2
  exit 1
fi
if ! grep -q 'chown -R admin:admin /home/admin' "${TEST_SSH_LOG}"; then
  echo "remote provisioning did not set home ownership for admin" >&2
  exit 1
fi
if grep -q 'tee -a /home/admin/.ssh/authorized_keys' "${TEST_SSH_LOG}"; then
  echo "remote provisioning still appends to authorized_keys instead of replacing it" >&2
  exit 1
fi
if ! grep -q 'authorized_keys' "${TEST_SSH_LOG}"; then
  echo "remote provisioning did not update authorized_keys" >&2
  exit 1
fi
if grep -q 'AAAAoldkey' "${HOME}/.ssh/known_hosts"; then
  echo "old host key was not removed from known_hosts" >&2
  exit 1
fi
if ! grep -q 'AAAAnewkey' "${HOME}/.ssh/known_hosts"; then
  echo "new host key was not written to known_hosts" >&2
  exit 1
fi

ensure_user_home_ownership admin
if ! grep -q 'chown -R admin:admin' "${TEST_SSH_LOG}"; then
  echo "remote home ownership repair did not run ownership fix" >&2
  exit 1
fi

cat >"${tmpdir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -L)
      shift
      ;;
    *)
      shift
      ;;
  esac
done
if [[ -z "${output}" ]]; then
  echo "curl missing output path" >&2
  exit 1
fi
mkdir -p "$(dirname "${output}")"
tar -czf "${output}" -C "${ROOT_DIR}" aap27_menu_installer.sh >/dev/null 2>&1
EOF
chmod +x "${tmpdir}/curl"

export PATH="${tmpdir}:${PATH}"
export DOWNLOAD_DIR="${tmpdir}/downloads"
mkdir -p "${DOWNLOAD_DIR}"
printf 'not an archive\n' >"${DOWNLOAD_DIR}/${BUNDLE_FILE}"
export AAP_INSTALL_SCOPE="local"
BUNDLE_URL="https://example.invalid/bundle.tar.gz"
download_bundle
if ! tar -tzf "${DOWNLOAD_DIR}/${BUNDLE_FILE}" >/dev/null 2>&1; then
  echo "download_bundle did not replace the invalid archive" >&2
  exit 1
fi

mkdir -p "${HOME}/Downloads"
cp -f "${DOWNLOAD_DIR}/${BUNDLE_FILE}" "${HOME}/Downloads/${BUNDLE_FILE}"

export TEST_REMOTE_FAIL_BOOTSTRAP=1
export TEST_REMOTE_FAIL_ADMIN=1
export AAP_REMOTE_BOOTSTRAP_USER="root"
export AAP_REMOTE_USER="sgallego"
: > "${TEST_SSH_LOG}"
if ! ensure_admin_user_exists; then
  echo "remote admin provisioning fallback failed" >&2
  exit 1
fi

(
  export AAP_INSTALL_SCOPE="local"
  export AAP_INTERACTIVE_MODE="manual"
  export ENV_FILE="${tmpdir}/initial-prompts.env"
  unset BUNDLE_URL RHSM_USERNAME RHSM_PASSWORD RHSM_OFFLINE_TOKEN
  prompt_for_value() {
    local var_name="$1"
    local prompt_message="$2"
    local default_value="${3:-}"
    case "${var_name}" in
      RHSM_USERNAME)
        printf -v "${var_name}" '%s' "test-rhsm-user"
        ;;
      BUNDLE_URL)
        printf -v "${var_name}" '%s' "https://example.invalid/override.tar.gz"
        ;;
      AAP_REMOTE_USER)
        printf -v "${var_name}" '%s' "admin"
        ;;
      AAP_REMOTE_BOOTSTRAP_USER)
        printf -v "${var_name}" '%s' "root"
        ;;
      *)
        printf -v "${var_name}" '%s' "${default_value}"
        ;;
    esac
    return 0
  }
  read_secret_prompt() {
    local var_name="$1"
    local prompt_message="$2"
    local value=""
    case "${var_name}" in
      RHSM_PASSWORD)
        value="${RHSM_PASSWORD_FIXTURE:-}"
        ;;
      RHSM_OFFLINE_TOKEN)
        value="${RHSM_OFFLINE_TOKEN_FIXTURE:-}"
        ;;
      AAP_REMOTE_PASSWORD)
        value="${AAP_REMOTE_PASSWORD_FIXTURE:-}"
        ;;
    esac
    printf -v "${var_name}" '%s' "${value}"
  }
  prompt_for_missing_runtime_settings
  load_env
  if [[ "${RHSM_USERNAME:-}" != "test-rhsm-user" ]]; then
    echo "RHSM username was not stored from initial prompts" >&2
    exit 1
  fi
  if [[ "${RHSM_PASSWORD:-}" != "${RHSM_PASSWORD_FIXTURE:-}" ]]; then
    echo "RHSM password was not stored from initial prompts" >&2
    exit 1
  fi
  if [[ "${RHSM_OFFLINE_TOKEN:-}" != "${RHSM_OFFLINE_TOKEN_FIXTURE:-}" ]]; then
    echo "offline token was not stored from initial prompts" >&2
    exit 1
  fi
  if [[ "${BUNDLE_URL:-}" != "https://example.invalid/override.tar.gz" ]]; then
    echo "bundle URL was not stored from initial prompts" >&2
    exit 1
  fi
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "initial prompts did not write to the env file" >&2
    exit 1
  fi
)

export AAP_INSTALL_SCOPE="remote"
export AAP_REMOTE_USER="sgallego"
export AAP_REMOTE_PASSWORD="${AAP_REMOTE_PASSWORD_FIXTURE:-}"
export AAP_REMOTE_IP="${AAP_REMOTE_IP_FIXTURE:-}"
export AAP_REMOTE_BOOTSTRAP_USER="root"
unset TEST_REMOTE_FAIL_BOOTSTRAP TEST_REMOTE_FAIL_ADMIN
unset DOWNLOAD_DIR
: > "${TEST_SSH_LOG}"
if ! download_bundle; then
  echo "remote bundle download failed" >&2
  exit 1
fi
if ! grep -q '/home/admin/Downloads' "${TEST_SSH_LOG}"; then
  echo "remote bundle download did not target the admin Downloads directory" >&2
  exit 1
fi

export TEST_REMOTE_FAIL_DOWNLOAD=1
export TEST_REMOTE_FAIL_EXISTING_BUNDLE=1
: > "${TEST_SSH_LOG}"
: > "${TEST_SCP_LOG}"
if ! download_bundle; then
  echo "remote bundle fallback did not upload controller bundle from ~/Downloads" >&2
  exit 1
fi
if ! grep -q "admin@${AAP_REMOTE_IP}:/home/admin/Downloads/${BUNDLE_FILE}" "${TEST_SCP_LOG}"; then
  echo "remote bundle fallback did not scp bundle to remote admin Downloads" >&2
  exit 1
fi
if ! grep -q "tar -xzf" "${TEST_SSH_LOG}" || ! grep -q "/home/admin/Downloads/${BUNDLE_FILE}" "${TEST_SSH_LOG}"; then
  echo "remote bundle fallback did not untar uploaded bundle on remote host" >&2
  exit 1
fi
if ! download_bundle; then
  echo "remote bundle fallback rerun was not idempotent" >&2
  exit 1
fi
unset TEST_REMOTE_FAIL_DOWNLOAD
unset TEST_REMOTE_FAIL_EXISTING_BUNDLE

export TEST_REMOTE_FAIL_DOWNLOAD=1
export TEST_REMOTE_FAIL_EXISTING_BUNDLE=1
export TEST_REMOTE_EMIT_CHECKSUM=1
export TEST_REMOTE_BUNDLE_SHA256="$(sha256sum "${HOME}/Downloads/${BUNDLE_FILE}" | awk '{print $1}')"
: > "${TEST_SSH_LOG}"
: > "${TEST_SCP_LOG}"
if ! download_bundle; then
  echo "remote bundle checksum fallback failed" >&2
  exit 1
fi
if [[ -s "${TEST_SCP_LOG}" ]]; then
  echo "remote bundle checksum fallback should skip scp when checksums match" >&2
  exit 1
fi
if ! grep -q "tar -xzf" "${TEST_SSH_LOG}" || ! grep -q "/home/admin/Downloads/${BUNDLE_FILE}" "${TEST_SSH_LOG}"; then
  echo "remote bundle checksum fallback did not untar matching remote bundle" >&2
  exit 1
fi
unset TEST_REMOTE_FAIL_DOWNLOAD
unset TEST_REMOTE_FAIL_EXISTING_BUNDLE
unset TEST_REMOTE_EMIT_CHECKSUM
unset TEST_REMOTE_BUNDLE_SHA256


echo "remote admin provisioning test passed"
echo "remote admin provisioning fallback test passed"
echo "bundle download recovery test passed"
echo "initial prompt persistence test passed"
echo "remote bundle path test passed"
echo "remote bundle fallback test passed"
echo "remote bundle checksum skip-scp test passed"
