#!/usr/bin/env bash
# install_gico.sh — One-command installer for GICO-Veza OAA integration
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/integrations/gico/install_gico.sh | bash
#
# Non-interactive / CI mode:
#   VEZA_URL=your-company.veza.com VEZA_API_KEY='secret' \
#   bash install_gico.sh --non-interactive
set -euo pipefail

SCRIPT_NAME="gico-veza-installer"
DEFAULT_REPO_URL="https://github.com/<org>/<repo>.git"
DEFAULT_BRANCH="main"
DEFAULT_INSTALL_BASE="/opt/gico-veza"

REPO_URL="${DEFAULT_REPO_URL}"
BRANCH="${DEFAULT_BRANCH}"
INSTALL_BASE="${DEFAULT_INSTALL_BASE}"
NON_INTERACTIVE="false"
OVERWRITE_ENV="false"

APP_DIR=""
LOG_DIR=""
VENV_DIR=""
ENV_FILE=""
INSTALL_LOG=""
RUN_AS_ROOT=""
PKG_MANAGER=""
OS_ID=""
APT_UPDATED="false"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $*";  [[ -n "${INSTALL_LOG}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"  >> "${INSTALL_LOG}" || true; }
ok()   { echo -e "${GREEN}[OK]${NC} $*";    [[ -n "${INSTALL_LOG}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $*"    >> "${INSTALL_LOG}" || true; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; [[ -n "${INSTALL_LOG}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*"  >> "${INSTALL_LOG}" || true; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; [[ -n "${INSTALL_LOG}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >> "${INSTALL_LOG}" || true; }

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  --repo-url URL         Git repository URL (default: ${DEFAULT_REPO_URL})
  --branch NAME          Git branch to clone/update (default: ${DEFAULT_BRANCH})
  --install-dir PATH     Base install directory (default: ${DEFAULT_INSTALL_BASE})
  --non-interactive      Do not prompt for values (expects VEZA env vars)
  --overwrite-env        Overwrite existing .env file if present
  -h, --help             Show this help

Required env vars in --non-interactive mode:
  VEZA_URL  VEZA_API_KEY

Optional env vars:
  GICO_DATA_DIR  PROVIDER_NAME  DATASOURCE_NAME
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-url)        REPO_URL="$2";        shift 2 ;;
            --branch)          BRANCH="$2";          shift 2 ;;
            --install-dir)     INSTALL_BASE="$2";    shift 2 ;;
            --non-interactive) NON_INTERACTIVE="true"; shift ;;
            --overwrite-env)   OVERWRITE_ENV="true";   shift ;;
            -h|--help)         usage; exit 0 ;;
            *)                 err "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

configure_paths() {
    APP_DIR="${INSTALL_BASE}/scripts"
    LOG_DIR="${INSTALL_BASE}/logs"
    VENV_DIR="${APP_DIR}/venv"
    ENV_FILE="${APP_DIR}/.env"
    INSTALL_LOG="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
}

require_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        err "This installer supports Linux only."
        exit 1
    fi
}

detect_package_manager() {
    if   command -v dnf     >/dev/null 2>&1; then PKG_MANAGER="dnf"
    elif command -v yum     >/dev/null 2>&1; then PKG_MANAGER="yum"
    elif command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt"
    elif command -v zypper  >/dev/null 2>&1; then PKG_MANAGER="zypper"
    elif command -v apk     >/dev/null 2>&1; then PKG_MANAGER="apk"
    else
        err "No supported package manager found (dnf/yum/apt/zypper/apk)."
        exit 1
    fi
    ok "Detected package manager: ${PKG_MANAGER}"

    if [[ -f /etc/os-release ]]; then
        OS_ID="$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')"
    else
        OS_ID="unknown"
    fi
    ok "Detected distro: ${OS_ID}"
}

ensure_root_command() {
    if [[ "${EUID}" -eq 0 ]]; then
        RUN_AS_ROOT=""
    elif command -v sudo >/dev/null 2>&1; then
        RUN_AS_ROOT="sudo"
    else
        err "Root access is required. Run as root or install sudo."
        exit 1
    fi
}

run_root() {
    if [[ -n "${RUN_AS_ROOT}" ]]; then
        ${RUN_AS_ROOT} "$@"
    else
        "$@"
    fi
}

setup_directories() {
    run_root mkdir -p "${APP_DIR}" "${LOG_DIR}"
    run_root chmod 755 "${INSTALL_BASE}" "${APP_DIR}" "${LOG_DIR}"
    run_root touch "${INSTALL_LOG}"

    if [[ "${EUID}" -ne 0 ]]; then
        run_root chown -R "${USER}":"${USER}" "${INSTALL_BASE}"
        run_root chown "${USER}":"${USER}" "${INSTALL_LOG}"
    fi
}

install_pkg() {
    local pkg="$1"
    case "${PKG_MANAGER}" in
        dnf)    run_root dnf install -y "${pkg}" >/dev/null ;;
        yum)    run_root yum install -y "${pkg}" >/dev/null ;;
        apt)
            if [[ "${APT_UPDATED}" != "true" ]]; then
                run_root apt-get update -y >/dev/null
                APT_UPDATED="true"
            fi
            run_root apt-get install -y "${pkg}" >/dev/null
            ;;
        zypper) run_root zypper --non-interactive install "${pkg}" >/dev/null ;;
        apk)    run_root apk add --no-cache "${pkg}" >/dev/null ;;
    esac
}

install_system_packages() {
    if ! command -v git >/dev/null 2>&1; then
        log "Installing git..."; install_pkg "git"
    fi

    if ! command -v curl >/dev/null 2>&1; then
        if command -v wget >/dev/null 2>&1; then
            warn "curl not found, but wget is available. Continuing."
        else
            log "Installing curl..."; install_pkg "curl"
        fi
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log "Installing python3..."; install_pkg "python3"
    fi

    if ! python3 -m pip --version >/dev/null 2>&1; then
        log "Installing python3-pip..."
        case "${PKG_MANAGER}" in
            apk) install_pkg "py3-pip" ;;
            *)   install_pkg "python3-pip" ;;
        esac
    fi

    if ! python3 -m venv --help >/dev/null 2>&1; then
        warn "python3 venv module not available; installing..."
        case "${PKG_MANAGER}" in
            dnf)    run_root dnf install -y python3-virtualenv >/dev/null ;;
            yum)    run_root yum install -y python3-virtualenv >/dev/null ;;
            apt)    run_root apt-get install -y python3-venv >/dev/null ;;
            zypper) run_root zypper --non-interactive install python3-virtualenv >/dev/null ;;
            apk)    run_root apk add --no-cache py3-virtualenv >/dev/null ;;
        esac
    fi

    ok "System packages verified"
}

check_python_version() {
    local version
    version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    local major minor
    major="${version%%.*}"
    minor="${version##*.}"
    if (( major < 3 || (major == 3 && minor < 8) )); then
        err "Python ${version} detected; Python 3.8+ required."
        exit 1
    fi
    ok "Python ${version} is supported"
}

sync_repository() {
    if [[ -d "${APP_DIR}/.git" ]]; then
        log "Existing repository found in ${APP_DIR}; updating..."
        git -C "${APP_DIR}" remote set-url origin "${REPO_URL}" >> "${INSTALL_LOG}" 2>&1
        git -C "${APP_DIR}" fetch --all --prune >> "${INSTALL_LOG}" 2>&1
        git -C "${APP_DIR}" checkout "${BRANCH}" >> "${INSTALL_LOG}" 2>&1
        git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}" >> "${INSTALL_LOG}" 2>&1
    else
        if [[ -n "$(ls -A "${APP_DIR}" 2>/dev/null)" ]]; then
            warn "${APP_DIR} is not empty. Existing files may be overwritten."
            run_root rm -rf "${APP_DIR}"
            run_root mkdir -p "${APP_DIR}"
            if [[ "${EUID}" -ne 0 ]]; then
                run_root chown "${USER}":"${USER}" "${APP_DIR}"
            fi
        fi
        log "Cloning repository ${REPO_URL} (${BRANCH}) into ${APP_DIR}"
        git clone --branch "${BRANCH}" --single-branch "${REPO_URL}" "${APP_DIR}" >> "${INSTALL_LOG}" 2>&1
    fi

    chmod +x "${APP_DIR}/integrations/gico/gico.py" 2>/dev/null || true
    ok "Repository synchronized"
}

setup_python_environment() {
    log "Creating/updating Python virtual environment..."
    if [[ ! -d "${VENV_DIR}" ]]; then
        python3 -m venv "${VENV_DIR}"
    fi
    ok "Virtual environment ready: ${VENV_DIR}"

    log "Upgrading pip..."
    "${VENV_DIR}/bin/python" -m pip install --upgrade pip 2>&1 | tee -a "${INSTALL_LOG}" | tail -1

    log "Installing Python dependencies..."
    local req_file="${APP_DIR}/integrations/gico/requirements.txt"
    if [[ ! -f "${req_file}" ]]; then
        req_file="${APP_DIR}/requirements.txt"
    fi

    if ! "${VENV_DIR}/bin/pip" install -r "${req_file}" 2>&1 | tee -a "${INSTALL_LOG}"; then
        err "pip install failed. Check ${INSTALL_LOG}"
        exit 1
    fi

    # Verify key packages
    local failed=0
    for entry in "requests:requests" "python-dotenv:dotenv" "oaaclient:oaaclient"; do
        local dist="${entry%%:*}"
        local imp="${entry##*:}"
        if "${VENV_DIR}/bin/python" -c "import ${imp}" 2>/dev/null; then
            local ver
            ver=$("${VENV_DIR}/bin/pip" show "${dist}" 2>/dev/null | grep '^Version:' | awk '{print $2}')
            ok "${dist} ${ver:-installed} verified"
        else
            err "${dist} failed to import"
            failed=$((failed + 1))
        fi
    done

    if [[ ${failed} -gt 0 ]]; then
        err "${failed} package(s) failed. Run: ${VENV_DIR}/bin/pip install -r ${req_file}"
        exit 1
    fi
    ok "All Python dependencies installed"
}

sanitize_veza_url() {
    local raw="$1"
    raw="${raw#https://}"
    raw="${raw#http://}"
    raw="${raw%/}"
    echo "${raw}"
}

prompt_value() {
    local prompt_text="$1"
    local default_value="$2"
    local required="$3"
    local secret="$4"
    local value=""

    while true; do
        if [[ "${secret}" == "true" ]]; then
            if [[ -n "${default_value}" ]]; then
                IFS= read -r -s -p "${prompt_text} [current kept if empty]: " value </dev/tty
            else
                IFS= read -r -s -p "${prompt_text}: " value </dev/tty
            fi
            echo >/dev/tty
        else
            if [[ -n "${default_value}" ]]; then
                IFS= read -r -p "${prompt_text} [${default_value}]: " value </dev/tty
            else
                IFS= read -r -p "${prompt_text}: " value </dev/tty
            fi
        fi

        if [[ -z "${value}" && -n "${default_value}" ]]; then
            value="${default_value}"
        fi

        if [[ "${required}" == "true" && -z "${value}" ]]; then
            echo -e "${YELLOW}[WARN]${NC} This value is required." >/dev/tty
            continue
        fi

        echo "${value}"
        return 0
    done
}

load_existing_env_defaults() {
    EXISTING_VEZA_URL=""
    EXISTING_GICO_DATA_DIR=""
    EXISTING_PROVIDER_NAME=""
    EXISTING_DATASOURCE_NAME=""

    if [[ -f "${ENV_FILE}" ]]; then
        EXISTING_VEZA_URL="$(grep -E '^VEZA_URL=' "${ENV_FILE}" | tail -1 | cut -d'=' -f2- || true)"
        EXISTING_GICO_DATA_DIR="$(grep -E '^GICO_DATA_DIR=' "${ENV_FILE}" | tail -1 | cut -d'=' -f2- || true)"
        EXISTING_PROVIDER_NAME="$(grep -E '^PROVIDER_NAME=' "${ENV_FILE}" | tail -1 | cut -d'=' -f2- || true)"
        EXISTING_DATASOURCE_NAME="$(grep -E '^DATASOURCE_NAME=' "${ENV_FILE}" | tail -1 | cut -d'=' -f2- || true)"
    fi
}

create_env_file() {
    if [[ -f "${ENV_FILE}" && "${OVERWRITE_ENV}" != "true" ]]; then
        warn "${ENV_FILE} already exists. Reusing (use --overwrite-env to regenerate)."
        return 0
    fi

    load_existing_env_defaults

    local veza_url="" veza_api_key="" gico_data_dir="" provider_name="" datasource_name=""

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        veza_url="${VEZA_URL:-}"
        veza_api_key="${VEZA_API_KEY:-}"
        gico_data_dir="${GICO_DATA_DIR:-/path/to/gico/exports}"
        provider_name="${PROVIDER_NAME:-GICO}"
        datasource_name="${DATASOURCE_NAME:-GICO}"

        if [[ -z "${veza_url}" || -z "${veza_api_key}" ]]; then
            err "Missing required environment variables for --non-interactive mode."
            err "Required: VEZA_URL, VEZA_API_KEY"
            exit 1
        fi
    else
        log "Collecting GICO + Veza configuration for .env"
        veza_url="$(prompt_value "Veza URL (e.g. your-company.veza.com)" "${EXISTING_VEZA_URL}" "true" "false")"
        veza_api_key="$(prompt_value "Veza API key" "" "true" "true")"
        gico_data_dir="$(prompt_value "Path to GICO export files directory" "${EXISTING_GICO_DATA_DIR:-/path/to/gico/exports}" "false" "false")"
        provider_name="$(prompt_value "Veza provider name" "${EXISTING_PROVIDER_NAME:-GICO}" "false" "false")"
        datasource_name="$(prompt_value "Veza datasource name" "${EXISTING_DATASOURCE_NAME:-GICO}" "false" "false")"
    fi

    veza_url="$(sanitize_veza_url "${veza_url}")"

    cat > "${ENV_FILE}" <<EOF
# GICO-Veza OAA Integration Configuration
# Generated by install_gico.sh on $(date '+%Y-%m-%d %H:%M:%S')

# Veza Configuration
VEZA_URL=${veza_url}
VEZA_API_KEY=${veza_api_key}

# GICO Data Source
GICO_DATA_DIR=${gico_data_dir}

# OAA Provider Settings
PROVIDER_NAME=${provider_name}
DATASOURCE_NAME=${datasource_name}
EOF

    chmod 600 "${ENV_FILE}"
    ok ".env created at ${ENV_FILE}"
}

test_connectivity() {
    local target="$1"
    local endpoint="$2"

    if [[ -z "${endpoint}" ]]; then
        warn "Skipping ${target} connectivity test (empty host)"
        return 0
    fi

    local url="${endpoint}"
    if [[ ! "${url}" =~ ^https?:// ]]; then
        url="https://${url}"
    fi

    if curl -k -sS --connect-timeout 8 --max-time 15 "${url}" >/dev/null 2>&1; then
        ok "Connectivity check passed: ${target} (${url})"
    else
        warn "Connectivity check failed: ${target} (${url})"
    fi
}

run_post_install_checks() {
    log "Running post-install checks..."
    check_python_version

    local veza_url
    veza_url="$(grep -E '^VEZA_URL=' "${ENV_FILE}" | cut -d'=' -f2-)"
    test_connectivity "Veza API" "${veza_url}"

    ok "Post-install checks completed"
}

print_summary() {
    cat <<EOF

Installation complete.

Paths:
  Base:      ${INSTALL_BASE}
  Scripts:   ${APP_DIR}/integrations/gico/
  Venv:      ${VENV_DIR}
  Config:    ${ENV_FILE}
  Logs:      ${LOG_DIR}
  Log file:  ${INSTALL_LOG}

Run the integration:
  cd ${APP_DIR}
  source venv/bin/activate
  python3 integrations/gico/gico.py \\
    --data-dir /path/to/gico/exports \\
    --env-file ${ENV_FILE} \\
    --dry-run

For production:
  ${VENV_DIR}/bin/python ${APP_DIR}/integrations/gico/gico.py \\
    --data-dir /path/to/gico/exports \\
    --env-file ${ENV_FILE}
EOF
}

main() {
    parse_args "$@"
    require_linux
    detect_package_manager
    ensure_root_command
    configure_paths
    setup_directories

    log "Starting GICO-Veza installer"
    log "Repository: ${REPO_URL} (${BRANCH})"
    log "Install base: ${INSTALL_BASE}"

    install_system_packages
    check_python_version
    sync_repository
    setup_python_environment
    create_env_file
    run_post_install_checks
    print_summary
}

main "$@"
