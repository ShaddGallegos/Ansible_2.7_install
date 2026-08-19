#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT_DIR}"

mapfile -d '' tracked_files < <(
  git ls-files -z --cached --others --exclude-standard -- \
    '*.sh' '*.yml' '*.yaml' '*.ini' '*.example' '*.md' \
    ':(exclude)tests/check_repository_hygiene.sh' \
    ':(exclude)roles/aap27_menu_installer/files/collection_patches/**' \
    ':(exclude)roles/aap27_menu_installer/files/collection_patch_candidates/**'
)

failures=0

check_forbidden_pattern() {
  local description="$1"
  local pattern="$2"
  local matches

  matches="$(grep -InE "${pattern}" "${tracked_files[@]}" 2>/dev/null || true)"
  if [[ -n "${matches}" ]]; then
    printf '[FAIL] %s\n%s\n' "${description}" "${matches}"
    failures=$((failures + 1))
  else
    printf '[ OK ] %s\n' "${description}"
  fi
}

check_forbidden_pattern \
  "No known credential/token formats are committed" \
  'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |OPENSSH )?PRIVATE KEY-----'

check_forbidden_pattern \
  "No developer-specific identities or private-network examples are committed" \
  '/home/sgallego|shadd@redhat\.com|kaso\.prod\.spg|aap\.prod\.spg|192\.168\.'

check_forbidden_pattern \
  "No obvious literal credential values are committed" \
  '^[[:space:]]*([A-Za-z0-9_]+_)?(password|token|secret|api_key)[[:space:]]*:[[:space:]]+[A-Za-z0-9][A-Za-z0-9._@/-]*[[:space:]]*$'

if [[ "${failures}" -ne 0 ]]; then
  printf '\nRepository hygiene checks failed: %s\n' "${failures}"
  exit 1
fi

printf '\nRepository hygiene checks passed.\n'
