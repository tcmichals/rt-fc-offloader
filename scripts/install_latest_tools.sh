#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="${TOOLS_DIR:-${HOME}/.tools}"
TMP_DIR="$(mktemp -d)"
HOST_OS=""
HOST_ARCH=""
ARM_HOST_ARTIFACT_REGEX=""
OSS_CAD_ASSET_REGEX=""
RISCV_XPACK_ASSET_REGEX=""
FORCE_INSTALL=false

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

log() {
  echo "[install-tools] $*"
}

fail() {
  echo "[install-tools] ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [TOOL...]

Install or update development toolchains into ${TOOLS_DIR}.
Default: check all tools and update only if a newer version is available.

TOOLS (default: all):
  oss-cad     OSS CAD Suite  (Yosys, nextpnr-gowin, icestorm, ...)
  arm         Arm GNU Toolchain (arm-none-eabi-gcc with nano.specs)
  riscv       xPack RISC-V GCC  (riscv-none-elf-gcc with nano.specs)
  pico-sdk    Raspberry Pi Pico SDK (source, cloned recursively)

OPTIONS:
  --force     Skip version check; re-download and reinstall regardless
  -h, --help  Show this help message

ENVIRONMENT:
  TOOLS_DIR     Install root directory (default: ~/.tools)
  ARM_GNU_URL   Override Arm GNU toolchain download URL
  PICO_SDK_TIMEOUT_SEC  Timeout for each Pico git step (default: 900)

Examples:
  $(basename "$0")               # Check and update all tools
  $(basename "$0") arm riscv     # Check/update specific tools only
  $(basename "$0") --force       # Force-reinstall all tools
  $(basename "$0") --force arm   # Force-reinstall Arm toolchain only
EOF
}

need_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required command: ${cmd}"
}

run_with_optional_timeout() {
  # Run a command with GNU timeout when available; otherwise run normally.
  # Usage: run_with_optional_timeout <seconds> <command> [args...]
  local timeout_s="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "${timeout_s}" "$@"
  else
    "$@"
  fi
}

need_cmd curl
need_cmd tar
need_cmd grep
need_cmd sed
need_cmd find

mkdir -p "${TOOLS_DIR}"

validate_nano_specs() {
  local gcc_path="$1"
  local label="$2"
  local nano_path

  [[ -x "${gcc_path}" ]] || fail "${label} compiler not found at ${gcc_path}"

  nano_path="$(${gcc_path} -print-file-name=nano.specs 2>/dev/null || true)"
  if [[ -z "${nano_path}" || "${nano_path}" == "nano.specs" ]]; then
    fail "${label} does not provide nano.specs (${gcc_path})"
  fi

  log "Verified ${label} nano.specs -> ${nano_path}"
}

detect_host_platform() {
  local uname_s
  local uname_m

  uname_s="$(uname -s | tr '[:upper:]' '[:lower:]')"
  uname_m="$(uname -m | tr '[:upper:]' '[:lower:]')"

  case "${uname_s}" in
    linux*) HOST_OS="linux" ;;
    msys*|mingw*|cygwin*) HOST_OS="windows" ;;
    *) fail "Unsupported host OS '${uname_s}'. Use Linux or Windows via Git Bash/MSYS2." ;;
  esac

  case "${uname_m}" in
    x86_64|amd64) HOST_ARCH="x64" ;;
    aarch64|arm64) HOST_ARCH="arm64" ;;
    *) fail "Unsupported host architecture '${uname_m}'." ;;
  esac

  if [[ "${HOST_OS}" == "linux" && "${HOST_ARCH}" == "x64" ]]; then
    ARM_HOST_ARTIFACT_REGEX='-x86_64-arm-none-eabi\.tar\.xz$'
    OSS_CAD_ASSET_REGEX='oss-cad-suite-linux-x64.*\.(tgz|tar\.gz)$'
    RISCV_XPACK_ASSET_REGEX='xpack-riscv-none-elf-gcc-.*-linux-x64\.tar\.gz$'
  elif [[ "${HOST_OS}" == "linux" && "${HOST_ARCH}" == "arm64" ]]; then
    ARM_HOST_ARTIFACT_REGEX='-aarch64-arm-none-eabi\.tar\.xz$'
    OSS_CAD_ASSET_REGEX='oss-cad-suite-linux-arm64.*\.(tgz|tar\.gz)$'
    RISCV_XPACK_ASSET_REGEX='xpack-riscv-none-elf-gcc-.*-linux-arm64\.tar\.gz$'
  elif [[ "${HOST_OS}" == "windows" && "${HOST_ARCH}" == "x64" ]]; then
    ARM_HOST_ARTIFACT_REGEX='-mingw-w64-x86_64-arm-none-eabi\.zip$'
    OSS_CAD_ASSET_REGEX='oss-cad-suite-windows-x64.*\.zip$'
    RISCV_XPACK_ASSET_REGEX='xpack-riscv-none-elf-gcc-.*-win32-x64\.zip$'
  else
    fail "Unsupported host combination '${HOST_OS}/${HOST_ARCH}' for automatic downloads."
  fi
}

fetch_latest_github_asset_url() {
  local repo="$1"
  local asset_regex="$2"
  local api_url="https://api.github.com/repos/${repo}/releases/latest"
  local body
  local url

  body="$(curl -fsSL "${api_url}")" || fail "Failed to query GitHub releases for ${repo}"

  url="$(printf '%s\n' "${body}" \
    | grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"(https:[^"]+)"$/\1/' \
    | grep -E -- "${asset_regex}" \
    | head -n 1 || true)"

  [[ -n "${url}" ]] || fail "Could not find asset matching '${asset_regex}' in ${repo} latest release"
  printf '%s\n' "${url}"
}

download_to() {
  local url="$1"
  local out="$2"
  log "Downloading: ${url}"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "${out}" "${url}" \
    || fail "Download failed: ${url}"
}

install_archive_to_target_dir() {
  local archive="$1"
  local target_dir="$2"
  local unpack_dir
  local root

  unpack_dir="${TMP_DIR}/unpack-$(basename "${target_dir}")"
  rm -rf "${unpack_dir}"
  mkdir -p "${unpack_dir}"

  if [[ "${archive}" == *.zip ]]; then
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "${archive}" -d "${unpack_dir}" || fail "Failed to extract ${archive}"
    elif command -v bsdtar >/dev/null 2>&1; then
      bsdtar -xf "${archive}" -C "${unpack_dir}" || fail "Failed to extract ${archive}"
    else
      fail "ZIP extraction requires 'unzip' or 'bsdtar' on this host"
    fi
  else
    tar -xf "${archive}" -C "${unpack_dir}" || fail "Failed to extract ${archive}"
  fi

  root="$(find "${unpack_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
  [[ -n "${root}" ]] || fail "Archive ${archive} did not contain an expected top-level directory"

  rm -rf "${target_dir}"
  mv "${root}" "${target_dir}"
}

find_latest_arm_url() {
  local page_url="https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads"
  local page
  local url

  if [[ -n "${ARM_GNU_URL:-}" ]]; then
    printf '%s\n' "${ARM_GNU_URL}"
    return 0
  fi

  page="$(curl -fsSL "${page_url}" || true)"
  [[ -n "${page}" ]] || return 1

  # Try absolute links first.
  url="$(printf '%s\n' "${page}" \
    | grep -Eo 'https://[^"[:space:]]*arm-gnu-toolchain-[0-9][^"[:space:]]*\.(zip|tar\.xz)' \
    | grep -E -- "${ARM_HOST_ARTIFACT_REGEX}" \
    | head -n 1 || true)"

  if [[ -n "${url}" ]]; then
    printf '%s\n' "${url}"
    return 0
  fi

  # Then relative links from Arm media endpoints.
  url="$(printf '%s\n' "${page}" \
    | grep -Eo '/-/media/Files/downloads/gnu/[0-9][^"[:space:]]*arm-gnu-toolchain-[0-9][^"[:space:]]*\.(zip|tar\.xz)' \
    | grep -E -- "${ARM_HOST_ARTIFACT_REGEX}" \
    | head -n 1 || true)"

  if [[ -n "${url}" ]]; then
    printf 'https://developer.arm.com%s\n' "${url}"
    return 0
  fi

  return 1
}

create_riscv_prefix_compat_symlinks() {
  local bin_dir="$1"
  local f
  local base
  local compat

  [[ -d "${bin_dir}" ]] || return 0

  while IFS= read -r -d '' f; do
    base="$(basename "${f}")"
    compat="${base/riscv-none-elf-/riscv64-unknown-elf-}"

    if [[ "${compat}" != "${base}" && ! -e "${bin_dir}/${compat}" ]]; then
      if ! ln -s "${base}" "${bin_dir}/${compat}" 2>/dev/null; then
        cp "${f}" "${bin_dir}/${compat}"
      fi
    fi
  done < <(find "${bin_dir}" -maxdepth 1 -type f -name 'riscv-none-elf-*' -print0)
}

# ---------------------------------------------------------------------------
# Version tracking helpers
# ---------------------------------------------------------------------------

read_installed_version() {
  local target_dir="$1"
  local ver_file="${target_dir}/.installed-version"
  if [[ -f "${ver_file}" ]]; then
    cat "${ver_file}"
  else
    printf ''
  fi
}

write_installed_version() {
  local target_dir="$1"
  local version="$2"
  mkdir -p "${target_dir}"
  printf '%s\n' "${version}" > "${target_dir}/.installed-version"
}

fetch_latest_github_release_tag() {
  local repo="$1"
  local api_url="https://api.github.com/repos/${repo}/releases/latest"
  local body tag

  body="$(curl -fsSL "${api_url}")" || fail "Failed to query GitHub releases for ${repo}"
  tag="$(printf '%s\n' "${body}" \
    | grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/' \
    | head -n 1 || true)"

  [[ -n "${tag}" ]] || fail "Could not find tag_name in ${repo} latest release"
  printf '%s\n' "${tag}"
}

# Returns 0 (true) if already up-to-date → caller should skip.
# Returns 1 (false) if install/update is needed.
check_up_to_date() {
  local label="$1"
  local target_dir="$2"
  local latest_version="$3"
  local installed_version

  if [[ "${FORCE_INSTALL}" == "true" ]]; then
    log "${label}: --force specified; reinstalling ${latest_version}"
    return 1
  fi

  installed_version="$(read_installed_version "${target_dir}")"
  if [[ -n "${installed_version}" && "${installed_version}" == "${latest_version}" ]]; then
    log "${label}: already up-to-date (${latest_version}) — skipping (use --force to reinstall)"
    return 0
  fi

  if [[ -n "${installed_version}" ]]; then
    log "${label}: installed=${installed_version}  latest=${latest_version} → updating"
  else
    log "${label}: not installed → installing ${latest_version}"
  fi
  return 1
}

install_oss_cad_python_extras() {
  # Install apycula performance-critical Python packages into OSS CAD Suite's
  # own Python interpreter.  These are optional but eliminate the gowin_pack
  # "performance will be degraded" warnings.
  # Always runs (even when the suite version is already up-to-date) so pip can
  # self-heal if packages were missing after a previous install.
  local pip3="${TOOLS_DIR}/oss-cad-suite/py3bin/pip3"
  local packages=(numpy msgspec fastcrc)

  if [[ ! -x "${pip3}" ]]; then
    log "OSS CAD python extras: pip3 not found at ${pip3}, skipping"
    return 0
  fi

  log "OSS CAD python extras: ensuring ${packages[*]} are installed"
  # Install into OSS CAD Suite's own Python runtime (used by gowin_pack).
  # Keep output quiet to avoid noisy deprecation spam from bundled eggs.
  if ! PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "${pip3}" install --quiet --no-input --no-warn-script-location \
    "${packages[@]}" >/dev/null 2>&1; then
    log "WARNING: some OSS CAD python extras failed to install — gowin_pack performance may be degraded"
  fi

  for pkg in "${packages[@]}"; do
    if "${TOOLS_DIR}/oss-cad-suite/py3bin/python3" -c "import ${pkg}" 2>/dev/null; then
      log "  [ok] ${pkg}"
    else
      log "  [missing] ${pkg} — gowin_pack will warn about degraded performance"
    fi
  done
}

install_oss_cad_suite() {
  local url
  local archive_ext
  local archive
  local target="${TOOLS_DIR}/oss-cad-suite"
  local tag

  tag="$(fetch_latest_github_release_tag "YosysHQ/oss-cad-suite-build")"
  if ! check_up_to_date "OSS CAD Suite" "${target}" "${tag}"; then
    url="$(fetch_latest_github_asset_url \
      "YosysHQ/oss-cad-suite-build" \
      "${OSS_CAD_ASSET_REGEX}")"

    archive_ext="${url##*.}"
    archive="${TMP_DIR}/oss-cad-suite.${archive_ext}"

    download_to "${url}" "${archive}"
    install_archive_to_target_dir "${archive}" "${target}"

    [[ -x "${target}/bin/yosys" ]] || fail "OSS CAD install missing expected binary: ${target}/bin/yosys"
    write_installed_version "${target}" "${tag}"
    log "Installed OSS CAD Suite ${tag} -> ${target}"
  fi

  # Always ensure the Python performance extras are present.
  install_oss_cad_python_extras
}

install_riscv_xpack() {
  local url
  local archive_ext
  local archive
  local target="${TOOLS_DIR}/gcc-riscv-none-eabi"
  local tag

  tag="$(fetch_latest_github_release_tag "xpack-dev-tools/riscv-none-elf-gcc-xpack")"
  check_up_to_date "xPack RISC-V GCC" "${target}" "${tag}" && return 0

  url="$(fetch_latest_github_asset_url \
    "xpack-dev-tools/riscv-none-elf-gcc-xpack" \
    "${RISCV_XPACK_ASSET_REGEX}")"

  archive_ext="${url##*.}"
  archive="${TMP_DIR}/riscv-xpack.${archive_ext}"

  download_to "${url}" "${archive}"
  install_archive_to_target_dir "${archive}" "${target}"
  create_riscv_prefix_compat_symlinks "${target}/bin"

  if [[ -x "${target}/bin/riscv64-unknown-elf-gcc" ]]; then
    validate_nano_specs "${target}/bin/riscv64-unknown-elf-gcc" "RISC-V GCC"
    write_installed_version "${target}" "${tag}"
    log "Installed xPack RISC-V GCC ${tag} -> ${target} (riscv64-unknown-elf-* compatibility links created)"
  elif [[ -x "${target}/bin/riscv-none-elf-gcc" ]]; then
    validate_nano_specs "${target}/bin/riscv-none-elf-gcc" "RISC-V GCC"
    write_installed_version "${target}" "${tag}"
    log "Installed xPack RISC-V GCC ${tag} -> ${target}"
  else
    fail "RISC-V install missing expected compiler in ${target}/bin"
  fi
}

install_arm_gnu() {
  local url
  local archive
  local target="${TOOLS_DIR}/gcc-arm-none-eabi"
  local arm_ver

  if ! url="$(find_latest_arm_url)"; then
    fail "Could not resolve latest Arm GNU toolchain URL automatically. Re-run with ARM_GNU_URL set to a host-appropriate arm-none-eabi archive URL from Arm Developer downloads."
  fi

  # Extract version token from filename, e.g. "14.2.rel1" from arm-gnu-toolchain-14.2.rel1-x86_64-...
  arm_ver="$(basename "${url}" | sed -E 's/arm-gnu-toolchain-([0-9][^-]+)-.*/\1/')"
  [[ -n "${arm_ver}" ]] || arm_ver="$(basename "${url}")"

  check_up_to_date "Arm GNU Toolchain" "${target}" "${arm_ver}" && return 0

  if [[ "${url}" == *.zip ]]; then
    archive="${TMP_DIR}/arm-gnu.zip"
  else
    archive="${TMP_DIR}/arm-gnu.tar.xz"
  fi

  download_to "${url}" "${archive}"
  install_archive_to_target_dir "${archive}" "${target}"

  [[ -x "${target}/bin/arm-none-eabi-gcc" ]] || fail "Arm install missing expected binary: ${target}/bin/arm-none-eabi-gcc"
  validate_nano_specs "${target}/bin/arm-none-eabi-gcc" "Arm GCC"
  write_installed_version "${target}" "${arm_ver}"
  log "Installed Arm GNU Toolchain ${arm_ver} -> ${target}"
}

install_pico_sdk() {
  local target="${TOOLS_DIR}/pico-sdk"
  local tag
  local submodule_jobs="${PICO_SDK_SUBMODULE_JOBS:-8}"
  local timeout_s="${PICO_SDK_TIMEOUT_SEC:-900}"
  local existing_tag=""

  need_cmd git

  tag="$(fetch_latest_github_release_tag "raspberrypi/pico-sdk")"

  # Backward-compat: if an older install exists without .installed-version,
  # detect the checked-out tag and adopt it.
  if [[ ! -f "${target}/.installed-version" && -d "${target}/.git" ]]; then
    existing_tag="$(git -C "${target}" describe --tags --exact-match 2>/dev/null || true)"
    if [[ -n "${existing_tag}" ]]; then
      write_installed_version "${target}" "${existing_tag}"
      log "Pico SDK: detected existing checkout at tag ${existing_tag}; wrote .installed-version"
    fi
  fi

  check_up_to_date "Pico SDK" "${target}" "${tag}" && return 0

  log "Cloning Pico SDK ${tag} -> ${target} (timeout=${timeout_s}s)"
  rm -rf "${target}"
  if ! GIT_TERMINAL_PROMPT=0 \
    run_with_optional_timeout "${timeout_s}" \
    git -c advice.detachedHead=false clone \
      --depth=1 \
      --branch "${tag}" \
      --single-branch \
      --filter=blob:none \
      "https://github.com/raspberrypi/pico-sdk.git" \
      "${target}"; then
    fail "Failed to clone Pico SDK ${tag} (timed out or network/auth issue)"
  fi

  log "Initializing Pico SDK submodules (jobs=${submodule_jobs}, timeout=${timeout_s}s)"
  if ! GIT_TERMINAL_PROMPT=0 \
    run_with_optional_timeout "${timeout_s}" \
    git -C "${target}" submodule update --init --recursive --depth=1 --jobs "${submodule_jobs}"; then
    fail "Failed to initialize Pico SDK submodules (timed out or network/auth issue)"
  fi

  write_installed_version "${target}" "${tag}"
  log "Installed Pico SDK ${tag} -> ${target}"
  log "  Set PICO_SDK_PATH=${target} (or source settings.sh)"
}

main() {
  local -a tools_to_install=()
  local arg

  for arg in "$@"; do
    case "${arg}" in
      --force)          FORCE_INSTALL=true ;;
      -h|--help)        usage; exit 0 ;;
      oss-cad|arm|riscv|pico-sdk)
                        tools_to_install+=("${arg}") ;;
      *)                fail "Unknown argument: '${arg}'. Use --help for usage." ;;
    esac
  done

  [[ ${#tools_to_install[@]} -eq 0 ]] && tools_to_install=(oss-cad arm riscv pico-sdk)

  detect_host_platform
  log "Checking/updating toolchains in ${TOOLS_DIR} (${HOST_OS}/${HOST_ARCH})"

  for tool in "${tools_to_install[@]}"; do
    case "${tool}" in
      oss-cad)   install_oss_cad_suite ;;
      arm)       install_arm_gnu ;;
      riscv)     install_riscv_xpack ;;
      pico-sdk)  install_pico_sdk ;;
    esac
  done

  log ""
  log "Done. Source settings.sh to configure your environment:"
  log "  source settings.sh"
  log "Verify: command -v yosys arm-none-eabi-gcc riscv64-unknown-elf-gcc"
}

main "$@"
