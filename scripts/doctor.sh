#!/usr/bin/env bash
# ==============================================================================
# scripts/doctor.sh — Diagnóstico de Pré-requisitos do Host (Marco 0)
# Verifica KVM, grupos, libvirt, binários obrigatórios, espaço livre e ISO SHA256
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
LIBVIRT_IMAGES_DIR="${LIBVIRT_IMAGES_DIR:-/var/lib/libvirt/images}"
ISO_DIR="${ISO_DIR:-${REPO_ROOT}/isos}"
MIN_FREE_GIB="${MIN_FREE_GIB:-50}"

FAILURES=0
WARNINGS=0

if [[ -t 1 ]]; then
  C_RED='\033[0;31m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[1;33m'
  C_BLUE='\033[0;34m'
  C_BOLD='\033[1m'
  C_RESET='\033[0m'
else
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_BOLD=''
  C_RESET=''
fi

log_pass() { printf '%b[PASS]%b %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
log_warn() {
  printf '%b[WARN]%b %s\n' "${C_YELLOW}" "${C_RESET}" "$1"
  WARNINGS=$((WARNINGS + 1))
}
log_fail() {
  printf '%b[FAIL]%b %s\n' "${C_RED}" "${C_RESET}" "$1"
  FAILURES=$((FAILURES + 1))
}
log_section() { printf '\n%b%b==> %s%b\n' "${C_BLUE}" "${C_BOLD}" "$1" "${C_RESET}"; }

version_ge() {
  # Retorna 0 se $1 >= $2 usando ordenação semântica de versão
  local current="$1"
  local required="$2"
  [[ "$(printf '%s\n%s\n' "${required}" "${current}" | sort -V | head -n1)" == "${required}" ]]
}

check_kvm_and_groups() {
  log_section "1. Virtualização KVM e Permissões de Usuário"

  if [[ -c /dev/kvm ]]; then
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
      log_pass "/dev/kvm presente e acessível com leitura/escrita pelo usuário atual."
    else
      log_fail "/dev/kvm existe, mas o usuário '$(id -un)' não possui permissão rw."
    fi
  else
    log_fail "Dispositivo /dev/kvm não encontrado (verifique VT-x/AMD-V na BIOS/UEFI)."
  fi

  local user_groups
  user_groups=" $(id -nG) "

  for grp in kvm libvirt; do
    if [[ "${user_groups}" == *" ${grp} "* ]]; then
      log_pass "Usuário '$(id -un)' pertence ao grupo '${grp}'."
    else
      log_fail "Usuário '$(id -un)' NÃO pertence ao grupo '${grp}'."
    fi
  done
}

check_libvirt_host() {
  log_section "2. Validação do Hipervisor (virt-host-validate & qemu:///system)"

  if command -v virt-host-validate >/dev/null 2>&1; then
    local vhv_out
    if vhv_out="$(LC_ALL=C virt-host-validate qemu 2>&1)"; then
      log_pass "virt-host-validate qemu concluído sem falhas bloqueantes."
    else
      if printf '%s\n' "${vhv_out}" | grep -Eq ':[[:space:]]*FAIL'; then
        log_fail "virt-host-validate qemu reportou falha(s) crítica(s):"
        printf '%s\n' "${vhv_out}" | grep -E ':[[:space:]]*FAIL' | sed 's/^/       /'
      else
        log_warn "virt-host-validate qemu retornou código diferente de zero apenas com avisos."
      fi
    fi
  else
    log_fail "Binário 'virt-host-validate' ausente (pacote libvirt-clients)."
  fi

  if command -v virsh >/dev/null 2>&1; then
    if virsh -c "${LIBVIRT_URI}" uri >/dev/null 2>&1; then
      log_pass "Conexão sem sudo com '${LIBVIRT_URI}' validada."
    else
      log_fail "Não foi possível conectar a '${LIBVIRT_URI}' sem sudo."
      return
    fi

    if LC_ALL=C virsh -c "${LIBVIRT_URI}" net-info default >/dev/null 2>&1; then
      log_pass "Rede pré-existente 'default' (WAN) detectada e preservada."
    else
      log_warn "Rede libvirt 'default' não encontrada em '${LIBVIRT_URI}'."
    fi

    if LC_ALL=C virsh -c "${LIBVIRT_URI}" pool-info default >/dev/null 2>&1; then
      log_pass "Storage pool pré-existente 'default' detectado."
    else
      log_warn "Storage pool 'default' não encontrado em '${LIBVIRT_URI}'."
    fi
  fi
}

check_required_binaries() {
  log_section "3. Binários Obrigatórios da Stack IaC"

  local required_cmds=(tofu ansible virsh xorriso jq envsubst)
  for cmd in "${required_cmds[@]}"; do
    if command -v "${cmd}" >/dev/null 2>&1; then
      log_pass "Binário obrigatório '${cmd}' encontrado em $(command -v "${cmd}")."
    else
      log_fail "Binário obrigatório '${cmd}' NÃO encontrado no PATH."
    fi
  done

  if command -v tofu >/dev/null 2>&1; then
    local tofu_ver
    tofu_ver="$(tofu version -json 2>/dev/null | jq -r '.terraform_version // empty' || true)"
    if [[ -z "${tofu_ver}" ]]; then
      tofu_ver="$(tofu --version | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    fi
    if [[ -n "${tofu_ver}" ]] && version_ge "${tofu_ver}" "1.8.0"; then
      log_pass "Versão do OpenTofu compatível (${tofu_ver} >= 1.8.0)."
    elif [[ -n "${tofu_ver}" ]]; then
      log_fail "Versão do OpenTofu (${tofu_ver}) inferior ao mínimo exigido (1.8.0)."
    fi
  fi

  if command -v ansible >/dev/null 2>&1; then
    local ans_ver
    ans_ver="$(ansible --version | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    if [[ -n "${ans_ver}" ]] && version_ge "${ans_ver}" "2.17.0"; then
      log_pass "Versão do ansible-core compatível (${ans_ver} >= 2.17.0)."
    elif [[ -n "${ans_ver}" ]]; then
      log_fail "Versão do ansible-core (${ans_ver}) inferior ao mínimo exigido (2.17.0)."
    fi
  fi

  log_section "4. Ferramentas de Qualidade, Testes e Segurança"
  local quality_cmds=(shellcheck xmllint tflint checkov ansible-lint gitleaks bats pre-commit vim)
  for cmd in "${quality_cmds[@]}"; do
    if command -v "${cmd}" >/dev/null 2>&1; then
      log_pass "Ferramenta '${cmd}' disponível ($(command -v "${cmd}"))."
    else
      log_warn "Ferramenta '${cmd}' ainda não instalada (recomendada para lint/testes locais)."
    fi
  done
}

check_storage_space() {
  log_section "5. Espaço Livre em Disco (${LIBVIRT_IMAGES_DIR})"

  local target_dir="${LIBVIRT_IMAGES_DIR}"
  if [[ ! -e "${target_dir}" ]]; then
    target_dir="$(dirname "${target_dir}")"
  fi

  if [[ -e "${target_dir}" ]]; then
    local avail_kb avail_gib
    avail_kb="$(df -Pk "${target_dir}" | awk 'NR==2 {print $4}')"
    avail_gib=$((avail_kb / 1024 / 1024))
    if ((avail_gib >= MIN_FREE_GIB)); then
      log_pass "Espaço livre suficiente em '${target_dir}': ${avail_gib} GiB disponíveis (mínimo: ${MIN_FREE_GIB} GiB)."
    else
      log_fail "Espaço livre insuficiente em '${target_dir}': ${avail_gib} GiB disponíveis (mínimo: ${MIN_FREE_GIB} GiB)."
    fi
  else
    log_fail "Diretório de armazenamento '${LIBVIRT_IMAGES_DIR}' (e seu diretório pai) inexistente."
  fi
}

verify_iso_checksum_file() {
  local iso_file="$1"
  local iso_name
  iso_name="$(basename "${iso_file}")"
  local sha_file="${iso_file}.sha256"
  local sums_file="${ISO_DIR}/SHA256SUMS"

  local actual_hash
  actual_hash="$(sha256sum "${iso_file}" | awk '{print tolower($1)}')"

  local expected_hash=""
  if [[ -n "${PFSENSE_ISO_SHA256:-}" ]]; then
    expected_hash="$(printf '%s' "${PFSENSE_ISO_SHA256}" | tr '[:upper:]' '[:lower:]')"
  elif [[ -f "${sha_file}" ]]; then
    expected_hash="$(grep -Eo '[0-9a-fA-F]{64}' "${sha_file}" | head -n1 | tr '[:upper:]' '[:lower:]' || true)"
  elif [[ -f "${sums_file}" ]]; then
    expected_hash="$(grep -F "${iso_name}" "${sums_file}" | grep -Eo '[0-9a-fA-F]{64}' | head -n1 | tr '[:upper:]' '[:lower:]' || true)"
  fi

  if [[ -n "${expected_hash}" ]]; then
    if [[ "${actual_hash}" == "${expected_hash}" ]]; then
      log_pass "SHA256 verificado para '${iso_name}' (${actual_hash})."
    else
      log_fail "SHA256 INVÁLIDO para '${iso_name}'! Esperado: ${expected_hash} | Obtido: ${actual_hash}"
    fi
  else
    log_warn "Imagem '${iso_name}' encontrada sem arquivo '${iso_name}.sha256' ou SHA256SUMS. Hash calculado: ${actual_hash}"
  fi
}

check_pfsense_iso() {
  log_section "6. Artefatos de Instalação pfSense CE (${ISO_DIR})"

  if [[ ! -d "${ISO_DIR}" ]]; then
    log_warn "Diretório '${ISO_DIR}' ainda não existe (necessário a partir do Marco 3)."
    return
  fi

  local -a iso_files=()
  while IFS= read -r -d '' file; do
    iso_files+=("${file}")
  done < <(find "${ISO_DIR}" -maxdepth 1 -type f \( -name '*.iso' -o -name '*.img' \) -print0 | sort -z)

  if ((${#iso_files[@]} == 0)); then
    log_warn "Nenhuma imagem .iso/.img encontrada em '${ISO_DIR}' (necessária a partir do Marco 3)."
    return
  fi

  for iso_file in "${iso_files[@]}"; do
    verify_iso_checksum_file "${iso_file}"
  done
}

main() {
  printf '%bDiagnóstico de Ambiente — pfsense-kvm-iac%b\n' "${C_BOLD}" "${C_RESET}"
  printf 'Repositório : %s\n' "${REPO_ROOT}"
  printf 'Libvirt URI : %s\n' "${LIBVIRT_URI}"

  check_kvm_and_groups
  check_libvirt_host
  check_required_binaries
  check_storage_space
  check_pfsense_iso

  printf '\n============================================================\n'
  if ((FAILURES > 0)); then
    printf '%b%bRESULTADO: %d falha(s) crítica(s), %d aviso(s).%b\n' "${C_RED}" "${C_BOLD}" "${FAILURES}" "${WARNINGS}" "${C_RESET}"
    printf "Corrija os itens marcados como [FAIL] (edite configurações locais com 'vim' se necessário) e reexecute 'make doctor'.\n"
    exit 1
  fi

  printf '%b%bRESULTADO: Ambiente aprovado (%d falha(s), %d aviso(s)).%b\n' "${C_GREEN}" "${C_BOLD}" "${FAILURES}" "${WARNINGS}" "${C_RESET}"
}

main "$@"
