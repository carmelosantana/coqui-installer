#!/usr/bin/env bash

# Coqui Installer
# https://github.com/carmelosantana/coqui
#
# Terminal AI agent with multi-model orchestration, persistent sessions,
# and runtime extensibility via Composer.
#
# Install with:
#   curl -fsSL https://raw.githubusercontent.com/carmelosantana/coqui-installer/main/install.sh | bash

set -euo pipefail

# ─── Configuration (override via environment variables) ──────────────────────

COQUI_REPO="${COQUI_REPO:-https://github.com/carmelosantana/coqui.git}"
COQUI_INSTALL_DIR="${COQUI_INSTALL_DIR:-$HOME/.coqui}"
COQUI_VERSION="${COQUI_VERSION:-}"

# GitHub release configuration
COQUI_GITHUB_OWNER="carmelosantana"
COQUI_GITHUB_REPO="coqui"
COQUI_API_URL="https://api.github.com/repos/${COQUI_GITHUB_OWNER}/${COQUI_GITHUB_REPO}/releases/latest"
COQUI_DOWNLOAD_BASE="https://github.com/${COQUI_GITHUB_OWNER}/${COQUI_GITHUB_REPO}/releases/download"

# Minimum PHP version required
REQUIRED_PHP_MAJOR=8
REQUIRED_PHP_MINOR=4

# PHP extensions required to boot Coqui successfully.
REQUIRED_EXTENSIONS="dom mbstring pdo_sqlite xml"

# Recommended extensions for a smooth default install.
RECOMMENDED_EXTENSIONS="curl readline"

# Optional feature extensions (derived from coqui/composer.json "suggest").
OPTIONAL_EXTENSIONS="gd pcntl posix"

# ─── Mode flags (set via CLI arguments) ──────────────────────────────────────

INSTALL_PHP=false
INSTALL_COMPOSER=false
INSTALL_COQUI=false
NON_INTERACTIVE=false
QUIET_MODE=false       # true when --quiet is passed (minimal output)
SELECTIVE_MODE=false   # true when any --install-* flag is passed
DEV_MODE=false         # true when --dev is passed (git clone instead of release)

# ─── Docker preference (Docker is the primary install path) ──────────────────

FORCE_NATIVE=0         # 1 when --native is passed (skip the Docker path)
DOCKER_OK=0            # 1 when docker + compose v2 are usable
DOCKER_NEEDS_SUDO=0    # 1 when docker only works via sudo

# Resolved at runtime
LATEST_VERSION=""

# ─── Argument parsing ────────────────────────────────────────────────────────

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --install-php)
                INSTALL_PHP=true; SELECTIVE_MODE=true; shift ;;
            --install-composer)
                INSTALL_COMPOSER=true; SELECTIVE_MODE=true; shift ;;
            --install-coqui)
                INSTALL_COQUI=true; SELECTIVE_MODE=true; shift ;;
            --dev)
                DEV_MODE=true; shift ;;
            --native)
                FORCE_NATIVE=1; shift ;;
            --non-interactive)
                NON_INTERACTIVE=true; shift ;;
            --quiet|-q)
                QUIET_MODE=true; shift ;;
            --help|-h)
                show_usage; exit 0 ;;
            *)
                error "Unknown argument: $1"
                echo "  Run '$0 --help' for usage."
                exit 1 ;;
        esac
    done

    # No --install-* flags → full install (backward compatible with curl | bash)
    if [ "$SELECTIVE_MODE" = false ]; then
        INSTALL_PHP=true
        INSTALL_COMPOSER=true
        INSTALL_COQUI=true
    fi
}

show_usage() {
    echo "Usage: $0 [flags]"
    echo ""
    echo "Flags:"
    echo "  --install-php          Install/check PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR}+ and extensions"
    echo "  --install-composer     Install/check Composer"
    echo "  --install-coqui        Install/update Coqui and create symlink"
    echo "  --native               Skip the Docker path; install natively on this host"
    echo "  --dev                  Use git clone instead of release download (for development)"
    echo "  --non-interactive      Skip all confirmation prompts (assume yes)"
    echo "  --quiet, -q            Minimal output (milestones and errors only)"
    echo "  --help, -h             Show this help"
    echo ""
    echo "By default, the installer downloads the latest GitHub release."
    echo "Use --dev to clone the git repository instead (requires Git and Composer)."
    echo ""
    echo "When no --install-* flags are given, all components are installed (full setup)."
    echo ""
    echo "Environment variables:"
    echo "  COQUI_REPO             Git repo URL (default: ${COQUI_REPO})"
    echo "  COQUI_INSTALL_DIR      Install path (default: \$HOME/.coqui)"
    echo "  COQUI_VERSION          Release version or git branch/tag (default: latest)"
    echo ""
    echo "Examples:"
    echo "  # Full install — latest release (default)"
    echo "  curl -fsSL https://...install.sh | bash"
    echo ""
    echo "  # Development install — git clone"
    echo "  ./install.sh --dev"
    echo ""
    echo "  # Specific version"
    echo "  COQUI_VERSION=0.0.1 ./install.sh"
    echo ""
    echo "  # PHP only, no prompts"
    echo "  ./install.sh --install-php --non-interactive"
    echo ""
    echo "  # PHP + Composer only"
    echo "  ./install.sh --install-php --install-composer"
    echo ""
    echo "  # Coqui only (user has PHP already)"
    echo "  ./install.sh --install-coqui"
}

# ─── Output helpers ──────────────────────────────────────────────────────────

BOLD="$( (tput bold 2>/dev/null) || echo '' )"
RED="$( (tput setaf 1 2>/dev/null) || echo '' )"
GREEN="$( (tput setaf 2 2>/dev/null) || echo '' )"
YELLOW="$( (tput setaf 3 2>/dev/null) || echo '' )"
CYAN="$( (tput setaf 6 2>/dev/null) || echo '' )"
RESET="$( (tput sgr0 2>/dev/null) || echo '' )"

TICK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
ARROW="${CYAN}▸${RESET}"

status()  { [ "$QUIET_MODE" = true ] && return; echo "  ${ARROW} $*"; }
success() { [ "$QUIET_MODE" = true ] && return; echo "  ${TICK} $*"; }
warn()    { echo "  ${YELLOW}! $*${RESET}"; }
error()   { echo "  ${CROSS} ${RED}$*${RESET}" >&2; }
fatal()   { error "$@"; exit 1; }
progress() { echo "  ${ARROW} $*"; }  # always prints, even in quiet mode

# ─── Utility functions ───────────────────────────────────────────────────────

available() { command -v "$1" >/dev/null 2>&1; }

# Prompt user for Y/n confirmation. Default is yes.
confirm() {
    local prompt="${1:-Continue?}"
    local reply

    # Non-interactive mode — assume yes
    if [ "$NON_INTERACTIVE" = true ]; then
        return 0
    fi

    # Piped input (curl | bash) — assume yes
    if [ ! -t 0 ]; then
        return 0
    fi

    printf "  %s %s [Y/n] " "${ARROW}" "${prompt}"
    read -r reply
    case "${reply}" in
        [nN]|[nN][oO]) return 1 ;;
        *) return 0 ;;
    esac
}

# Determine sudo requirement
setup_sudo() {
    SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if available sudo; then
            SUDO="sudo"
        fi
    fi
}

# Detect the best writable bin directory in PATH.
# Never selects a directory that requires sudo — falls back to ~/.local/bin.
detect_bin_dir() {
    # Apple Silicon Homebrew (/opt/homebrew/bin) — user-owned, no sudo needed
    if echo "$PATH" | tr ':' '\n' | grep -qx '/opt/homebrew/bin' && [ -w '/opt/homebrew/bin' ]; then
        BIN_DIR="/opt/homebrew/bin"
        return
    fi

    # Intel Homebrew / user-owned /usr/local/bin
    if echo "$PATH" | tr ':' '\n' | grep -qx '/usr/local/bin' && [ -w '/usr/local/bin' ]; then
        BIN_DIR="/usr/local/bin"
        return
    fi

    # Safe user-local fallback — always writable, no sudo required
    BIN_DIR="$HOME/.local/bin"
}

# ─── OS detection ────────────────────────────────────────────────────────────

# shellcheck disable=SC2034
detect_os() {
    OS="$(uname -s)"
    # shellcheck disable=SC2034
    ARCH="$(uname -m)"
    DISTRO=""
    # shellcheck disable=SC2034
    DISTRO_VERSION=""
    # shellcheck disable=SC2034
    IS_WSL=false
    PKG_MANAGER=""

    case "$OS" in
        Linux)
            local kern
            kern="$(uname -r)"
            case "$kern" in
                *icrosoft*WSL2|*icrosoft*wsl2) IS_WSL=true ;;
                *icrosoft) fatal "WSL1 is not supported. Please upgrade to WSL2." ;;
            esac

            if [ -f /etc/os-release ]; then
                # shellcheck disable=SC1091
                . /etc/os-release
                # shellcheck disable=SC2034
                DISTRO="${ID:-unknown}"
                # shellcheck disable=SC2034
                DISTRO_VERSION="${VERSION_ID:-}"
            fi

            if available apt-get; then
                PKG_MANAGER="apt"
            elif available dnf; then
                PKG_MANAGER="dnf"
            elif available yum; then
                PKG_MANAGER="yum"
            elif available pacman; then
                PKG_MANAGER="pacman"
            elif available apk; then
                PKG_MANAGER="apk"
            elif available nix-env || available nix; then
                PKG_MANAGER="nix"
            fi
            ;;
        Darwin)
            # shellcheck disable=SC2034
            DISTRO="macos"
            if available brew; then
                PKG_MANAGER="brew"
            elif available nix-env || available nix; then
                PKG_MANAGER="nix"
            fi
            ;;
        *)
            fatal "Unsupported operating system: $OS. Coqui supports Linux and macOS."
            ;;
    esac
}

# ─── Docker detection ────────────────────────────────────────────────────────

# Detect Docker Engine + Compose v2. Respects sudo: if docker only works under
# sudo, DOCKER_OK still becomes 1 but DOCKER_NEEDS_SUDO is set so callers can
# message the user (never silently sudo).
detect_docker() {
    DOCKER_OK=0
    DOCKER_NEEDS_SUDO=0

    if ! available docker; then
        return 0
    fi

    # Does `docker compose` (v2 plugin) exist and does the daemon respond?
    if docker compose version >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
        DOCKER_OK=1
        return 0
    fi

    # Daemon may require sudo (user not in docker group).
    if [ -n "${SUDO:-}" ] && $SUDO docker compose version >/dev/null 2>&1 && $SUDO docker version >/dev/null 2>&1; then
        DOCKER_OK=1
        # shellcheck disable=SC2034  # consumed by the Docker path (Task 8)
        DOCKER_NEEDS_SUDO=1
        return 0
    fi

    return 0
}

docker_available() {
    [ "${DOCKER_OK:-0}" = "1" ]
}

install_docker_stack() {
    status "Setting up the Coqui Docker stack in ${COQUI_INSTALL_DIR}..."
    mkdir -p "$COQUI_INSTALL_DIR/config"

    local sudo_prefix=""
    if [ "${DOCKER_NEEDS_SUDO:-0}" = "1" ]; then
        sudo_prefix="sudo"
        warn "Docker requires sudo on this machine. The 'coqui' wrapper will run docker with sudo."
        warn "To avoid this, add your user to the 'docker' group and re-log in."
    fi

    # Resolve the directory holding the repo's compose.yaml + wrapper. Running
    # as ./install.sh, BASH_SOURCE points at it; when the script is sourced or
    # piped (curl | bash) BASH_SOURCE may resolve to a pipe/fd, so fall back to
    # $PWD — but only when BOTH files are present together, which reliably marks
    # a real checkout and avoids grabbing an unrelated compose.yaml from cwd.
    local script_dir=""
    if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    local src_dir=""
    if [ -n "$script_dir" ] && [ -f "$script_dir/compose.yaml" ] && [ -f "$script_dir/coqui.wrapper.sh" ]; then
        src_dir="$script_dir"
    elif [ -f "$PWD/compose.yaml" ] && [ -f "$PWD/coqui.wrapper.sh" ]; then
        src_dir="$PWD"
    fi

    # compose.yaml — copy from repo if present, else download the canonical file.
    if [ -n "$src_dir" ]; then
        cp "$src_dir/compose.yaml" "$COQUI_INSTALL_DIR/compose.yaml"
    else
        curl -fsSL "https://raw.githubusercontent.com/carmelosantana/coqui-installer/main/compose.yaml" \
            -o "$COQUI_INSTALL_DIR/compose.yaml" \
            || fatal "Could not obtain compose.yaml"
    fi

    # coqui wrapper — same source resolution.
    [ -z "${BIN_DIR:-}" ] && detect_bin_dir
    mkdir -p "$BIN_DIR"
    if [ -n "$src_dir" ]; then
        cp "$src_dir/coqui.wrapper.sh" "$BIN_DIR/coqui"
    else
        curl -fsSL "https://raw.githubusercontent.com/carmelosantana/coqui-installer/main/coqui.wrapper.sh" \
            -o "$BIN_DIR/coqui" \
            || fatal "Could not obtain the coqui wrapper"
    fi
    chmod +x "$BIN_DIR/coqui"

    # Bake COQUI_HOME + optional sudo into the installed wrapper so it is self-contained.
    {
        echo "#!/usr/bin/env bash"
        echo "export COQUI_HOME=\"$COQUI_INSTALL_DIR\""
        [ -n "$sudo_prefix" ] && echo "export COQUI_SUDO=\"$sudo_prefix\""
        tail -n +2 "$BIN_DIR/coqui"
    } > "$BIN_DIR/coqui.tmp" && mv "$BIN_DIR/coqui.tmp" "$BIN_DIR/coqui"
    chmod +x "$BIN_DIR/coqui"

    # Pull + start (skipped cleanly if the fake docker in tests is a no-op).
    status "Pulling the Coqui image and starting the stack..."
    # shellcheck disable=SC2086  # intentional word-splitting on the sudo prefix
    ${sudo_prefix} docker compose -f "$COQUI_INSTALL_DIR/compose.yaml" pull || true
    # shellcheck disable=SC2086  # intentional word-splitting on the sudo prefix
    ${sudo_prefix} docker compose -f "$COQUI_INSTALL_DIR/compose.yaml" up -d \
        || fatal "docker compose up failed"

    success "Coqui is running — open http://localhost:8080"
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
        warn "${BIN_DIR} is not in your PATH; add it to use the 'coqui' command."
    fi
}

# ─── PHP checks ──────────────────────────────────────────────────────────────

check_php() {
    status "Checking PHP..."

    if ! available php; then
        warn "PHP is not installed."
        install_php
        return
    fi

    local php_version
    php_version="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
    local php_major php_minor
    php_major="$(echo "$php_version" | cut -d. -f1)"
    php_minor="$(echo "$php_version" | cut -d. -f2)"

    if [ "$php_major" -lt "$REQUIRED_PHP_MAJOR" ] || \
       { [ "$php_major" -eq "$REQUIRED_PHP_MAJOR" ] && [ "$php_minor" -lt "$REQUIRED_PHP_MINOR" ]; }; then
        warn "PHP $php_version found, but PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR}+ is required."
        install_php
        return
    fi

    success "PHP $php_version"
}

install_php() {
    case "$PKG_MANAGER" in
        apt)
            if confirm "Install PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR} via Ondrej PPA?"; then
                status "Adding Ondrej PHP repository..."
                $SUDO apt-get update -qq
                $SUDO apt-get install -y -qq software-properties-common ca-certificates lsb-release >/dev/null
                $SUDO add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1
                $SUDO apt-get update -qq

                local phpv="${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR}"
                local packages="php${phpv}-cli php${phpv}-curl php${phpv}-gd php${phpv}-mbstring php${phpv}-xml php${phpv}-zip php${phpv}-intl php${phpv}-readline php${phpv}-sqlite3"

                status "Installing PHP ${phpv} and extensions..."
                # shellcheck disable=SC2086
                $SUDO apt-get install -y -qq $packages >/dev/null
                success "PHP ${phpv} installed"
            else
                fatal "PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR}+ is required. Install it and re-run the installer."
            fi
            ;;
        brew)
            if confirm "Install PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR} via Homebrew?"; then
                status "Installing PHP via Homebrew..."
                brew install php@${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR} >/dev/null
                brew link --force --overwrite php@${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR} >/dev/null
                success "PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR} installed"
            else
                fatal "PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR}+ is required."
            fi
            ;;
        dnf|yum)
            if confirm "Install PHP via ${PKG_MANAGER}?"; then
                status "Installing PHP via ${PKG_MANAGER}..."
                # shellcheck disable=SC2086
                $SUDO ${PKG_MANAGER} install -y php-cli php-curl php-gd php-mbstring php-xml php-zip php-intl php-pdo >/dev/null
                success "PHP installed"
            else
                fatal "PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR}+ is required."
            fi
            ;;
        pacman)
            if confirm "Install PHP via pacman?"; then
                status "Installing PHP via pacman..."
                $SUDO pacman -S --noconfirm php php-sqlite php-intl >/dev/null
                success "PHP installed"
            else
                fatal "PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR}+ is required."
            fi
            ;;
        apk)
            if confirm "Install PHP via apk?"; then
                status "Installing PHP via apk..."
                local phpv="${REQUIRED_PHP_MAJOR}${REQUIRED_PHP_MINOR}"
                $SUDO apk add --no-cache php${phpv} php${phpv}-cli php${phpv}-curl php${phpv}-gd php${phpv}-mbstring php${phpv}-xml php${phpv}-zip php${phpv}-intl php${phpv}-pdo_sqlite >/dev/null
                success "PHP installed"
            else
                fatal "PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR}+ is required."
            fi
            ;;
        nix)
            if confirm "Install PHP via Nix?"; then
                status "Installing PHP via Nix..."
                local phpv="${REQUIRED_PHP_MAJOR}${REQUIRED_PHP_MINOR}"
                if available nix-env; then
                    nix-env -iA nixpkgs.php${phpv} >/dev/null 2>&1 || nix-env -iA nixpkgs.php >/dev/null 2>&1
                elif available nix; then
                    nix profile install nixpkgs#php${phpv} >/dev/null 2>&1 || nix profile install nixpkgs#php >/dev/null 2>&1
                fi
                success "PHP installed"
            else
                fatal "PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR}+ is required."
            fi
            ;;
        *)
            echo ""
            echo "  Please install PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR}+ with these core extensions:"
            echo "    dom, mbstring, pdo_sqlite, xml"
            echo ""
            echo "  Recommended extensions for the default Coqui install:"
            echo "    curl, readline, gd"
            echo ""
            echo "  On Linux/macOS, pcntl and posix enable background task management"
            echo "  (usually built into php-cli already)."
            echo ""
            echo "  See: https://www.php.net/manual/en/install.php"
            echo ""
            fatal "PHP ${REQUIRED_PHP_MAJOR}.${REQUIRED_PHP_MINOR}+ is required."
            ;;
    esac
}

# ─── Extension checks ────────────────────────────────────────────────────────

check_extensions() {
    status "Checking PHP extensions..."

    local missing_required=""
    local missing_recommended=""
    local missing_optional=""
    local loaded
    loaded="$(php -m 2>/dev/null)"

    for ext in $REQUIRED_EXTENSIONS; do
        if ! echo "$loaded" | grep -qi "^${ext}$"; then
            missing_required="${missing_required} ${ext}"
        fi
    done

    for ext in $RECOMMENDED_EXTENSIONS; do
        if ! echo "$loaded" | grep -qi "^${ext}$"; then
            missing_recommended="${missing_recommended} ${ext}"
        fi
    done

    for ext in $OPTIONAL_EXTENSIONS; do
        if ! echo "$loaded" | grep -qi "^${ext}$"; then
            missing_optional="${missing_optional} ${ext}"
        fi
    done

    if [ -n "$missing_required" ]; then
        warn "Missing required PHP extensions:${missing_required}"

        if [ "$PKG_MANAGER" = "apt" ]; then
        local phpv
        phpv="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"

        # Map extension names to apt package names
        local packages=""
        for ext in $missing_required; do
            case "$ext" in
                dom|xml)    packages="${packages} php${phpv}-xml" ;;
                pdo_sqlite) packages="${packages} php${phpv}-sqlite3" ;;
                *)          packages="${packages} php${phpv}-${ext}" ;;
            esac
        done

        if confirm "Install missing extensions via apt?"; then
            status "Installing:${packages}"
            # shellcheck disable=SC2086
            $SUDO apt-get install -y -qq $packages >/dev/null
            success "Extensions installed"
        else
            fatal "Required extensions missing:${missing_required}"
        fi
        elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        local packages=""
        for ext in $missing_required; do
            case "$ext" in
                dom|xml)    packages="${packages} php-xml" ;;
                pdo_sqlite) packages="${packages} php-pdo" ;;
                *)          packages="${packages} php-${ext}" ;;
            esac
        done
        if confirm "Install missing extensions via ${PKG_MANAGER}?"; then
            status "Installing:${packages}"
            # shellcheck disable=SC2086
            $SUDO ${PKG_MANAGER} install -y $packages >/dev/null
            success "Extensions installed"
        else
            fatal "Required extensions missing:${missing_required}"
        fi
        elif [ "$PKG_MANAGER" = "apk" ]; then
        local phpv="${REQUIRED_PHP_MAJOR}${REQUIRED_PHP_MINOR}"
        local packages=""
        for ext in $missing_required; do
            case "$ext" in
                dom|xml)    packages="${packages} php${phpv}-xml" ;;
                *)          packages="${packages} php${phpv}-${ext}" ;;
            esac
        done
        if confirm "Install missing extensions via apk?"; then
            status "Installing:${packages}"
            # shellcheck disable=SC2086
            $SUDO apk add --no-cache $packages >/dev/null
            success "Extensions installed"
        else
            fatal "Required extensions missing:${missing_required}"
        fi
        elif [ "$PKG_MANAGER" = "nix" ]; then
        warn "Missing required extensions:${missing_required}. Nix manages PHP extensions via derivation configuration. Ensure your Nix PHP package exposes these modules."
        if ! confirm "Ignore missing required extension warning and continue?"; then
             fatal "Required extensions missing:${missing_required}"
        fi
        else
        # pacman and brew generally bundle these extensions with their base php packages,
        # or require manual edits to php.ini to enable them.
        echo ""
        echo "  Please enable or install the following required PHP extensions:${missing_required}"
        echo ""
        fatal "Required PHP extensions missing."
        fi

        loaded="$(php -m 2>/dev/null)"
    fi

    if [ -n "$missing_recommended" ]; then
        warn "Missing recommended PHP extensions:${missing_recommended}"
        echo "  These improve the default Coqui experience: curl for faster HTTP providers and readline for REPL ergonomics."
    fi

    if [ -n "$missing_optional" ]; then
        warn "Missing optional PHP extensions:${missing_optional}"
        echo "  gd powers the bundled image toolkit's low-fidelity REPL previews; pcntl and posix enable background task cancellation and process management (usually built into php-cli on Linux/macOS)."
    fi

    if [ -z "$missing_required$missing_recommended$missing_optional" ]; then
        success "All core and recommended extensions available"
    else
        success "Core extension check complete"
    fi
}

# ─── Performance checks ─────────────────────────────────────────────────────

check_opcache() {
    status "Checking OPcache / JIT..."

    local opcache_loaded
    opcache_loaded="$(php -r 'echo extension_loaded("Zend OPcache") ? "1" : "0";' 2>/dev/null)"

    if [ "$opcache_loaded" != "1" ]; then
        warn "OPcache extension not loaded — install php-opcache for faster performance"
        return
    fi

    local opcache_enabled
    opcache_enabled="$(php -r 'echo ini_get("opcache.enable_cli") ?: "0";' 2>/dev/null)"

    if [ "$opcache_enabled" != "1" ]; then
        warn "OPcache CLI not enabled — set opcache.enable_cli=1 in php.ini"
    else
        success "OPcache CLI enabled"
    fi

    local jit_buffer
    jit_buffer="$(php -r 'echo ini_get("opcache.jit_buffer_size") ?: "0";' 2>/dev/null)"

    if [ "$jit_buffer" = "0" ] || [ -z "$jit_buffer" ]; then
        warn "JIT disabled — set opcache.jit=1255 and opcache.jit_buffer_size=128M for improved loop performance"
    else
        success "JIT enabled (buffer: ${jit_buffer})"
    fi
}

# ─── Git check ───────────────────────────────────────────────────────────────

check_git() {
    status "Checking git..."

    if available git; then
        success "git $(git --version | awk '{print $3}')"
        return
    fi

    case "$PKG_MANAGER" in
        apt)
            if confirm "Install git via apt?"; then
                $SUDO apt-get install -y -qq git >/dev/null
                success "git installed"
            else
                fatal "git is required."
            fi
            ;;
        brew)
            if confirm "Install git via Homebrew?"; then
                brew install git >/dev/null
                success "git installed"
            else
                fatal "git is required. Install it with: brew install git"
            fi
            ;;
        dnf|yum)
            if confirm "Install git via ${PKG_MANAGER}?"; then
                $SUDO ${PKG_MANAGER} install -y git >/dev/null
                success "git installed"
            else
                fatal "git is required."
            fi
            ;;
        pacman)
            if confirm "Install git via pacman?"; then
                $SUDO pacman -S --noconfirm git >/dev/null
                success "git installed"
            else
                fatal "git is required."
            fi
            ;;
        apk)
            if confirm "Install git via apk?"; then
                $SUDO apk add --no-cache git >/dev/null
                success "git installed"
            else
                fatal "git is required."
            fi
            ;;
        nix)
            if confirm "Install git via Nix?"; then
                if available nix-env; then
                    nix-env -iA nixpkgs.git >/dev/null 2>&1
                elif available nix; then
                    nix profile install nixpkgs#git >/dev/null 2>&1
                fi
                success "git installed"
            else
                fatal "git is required."
            fi
            ;;
        *)
            fatal "git is required. Please install it and re-run the installer."
            ;;
    esac
}

# ─── Composer check ──────────────────────────────────────────────────────────

check_composer() {
    status "Checking Composer..."

    if available composer; then
        success "Composer $(composer --version 2>/dev/null | awk '{print $NF}' | head -1)"
        return
    fi

    if confirm "Composer not found. Install it now?"; then
        install_composer
    else
        fatal "Composer is required."
    fi
}

install_composer() {
    status "Downloading Composer installer..."

    local expected_sig
    expected_sig="$(curl -fsSL https://composer.github.io/installer.sig)"

    local setup_script
    setup_script="$(mktemp)"

    # copy() returns false on failure; surface that instead of validating a stale file.
    if ! php -r "exit(@copy('https://getcomposer.org/installer', '$setup_script') ? 0 : 1);"; then
        rm -f "$setup_script"
        fatal "Failed to download the Composer installer."
    fi

    local actual_sig
    actual_sig="$(php -r "echo hash_file('sha384', '$setup_script');")"

    if [ "$expected_sig" != "$actual_sig" ]; then
        rm -f "$setup_script"
        fatal "Composer installer signature mismatch. Download may be corrupted."
    fi

    status "Installing Composer..."
    php "$setup_script" --quiet
    rm -f "$setup_script"

    # Move composer.phar to a directory in PATH.
    # detect_bin_dir only ever returns a writable directory, so no sudo is needed.
    detect_bin_dir
    mkdir -p "$BIN_DIR"
    mv composer.phar "$BIN_DIR/composer"

    success "Composer installed to $BIN_DIR/composer"
}

# ─── Installation detection ─────────────────────────────────────────────────

# Check for a git-based (dev) installation
is_dev_installed() {
    [ -d "$COQUI_INSTALL_DIR" ] && [ -d "$COQUI_INSTALL_DIR/.git" ]
}

# Check for a release-based installation
is_release_installed() {
    [ -d "$COQUI_INSTALL_DIR" ] && [ -f "$COQUI_INSTALL_DIR/.coqui-version" ]
}

# Check for any installation
is_installed() {
    is_dev_installed || is_release_installed
}

# Read the currently installed release version
get_installed_version() {
    if [ -f "$COQUI_INSTALL_DIR/.coqui-version" ]; then
        cat "$COQUI_INSTALL_DIR/.coqui-version"
    else
        echo ""
    fi
}

# ─── GitHub release functions ────────────────────────────────────────────────

# Fetch the latest release version from the GitHub API.
# Sets LATEST_VERSION to the semver string (e.g. "0.0.1").
fetch_latest_version() {
    if [ -n "$COQUI_VERSION" ]; then
        LATEST_VERSION="$COQUI_VERSION"
        return
    fi

    status "Checking latest release..."

    local api_response
    api_response="$(curl -fsSL "$COQUI_API_URL" 2>/dev/null)" \
        || fatal "Failed to fetch release info from GitHub. Check your internet connection or try --dev."

    # Parse tag_name from JSON without jq (works with grep + sed)
    local tag_name
    tag_name="$(echo "$api_response" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"

    if [ -z "$tag_name" ]; then
        fatal "Could not determine latest version from GitHub. Try: COQUI_VERSION=0.0.1 $0"
    fi

    # Strip leading 'v' if present
    LATEST_VERSION="${tag_name#v}"
    success "Latest release: v${LATEST_VERSION}"
}

# Verify SHA-256 checksum of a downloaded file.
# Usage: verify_checksum <file_path> <checksum_url>
verify_checksum() {
    local file_path="$1"
    local checksum_url="$2"
    local expected_checksum

    status "Verifying checksum..."

    # Fail closed: a release install always ships a .sha256 sidecar, so a failed
    # download means the integrity control is unavailable — never install unverified.
    expected_checksum="$(curl -fsSL "$checksum_url" 2>/dev/null)" || {
        fatal "Could not download the checksum file from ${checksum_url}. Refusing to install an unverified release."
    }

    # The .sha256 file format is: "hash  filename"
    local expected_hash
    expected_hash="$(echo "$expected_checksum" | awk '{print $1}')"

    local actual_hash
    if available sha256sum; then
        actual_hash="$(sha256sum "$file_path" | awk '{print $1}')"
    elif available shasum; then
        actual_hash="$(shasum -a 256 "$file_path" | awk '{print $1}')"
    else
        warn "No sha256sum or shasum available. Skipping verification."
        return 0
    fi

    if [ "$expected_hash" != "$actual_hash" ]; then
        fatal "Checksum verification failed. The download may be corrupted. Expected: ${expected_hash}, Got: ${actual_hash}"
    fi

    success "Checksum verified"
}

# ─── Release install / update ────────────────────────────────────────────────

install_release() {
    fetch_latest_version

    local archive_name="coqui-v${LATEST_VERSION}.tar.gz"
    local download_url="${COQUI_DOWNLOAD_BASE}/v${LATEST_VERSION}/${archive_name}"
    local checksum_url="${download_url}.sha256"
    local tmp_dir

    tmp_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" EXIT

    status "Downloading Coqui v${LATEST_VERSION}..."
    curl -fsSL "$download_url" -o "${tmp_dir}/${archive_name}" \
        || fatal "Failed to download release v${LATEST_VERSION}. URL: ${download_url}"

    verify_checksum "${tmp_dir}/${archive_name}" "$checksum_url"

    status "Installing to ${COQUI_INSTALL_DIR}..."
    mkdir -p "$COQUI_INSTALL_DIR"

    # Extract — the archive contains a top-level coqui/ directory
    tar -xzf "${tmp_dir}/${archive_name}" -C "$tmp_dir"

    # Guard: the archive must contain a top-level coqui/ directory
    if [ ! -d "${tmp_dir}/coqui" ]; then
        fatal "Unexpected archive structure — 'coqui' directory not found in ${archive_name}."
    fi

    # Copy contents from extracted directory into install dir
    cp -a "${tmp_dir}/coqui/." "$COQUI_INSTALL_DIR/"

    # Write version marker
    echo "$LATEST_VERSION" > "$COQUI_INSTALL_DIR/.coqui-version"

    # Ensure the bin script is executable
    chmod +x "$COQUI_INSTALL_DIR/bin/coqui" 2>/dev/null || true

    rm -rf "$tmp_dir"
    trap - EXIT

    success "Coqui v${LATEST_VERSION} installed"
}

update_release() {
    fetch_latest_version

    local current_version
    current_version="$(get_installed_version)"

    if [ "$current_version" = "$LATEST_VERSION" ]; then
        success "Coqui v${current_version} is already up to date"
        return
    fi

    if [ -n "$current_version" ]; then
        status "Update available: v${current_version} -> v${LATEST_VERSION}"
    fi

    if ! confirm "Update Coqui to v${LATEST_VERSION}?"; then
        success "Update skipped"
        return
    fi

    local archive_name="coqui-v${LATEST_VERSION}.tar.gz"
    local download_url="${COQUI_DOWNLOAD_BASE}/v${LATEST_VERSION}/${archive_name}"
    local checksum_url="${download_url}.sha256"
    local tmp_dir

    tmp_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" EXIT

    status "Downloading Coqui v${LATEST_VERSION}..."
    curl -fsSL "$download_url" -o "${tmp_dir}/${archive_name}" \
        || fatal "Failed to download release v${LATEST_VERSION}."

    verify_checksum "${tmp_dir}/${archive_name}" "$checksum_url"

    # User data preserved across updates. These are never deleted, and are
    # restored last so a customized copy always wins over any default shipped
    # in the release. `.workspace` holds all runtime state; openclaw.json/.env
    # are the only user-editable config the installer exposes at the root.
    local preserve_names=".workspace openclaw.json .env"
    local name

    # Back up preserved paths (files or directories)
    for name in $preserve_names; do
        if [ -e "$COQUI_INSTALL_DIR/$name" ]; then
            cp -a "$COQUI_INSTALL_DIR/$name" "${tmp_dir}/preserve-${name}"
        fi
    done

    # Extract new release
    tar -xzf "${tmp_dir}/${archive_name}" -C "$tmp_dir"

    # Guard: the archive must contain a top-level coqui/ directory
    if [ ! -d "${tmp_dir}/coqui" ]; then
        fatal "Unexpected archive structure — 'coqui' directory not found in ${archive_name}."
    fi

    # Remove the old vendor tree for a clean install, but never the preserved
    # user data.
    find "$COQUI_INSTALL_DIR" -mindepth 1 -maxdepth 1 \
        ! -name '.workspace' \
        ! -name 'openclaw.json' \
        ! -name '.env' \
        -exec rm -rf {} + 2>/dev/null || true

    # Install new release
    cp -a "${tmp_dir}/coqui/." "$COQUI_INSTALL_DIR/"

    # Restore preserved user data (overwrite any defaults from the new release)
    for name in $preserve_names; do
        if [ -e "${tmp_dir}/preserve-${name}" ]; then
            rm -rf "${COQUI_INSTALL_DIR:?}/$name"
            cp -a "${tmp_dir}/preserve-${name}" "$COQUI_INSTALL_DIR/$name"
        fi
    done

    # Write version marker
    echo "$LATEST_VERSION" > "$COQUI_INSTALL_DIR/.coqui-version"

    # Ensure the bin script is executable
    chmod +x "$COQUI_INSTALL_DIR/bin/coqui" 2>/dev/null || true

    rm -rf "$tmp_dir"
    trap - EXIT

    success "Coqui updated to v${LATEST_VERSION}"
}

# ─── Dev (git) install / update ──────────────────────────────────────────────

install_dev() {
    status "Cloning Coqui into ${COQUI_INSTALL_DIR}..."

    local clone_args="--depth 1"
    if [ -n "$COQUI_VERSION" ]; then
        clone_args="--branch $COQUI_VERSION --depth 1"
    fi

    # shellcheck disable=SC2086
    git clone $clone_args "$COQUI_REPO" "$COQUI_INSTALL_DIR" 2>/dev/null \
        || fatal "Failed to clone Coqui repository."

    success "Coqui cloned"

    run_composer_install
}

update_dev() {
    status "Checking for updates..."

    cd "$COQUI_INSTALL_DIR"

    # Stash any local changes (e.g. modified composer.lock) before pulling
    local stash_result
    stash_result="$(git stash --include-untracked 2>&1)" || true

    git fetch --quiet 2>/dev/null || fatal "Failed to fetch updates. Check your internet connection."

    local local_head remote_head
    local_head="$(git rev-parse HEAD)"
    remote_head="$(git rev-parse '@{u}' 2>/dev/null || echo "$local_head")"

    if [ "$local_head" = "$remote_head" ]; then
        success "Coqui is already up to date"

        # Restore stashed changes
        if echo "$stash_result" | grep -q "Saved working directory"; then
            git stash pop --quiet 2>/dev/null || true
        fi

        # Still run composer install in case dependencies changed locally
        run_composer_install
        return
    fi

    if confirm "A new version of Coqui is available. Update now?"; then
        status "Updating Coqui..."

        # Unshallow if needed (shallow clones can fail ff-only)
        if [ -f "$COQUI_INSTALL_DIR/.git/shallow" ]; then
            git fetch --unshallow --quiet 2>/dev/null || true
        fi

        if ! git pull --ff-only --quiet; then
            # Restore stash before reporting error
            if echo "$stash_result" | grep -q "Saved working directory"; then
                git stash pop --quiet 2>/dev/null || true
            fi
            fatal "Failed to update. Your local branch may have diverged. Try: rm -rf $COQUI_INSTALL_DIR && re-run the installer."
        fi

        success "Coqui updated"

        # Restore stashed changes — if pop fails, drop the stash since
        # the fresh pull state is authoritative and composer install will
        # regenerate composer.lock from the updated composer.json.
        if echo "$stash_result" | grep -q "Saved working directory"; then
            if ! git stash pop --quiet 2>/dev/null; then
                warn "Could not restore local changes from stash (likely a merge conflict)."
                warn "Dropping stash — composer install will regenerate lock file."
                git stash drop --quiet 2>/dev/null || true
            fi
        fi

        run_composer_install
    else
        # Restore stash if update was skipped
        if echo "$stash_result" | grep -q "Saved working directory"; then
            git stash pop --quiet 2>/dev/null || true
        fi
        success "Update skipped"
    fi
}

run_composer_install() {
    status "Installing dependencies..."

    cd "$COQUI_INSTALL_DIR"

    # Remove stale lock file if it conflicts with the current composer.json
    # (common after a git pull that changed composer.json while the old
    # composer.lock was stashed and couldn't be restored).
    if ! composer validate --no-check-all --no-check-publish --quiet 2>/dev/null; then
        warn "composer.lock is out of sync — regenerating..."
        rm -f composer.lock
    fi

    if ! composer install --no-dev --optimize-autoloader --no-interaction 2>&1; then
        fatal "Composer install failed. Run manually: cd $COQUI_INSTALL_DIR && composer install --no-dev"
    fi

    success "Dependencies installed"
}

# ─── Symlink ─────────────────────────────────────────────────────────────────

create_symlink() {
    detect_bin_dir

    local target="${COQUI_INSTALL_DIR}/bin/coqui"

    # Ensure the public wrapper is executable
    chmod +x "$target"

    status "Creating command symlink in ${BIN_DIR}..."

    mkdir -p "$BIN_DIR"
    ln -sf "$target" "$BIN_DIR/coqui"

    success "Symlink created: ${BIN_DIR}/coqui"

    # Warn if BIN_DIR is not in PATH
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
        echo ""
        warn "${BIN_DIR} is not in your PATH."
        echo ""
        echo "  Add it to your shell profile:"
        echo ""
        echo "    echo 'export PATH=\"${BIN_DIR}:\$PATH\"' >> ~/.bashrc"
        echo ""
    fi
}

# ─── Banner ──────────────────────────────────────────────────────────────────


show_banner() {
    if [ "$QUIET_MODE" = true ]; then return; fi
    echo ""
    echo "  ${GREEN} ▄▄·       .▄▄▄  ▄• ▄▌▪  ${RESET}"
    echo "  ${GREEN}▐█ ▌▪▪     ▐▀•▀█ █▪██▌██ ${RESET}"
    echo "  ${GREEN}██ ▄▄ ▄█▀▄ █▌·.█▌█▌▐█▌▐█·${RESET}"
    echo "  ${GREEN}▐███▌▐█▌.▐▌▐█▪▄█·▐█▄█▌▐█▌${RESET}"
    echo "  ${GREEN}·▀▀▀  ▀█▄▀▪·▀▀█.  ▀▀▀ ▀▀▀${RESET}"
    echo ""
    echo "  ${BOLD}Coqui Installer${RESET}"
    echo ""
}

# ─── Success message ─────────────────────────────────────────────────────────

print_success() {
    local install_type="$1"
    local version_info=""

    if [ -n "$LATEST_VERSION" ]; then
        version_info=" v${LATEST_VERSION}"
    elif [ -f "$COQUI_INSTALL_DIR/.coqui-version" ]; then
        version_info=" v$(cat "$COQUI_INSTALL_DIR/.coqui-version")"
    fi

    if [ "$QUIET_MODE" = true ]; then
        progress "${install_type} complete!${version_info}"
        return
    fi

    echo ""
    echo "  ──────────────────────────────────────────"
    echo "  ${BOLD}${GREEN}${install_type} complete!${version_info}${RESET}"
    echo "  ──────────────────────────────────────────"
    echo ""
    echo "  ${BOLD}Get started:${RESET}"
    echo ""
    echo "    coqui                # Start the full launcher-managed app (REPL + API)"
    echo "    coqui --api-only     # Start only the launcher-managed API"
    echo "    coqui status         # Inspect launcher-managed services"
    echo ""
    echo "  ${BOLD}Add cloud providers${RESET} (optional):"
    echo ""
    echo "    export OPENAI_API_KEY=\"sk-...\""
    echo "    export ANTHROPIC_API_KEY=\"sk-ant-...\""
    echo ""
    echo "  ${BOLD}Prerequisites:${RESET}"
    echo ""
    echo "    Make sure Ollama is running:  ollama serve"
    echo "    Pull a model:                 ollama pull glm-4.7-flash"
    echo ""
    echo "  ${BOLD}Docs:${RESET}  https://github.com/carmelosantana/coqui"
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    show_banner

    detect_os
    setup_sudo

    # ── Install-path selection ─────────────────────────────────────────────
    # Docker is primary. Fall back to native when forced (--native), when a
    # selective --install-* flag is given (you cannot --install-php into a
    # container, so a selective flag implies the native path), or when Docker
    # is unavailable.
    if [ "${FORCE_NATIVE:-0}" != "1" ] && [ "$SELECTIVE_MODE" != true ]; then
        detect_docker
        if docker_available; then
            install_docker_stack    # implemented in Task 8
            return 0
        fi
        warn "Docker (with 'docker compose') was not found — falling back to the native install."
        warn "Install Docker for the recommended experience, or pass --native to silence this."
    fi

    # ── Selective mode: run only the requested components ──
    if [ "$SELECTIVE_MODE" = true ]; then
        if [ "$INSTALL_PHP" = true ]; then
            check_php
            check_extensions
            check_opcache
        fi

        if [ "$INSTALL_COMPOSER" = true ]; then
            # Composer needs PHP — verify it exists even if --install-php wasn't passed
            if ! available php; then
                fatal "PHP is required to install Composer. Re-run with --install-php or install PHP manually."
            fi
            check_composer
        fi

        if [ "$INSTALL_COQUI" = true ]; then
            if ! available php; then
                fatal "PHP is required to install Coqui. Re-run with --install-php or install PHP manually."
            fi

            if [ "$DEV_MODE" = true ]; then
                # Dev mode: requires Git + Composer
                if ! available composer; then
                    fatal "Composer is required for --dev installs. Re-run with --install-composer or install Composer manually."
                fi
                check_git

                if is_dev_installed; then
                    update_dev
                else
                    install_dev
                fi
            else
                # Release mode: download pre-built archive (no Git/Composer needed)
                if is_dev_installed; then
                    echo ""
                    warn "A development (git) installation was found at ${COQUI_INSTALL_DIR}"
                    echo "  Use ${BOLD}--dev${RESET} to update it, or remove it first:"
                    echo "    rm -rf ${COQUI_INSTALL_DIR}"
                    echo ""
                    fatal "Cannot install release over a dev installation."
                fi

                if is_release_installed; then
                    update_release
                else
                    install_release
                fi
            fi

            create_symlink
        fi

        echo ""
        success "Done"
        echo ""
        return
    fi

    # ── Full install (no --install-* flags — backward compatible) ──
    if [ "$DEV_MODE" = true ]; then
        # Dev mode full install
        if is_dev_installed; then
            echo "  ${ARROW} Existing dev installation found at ${COQUI_INSTALL_DIR}"
            echo ""

            check_php
            check_extensions
            check_opcache
            check_composer

            update_dev
            create_symlink

            print_success "Update"
        else
            if is_release_installed; then
                echo ""
                warn "A release installation was found at ${COQUI_INSTALL_DIR}"
                echo "  Remove it first to switch to dev mode:"
                echo "    rm -rf ${COQUI_INSTALL_DIR}"
                echo ""
                fatal "Cannot install dev over a release installation."
            fi

            check_php
            check_extensions
            check_opcache
            check_git
            check_composer

            install_dev
            create_symlink

            print_success "Installation"
        fi
    else
        # Release mode full install (default)
        if is_dev_installed; then
            echo ""
            warn "A development (git) installation was found at ${COQUI_INSTALL_DIR}"
            echo "  To update it, re-run with ${BOLD}--dev${RESET}"
            echo "  To switch to release mode, remove it first:"
            echo "    rm -rf ${COQUI_INSTALL_DIR}"
            echo ""
            fatal "Cannot install release over a dev installation."
        fi

        if is_release_installed; then
            echo "  ${ARROW} Existing installation found at ${COQUI_INSTALL_DIR}"
            echo ""

            check_php
            check_extensions
            check_opcache

            update_release
            create_symlink

            print_success "Update"
        else
            check_php
            check_extensions
            check_opcache

            install_release
            create_symlink

            print_success "Installation"
        fi
    fi
}

# Wrap in main() so partial curl downloads don't execute incomplete script
main "$@"
