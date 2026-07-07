#!/usr/bin/env bash
# =============================================================================
# recon-toolchain-v2.sh
# =============================================================================
# Clean installer for the pi-agent bug-bounty recon toolchain on Ubuntu 24.04.
#
# Fixes all known failure modes from v1:
#   - Tools not on PyPI → git clone + pip install . / symlink
#   - Debian package RECORD conflicts → pip install --ignore-installed
#   - mmh3 (lib-only) → python3 -c "import mmh3" check
#   - cewl → apt-get install
#   - wappalyzer-cli → npm + symlink from node_modules
#   - metabigor → ASSUME_NO_MOVING_GC_UNSAFE_RISK_IT_WITH in .bashrc
#   - trickest resolvers → single-line curl (no line-continuation bugs)
#
# Usage:
#   chmod +x recon-toolchain-v2.sh
#   sudo ./recon-toolchain-v2.sh
#
# Idempotent: skips already-installed tools.  Failures are logged and
# summarised at the end so you can fix them in one pass.
# =============================================================================

set -uo pipefail
# Intentional: no "set -e".  Each install function returns 1 on failure;
# the script logs, increments FAIL_COUNT, and continues.

# ---------------------------------------------------------------------------
# 0.  Configuration & globals
# ---------------------------------------------------------------------------
LOG_DIR="/var/log/pi-agent"
SUMMARY_FILE="${LOG_DIR}/recon-install-v2-$(date -u +%Y%m%d-%H%M%S).txt"
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_TOOLS=()

mkdir -p "$LOG_DIR"

# Wire Go / Ruby / local bins into PATH for this session and future shells
export PATH="${PATH}:/usr/local/go/bin:${HOME}/go/bin:${HOME}/.local/bin"
grep -q 'go/bin' "${HOME}/.bashrc" 2>/dev/null ||
    echo 'export PATH="${PATH}:${HOME}/go/bin:${HOME}/.local/bin"' >> "${HOME}/.bashrc"
export PIP_REQUIRE_VIRTUALENV=false  # suppress Ubuntu 24.04 venv enforcement

# ---------------------------------------------------------------------------
# 1.  Helper functions
# ---------------------------------------------------------------------------
log_start()    { echo ""; echo "================================================"; echo " $1"; echo "================================================"; }
log_info()     { echo "       $1"; }
log_ok()       { echo "            ✓ $1"; SUCCESS_COUNT=$((SUCCESS_COUNT + 1)); }
log_skip()     { echo "            (already installed, skipping)"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
log_fail()     { local t="$1" r="$2"; echo "            ✗ $t FAILED — $r"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_TOOLS+=("$t — $r"); echo "[FAIL] $t — $r" >> "$SUMMARY_FILE"; }

# install_go <import-path> <binary-name>
install_go() {
    local pkg="$1" bin="$2"
    echo "       [go] $bin"
    command -v "$bin" >/dev/null 2>&1 && { log_skip; return 0; }
    local errfile="/tmp/go-install-${bin}.log"
    if go install -v "${pkg}@latest" >"$errfile" 2>&1; then
        if [ -f "${HOME}/go/bin/${bin}" ]; then
            cp "${HOME}/go/bin/${bin}" /usr/local/bin/"${bin}" 2>/dev/null || true
        fi
        command -v "$bin" >/dev/null 2>&1 && { log_ok "$bin"; rm -f "$errfile"; return 0; }
    fi
    local reason; reason=$(tail -5 "$errfile" | tr '\n' ' ' | sed 's/  */ /g' | head -c 250)
    log_fail "$bin" "$reason"; rm -f "$errfile"; return 1
}

# install_pip <package-name> [cli-name] [extra-flags]
# Installs a PyPI package.  extra-flags passed verbatim to pip3 (e.g.
# "--ignore-installed").  If the package is a lib without a CLI binary
# (like mmh3), pass the cli-name as a sentinel like "LIB:verify-import".
install_pip() {
    local pkg="$1" cli="${2:-$1}" flags="${3:-}"
    echo "       [pip] $pkg"
    # Special case: library-only package, verify via Python import
    if [[ "$cli" == LIB:* ]]; then
        local mod="${cli#LIB:}"
        python3 -c "import $mod" 2>/dev/null && { log_skip; return 0; }
        # shellcheck disable=SC2086
        pip3 install --break-system-packages $flags --quiet "$pkg" 2>/dev/null | grep -v '^$'
        python3 -c "import $mod" 2>/dev/null && { log_ok "$pkg (Python lib)"; return 0; }
        log_fail "$pkg" "import $mod failed after pip install"; return 1
    fi
    # Standard case: tool has a CLI binary
    command -v "$cli" >/dev/null 2>&1 && { log_skip; return 0; }
    local errfile="/tmp/pip-install-${cli}.log"
    # shellcheck disable=SC2086
    pip3 install --break-system-packages $flags --quiet "$pkg" >"$errfile" 2>&1
    if command -v "$cli" >/dev/null 2>&1; then
        log_ok "$pkg"; rm -f "$errfile"; return 0
    fi
    local reason; reason=$(tail -5 "$errfile" | tr '\n' ' ' | sed 's/  */ /g' | head -c 250)
    log_fail "$pkg" "$reason"; rm -f "$errfile"; return 1
}

# install_pip_git <name> <repo-url> [cli-name]
# Clones a git repo, installs it (setup.py or pyproject.toml if present),
# and symlinks the script if it has no setup.py.
install_pip_git() {
    local name="$1" repo="$2" cli="${3:-$1}"
    echo "       [git+pip] $name"
    command -v "$cli" >/dev/null 2>&1 && { log_skip; return 0; }
    local target="/opt/$name"
    if [ ! -d "$target" ]; then
        git clone --quiet "$repo" "$target" 2>&1 | tail -1 || { log_fail "$name" "git clone failed"; return 1; }
    fi
    # Try pip install . if there's a setup.py or pyproject.toml
    if [ -f "$target/setup.py" ] || [ -f "$target/pyproject.toml" ]; then
        pip3 install --break-system-packages --quiet "$target" 2>/dev/null | tail -1
    fi
    # If still not on PATH, symlink the main script
    if ! command -v "$cli" >/dev/null 2>&1; then
        local script
        script=$(find "$target" -maxdepth 1 -name "${name}.py" -o -name "${cli}.py" 2>/dev/null | head -1)
        if [ -z "$script" ]; then
            script=$(find "$target" -maxdepth 2 -name "*.py" -type f 2>/dev/null | grep -i "${cli}\|${name}" | head -1)
        fi
        if [ -n "$script" ]; then
            chmod +x "$script"
            ln -sf "$script" "/usr/local/bin/$cli"
        fi
    fi
    command -v "$cli" >/dev/null 2>&1 && { log_ok "$name"; return 0; }
    log_fail "$name" "symlinked but not on PATH (available at $target)"
}

# install_npm <package-name> <cli-name>
# npm global install, then symlink the binary if it's not on PATH after.
install_npm() {
    local pkg="$1" cli="${2:-$1}"
    echo "       [npm] $pkg"
    command -v "$cli" >/dev/null 2>&1 && { log_skip; return 0; }
    npm install -g "$pkg" 2>&1 | tail -1
    # npm often installs bin scripts correctly; if not, symlink from node_modules
    if ! command -v "$cli" >/dev/null 2>&1; then
        local binpath
        binpath=$(npm root -g 2>/dev/null)/"${pkg}"/bin/"${cli}".js
        [ -f "$binpath" ] && ln -sf "$binpath" "/usr/local/bin/$cli"
    fi
    command -v "$cli" >/dev/null 2>&1 && { log_ok "$pkg"; return 0; }
    log_fail "$pkg" "not on PATH after npm install"
}

# install_gem <gem-name> [cli-name]
install_gem() {
    local gem="$1" cli="${2:-$gem}"
    echo "       [gem] $gem"
    command -v "$cli" >/dev/null 2>&1 && { log_skip; return 0; }
    gem install "$gem" --no-document 2>&1 | tail -1
    command -v "$cli" >/dev/null 2>&1 && { log_ok "$gem"; return 0; }
    log_fail "$gem" "gem install failed"
}

# ---------------------------------------------------------------------------
# 2.  System update & prerequisites
# ---------------------------------------------------------------------------
log_start "System prerequisites"

log_info "Updating package lists …"
apt-get update -qq 2>&1 | tail -1
log_info "Upgrading packages …"
apt-get upgrade -y -qq 2>&1 | tail -1

log_info "Installing apt prerequisites …"

APT_PACKAGES=(
    curl wget git jq tmux unzip
    build-essential ca-certificates gnupg apt-transport-https
    golang
    python3 python3-pip python3-venv
    nodejs npm
    ruby ruby-dev
    dnsutils
    nmap masscan
    whatweb
)

apt-get install -y -qq "${APT_PACKAGES[@]}" 2>&1 | tail -3

# aws-cli via official installer
if ! command -v aws >/dev/null 2>&1; then
    log_info "Installing aws-cli …"
    curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -qo /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install --update 2>&1 | tail -1
    rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# ---------------------------------------------------------------------------
# 3.  Go-based tools
# ---------------------------------------------------------------------------
log_start "Go-based recon tools"

install_go "github.com/projectdiscovery/subfinder/v2/cmd/subfinder"      "subfinder"
install_go "github.com/projectdiscovery/httpx/cmd/httpx"                 "httpx"
install_go "github.com/projectdiscovery/nuclei/v3/cmd/nuclei"            "nuclei"
install_go "github.com/projectdiscovery/naabu/v2/cmd/naabu"             "naabu"
install_go "github.com/projectdiscovery/katana/cmd/katana"              "katana"
install_go "github.com/projectdiscovery/dnsx/cmd/dnsx"                  "dnsx"
install_go "github.com/projectdiscovery/asnmap/cmd/asnmap"              "asnmap"
install_go "github.com/projectdiscovery/shuffledns/cmd/shuffledns"      "shuffledns"

install_go "github.com/owasp-amass/amass/v3/..."                        "amass"

install_go "github.com/jaeles-project/gospider"                         "gospider"
install_go "github.com/hakluke/hakrawler"                               "hakrawler"
install_go "github.com/tomnomnom/waybackurls"                           "waybackurls"
install_go "github.com/lc/gau/v2/cmd/gau"                               "gau"
install_go "github.com/tomnomnom/assetfinder"                           "assetfinder"
install_go "github.com/tomnomnom/anew"                                  "anew"
install_go "github.com/tomnomnom/unfurl"                                "unfurl"

# puredns — /v2 in go.mod
if ! install_go "github.com/d3mondev/puredns/v2" "puredns"; then
    log_info "puredns go install failed — trying apt …"
    if ! apt-get install -y -qq puredns 2>&1 | tail -2; then
        log_info "apt failed — cloning from source …"
        git clone --quiet https://github.com/d3mondev/puredns.git /opt/puredns 2>&1 | tail -1
        ( cd /opt/puredns && go build -o /usr/local/bin/puredns . ) 2>&1 | tail -1
        command -v puredns >/dev/null 2>&1 && log_ok "puredns (from source)"
    fi
fi

install_go "github.com/j3ssie/metabigor"                                "metabigor"
install_go "github.com/gwen001/github-subdomains"                       "github-subdomains"
install_go "github.com/incogbyte/shosubgo"                              "shosubgo"
install_go "github.com/sa7mon/s3scanner"                                "s3scanner"
install_go "github.com/zricethezav/gitleaks/v8"                         "gitleaks"
install_go "github.com/ffuf/ffuf/v2"                                    "ffuf"
install_go "github.com/sensepost/gowitness"                             "gowitness"
install_go "github.com/rverton/webanalyze/cmd/webanalyze"               "webanalyze"

# trufflehog — go install broken (replace directives in go.mod)
if ! command -v trufflehog >/dev/null 2>&1; then
    echo "       [script] trufflehog (official install script)"
    curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
        | sh -s -- -b /usr/local/bin 2>&1 | tail -1
    command -v trufflehog >/dev/null 2>&1 && log_ok "trufflehog" || log_fail "trufflehog" "install script failed"
else
    log_skip
fi

# kiterunner — does NOT support go install; must git clone + make build
if ! command -v kr >/dev/null 2>&1; then
    echo "       [make] kr (kiterunner — git clone + make build)"
    git clone --quiet https://github.com/assetnote/kiterunner.git /opt/kiterunner 2>&1 | tail -1
    ( cd /opt/kiterunner && make build 2>&1 | tail -1 )
    if [ -f /opt/kiterunner/dist/kr ]; then
        ln -sf /opt/kiterunner/dist/kr /usr/local/bin/kr
        log_ok "kr"
    else
        log_fail "kr" "make build produced no dist/kr"
    fi
else
    log_skip
fi

# Metabigor GC fix: the tool panics on Go ≥1.22 without this env var
grep -q 'ASSUME_NO_MOVING_GC_UNSAFE_RISK_IT_WITH' /root/.bashrc 2>/dev/null || {
    echo 'export ASSUME_NO_MOVING_GC_UNSAFE_RISK_IT_WITH=go1.22' >> /root/.bashrc
    log_info "Metabigor GC env var added to /root/.bashrc"
}

# ---------------------------------------------------------------------------
# 4.  Python / pip tools
# ---------------------------------------------------------------------------
log_start "Python-based recon tools"

# --- Standard PyPI installs (CLI binary present) ---
install_pip "shodan"                  "shodan"
install_pip "arjun"                   "arjun"
install_pip "uro"                     "uro"
install_pip "sublist3r"               "sublist3r"
install_pip "dnsgen"                  "dnsgen"
install_pip "bbrf"                    "bbrf"

# --- Library-only (no CLI binary, verify via import) ---
install_pip "mmh3"                    "LIB:mmh3"

# --- PyPI tools that need --ignore-installed for Debian RECORD conflicts ---
install_pip "wtfis"                   "wtfis"               "--ignore-installed"
install_pip "bbot"                    "bbot"                "--ignore-installed"

# --- Git-based tools (NOT on PyPI) ---
install_pip_git "altdns"              "https://github.com/infosec-au/altdns.git"              "altdns"
install_pip_git "cloud_enum"          "https://github.com/initstring/cloud_enum.git"          "cloud_enum"
install_pip_git "s3-inspector"        "https://github.com/vpistis/s3-inspector.git"           "s3inspector"
install_pip_git "SubDomainizer"       "https://github.com/nsonaniya2010/SubDomainizer.git"    "subdomainizer"
install_pip_git "LinkFinder"          "https://github.com/GerbenJavado/LinkFinder.git"        "linkfinder"
install_pip_git "FavFreak"            "https://github.com/devanshbatham/FavFreak.git"         "favfreak"

# SecretFinder — git-based, no setup.py, needs --ignore-installed for urllib3
if ! command -v secretfinder >/dev/null 2>&1; then
    echo "       [git+pip] secretfinder"
    if [ ! -d /opt/SecretFinder ]; then
        git clone --quiet https://github.com/m4ll0k/SecretFinder.git /opt/SecretFinder 2>&1 | tail -1
    fi
    pip3 install --break-system-packages --ignore-installed --quiet -r /opt/SecretFinder/requirements.txt 2>&1 | tail -1
    chmod +x /opt/SecretFinder/SecretFinder.py
    ln -sf /opt/SecretFinder/SecretFinder.py /usr/local/bin/secretfinder
    command -v secretfinder >/dev/null 2>&1 && log_ok "secretfinder" || log_fail "secretfinder" "not on PATH after setup"
else
    log_skip
fi

# EyeWitness — Python tool, git-based, needs --ignore-installed + deps from setup/
if ! command -v eyewitness >/dev/null 2>&1; then
    echo "       [git+pip] eyewitness"
    if [ ! -d /opt/EyeWitness ]; then
        git clone --quiet https://github.com/RedSiege/EyeWitness.git /opt/EyeWitness 2>&1 | tail -1
    fi
    pip3 install --break-system-packages --ignore-installed --quiet -r /opt/EyeWitness/setup/requirements.txt 2>&1 | tail -1
    chmod +x /opt/EyeWitness/Python/EyeWitness.py
    ln -sf /opt/EyeWitness/Python/EyeWitness.py /usr/local/bin/eyewitness
    command -v eyewitness >/dev/null 2>&1 && log_ok "eyewitness" || log_fail "eyewitness" "not on PATH after setup"
else
    log_skip
fi

# cewl — NOT on PyPI; install via apt
if ! command -v cewl >/dev/null 2>&1; then
    echo "       [apt] cewl"
    apt-get install -y -qq cewl 2>&1 | tail -1
    command -v cewl >/dev/null 2>&1 && log_ok "cewl (apt)" || log_fail "cewl" "apt install failed"
else
    log_skip
fi

# cloud_enum deps (needs separate requirements install even after pip install .)
if [ -f /opt/cloud_enum/cloud_enum.py ]; then
    pip3 install --break-system-packages --ignore-installed --quiet -r /opt/cloud_enum/requirements.txt 2>&1 | tail -1 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 5.  npm tools
# ---------------------------------------------------------------------------
log_start "npm-based tools"

install_npm "wappalyzer-cli"         "wappalyzer"
install_npm "retire"                  "retire"

# ---------------------------------------------------------------------------
# 6.  Gem tools
# ---------------------------------------------------------------------------
log_start "Ruby gem tools"

if ! command -v whatweb >/dev/null 2>&1; then
    apt-get install -y -qq whatweb 2>&1 | tail -1 || install_gem "whatweb" "whatweb"
else
    log_skip
fi

# ---------------------------------------------------------------------------
# 7.  Git clone + setup (tools without pip/go install paths)
# ---------------------------------------------------------------------------
log_start "Git-clone tools (no pip/go install path)"

clone_and_install() {
    local name="$1" repo="$2" setup_cmd="$3"
    echo "       [git] $name"
    if [ -d "$target" ]; then
        log_skip
        return 0
    fi
    local target="/opt/$name"
    git clone --quiet "$repo" "$target" 2>&1 | tail -1 || { log_fail "$name" "clone failed"; return 1; }
    if [ -n "$setup_cmd" ] && [ "$setup_cmd" != "none" ]; then
        ( cd "$target" && eval "$setup_cmd" ) 2>&1 | tail -1
    fi
    log_ok "$name → $target"
}

clone_and_install "GCPBucketBrute" \
    "https://github.com/RhinoSecurityLabs/GCPBucketBrute.git" \
    "pip3 install --break-system-packages --quiet -r requirements.txt 2>&1 | tail -1"

clone_and_install "bountycatch" \
    "https://github.com/jhaddix/bountycatch.git" \
    "pip3 install --break-system-packages --quiet -r requirements.txt 2>&1 | tail -1"

# dnsvalidator
echo "       [git] dnsvalidator"
if [ -d /opt/dnsvalidator ]; then
    log_skip
else
    git clone --quiet https://github.com/vortexau/dnsvalidator.git /opt/dnsvalidator 2>&1 | tail -1
    ( cd /opt/dnsvalidator && python3 setup.py install 2>&1 | tail -1 ) || true
    command -v dnsvalidator >/dev/null 2>&1 && log_ok "dnsvalidator" || log_fail "dnsvalidator" "setup.py install had issues"
fi

# ---------------------------------------------------------------------------
# 8.  Post-install: resolvers, templates, verification
# ---------------------------------------------------------------------------
log_start "Post-install steps"

# Nuclei templates
if command -v nuclei >/dev/null 2>&1; then
    log_info "nuclei -update-templates …"
    nuclei -update-templates -silent 2>&1 | tail -1 || true
fi

# Trickest resolvers (single-line curl to avoid line-continuation bugs)
log_info "Downloading trickest resolver lists …"
if curl -sS --connect-timeout 15 -o /opt/resolvers.txt \
    "https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt" 2>&1; then
    log_ok "/opt/resolvers.txt ($(wc -l < /opt/resolvers.txt) resolvers)"
else
    log_fail "resolvers.txt" "download failed"
fi
if curl -sS --connect-timeout 15 -o /opt/resolvers-extended.txt \
    "https://raw.githubusercontent.com/trickest/resolvers/main/resolvers-extended.txt" 2>&1; then
    log_ok "/opt/resolvers-extended.txt"
else
    log_fail "resolvers-extended.txt" "download failed"
fi

# ---------------------------------------------------------------------------
# 9.  Verification & summary
# ---------------------------------------------------------------------------
log_start "Verification"

TOOL_LIST=(
    # Go tools
    subfinder httpx nuclei naabu katana dnsx asnmap shuffledns amass
    gospider hakrawler waybackurls gau assetfinder anew unfurl puredns
    metabigor github-subdomains shosubgo s3scanner trufflehog gitleaks ffuf kr
    gowitness webanalyze
    # pip tools — CLI
    shodan arjun uro sublist3r dnsgen bbrf altdns cloud_enum s3inspector
    subdomainizer linkfinder secretfinder wtfis bbot
    # pip tools — special
    mmh3 eyewitness favfreak cewl
    # npm
    wappalyzer retire
)

declare -A STATUS_MAP
ALL_OK=true

for tool in "${TOOL_LIST[@]}"; do
    case "$tool" in
        mmh3)
            python3 -c "import mmh3" 2>/dev/null && STATUS_MAP[$tool]="OK" || { STATUS_MAP[$tool]="MISS"; ALL_OK=false; }
            ;;
        *)
            command -v "$tool" >/dev/null 2>&1 && STATUS_MAP[$tool]="OK" || { STATUS_MAP[$tool]="MISS"; ALL_OK=false; }
            ;;
    esac
done

echo ""
echo "  Tool                     Status"
echo "  ──────────────────────── ──────"
for tool in "${TOOL_LIST[@]}"; do
    printf "  %-24s %s\n" "$tool" "${STATUS_MAP[$tool]}"
done

echo ""
echo "  ───────────────────────────────"
echo "  Successfully installed : $SUCCESS_COUNT"
echo "  Skipped (already had)  : $SKIP_COUNT"
echo "  Failed                 : $FAIL_COUNT"
echo ""

if [ ${#FAILED_TOOLS[@]} -gt 0 ]; then
    echo "  FAILED TOOLS:"
    for f in "${FAILED_TOOLS[@]}"; do echo "    - $f"; done
    echo ""
fi

if [ -f /opt/resolvers.txt ]; then
    echo "  Resolvers              : OK ($(wc -l < /opt/resolvers.txt) entries)"
else
    echo "  Resolvers              : MISS"
fi

echo ""
echo "  Summary saved to: $SUMMARY_FILE"
echo ""

# Git-clone tools check
echo "  Git-clone directories:"
for d in altdns cloud_enum s3-inspector SubDomainizer LinkFinder SecretFinder \
         EyeWitness FavFreak GCPBucketBrute bountycatch dnsvalidator kiterunner; do
    if [ -d "/opt/$d" ]; then
        echo "    [OK]   /opt/$d"
    else
        echo "    [MISS] /opt/$d"
    fi
done

echo ""
echo "================================================"
echo " INSTALL COMPLETE"
echo "================================================"
