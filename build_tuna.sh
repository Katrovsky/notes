#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

WORK_DIR="$(pwd)/tuna_build"
REPO_URL="https://github.com/univrsal/tuna.git"
REPO_DIR="$WORK_DIR/tuna"
OBS_PLUGIN_DIR="$HOME/.config/obs-studio/plugins/tuna"

echo -e "${GREEN}Building Tuna OBS plugin${NC}"
echo "Install directory: $OBS_PLUGIN_DIR"

cleanup() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}Build failed!${NC}"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Distro check
# ---------------------------------------------------------------------------
check_distro() {
    if ! command -v rpm &> /dev/null || ! command -v dnf &> /dev/null; then
        echo -e "${RED}ERROR: This script is designed for Fedora/RHEL-based systems.${NC}"
        echo "It uses 'dnf' and 'rpm'. On Debian/Ubuntu, install equivalents manually:"
        echo "  sudo apt install cmake gcc g++ make pkg-config obs-studio-dev libdbus-1-dev qt6-base-dev"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_and_install_deps() {
    echo "Checking dependencies..."

    local REQUIRED_COMMANDS=("git" "cmake" "gcc" "g++" "make" "pkg-config")
    local FEDORA_PACKAGES=("git" "cmake" "gcc" "gcc-c++" "make" "pkgconfig"
                           "obs-studio-devel" "dbus-devel" "qt6-qtbase-devel")

    local MISSING=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$cmd" &> /dev/null || MISSING+=("$cmd")
    done

    local MISSING_PKGS=()
    for pkg in "obs-studio-devel" "dbus-devel" "qt6-qtbase-devel"; do
        rpm -q "$pkg" &> /dev/null || MISSING_PKGS+=("$pkg")
    done

    if [ ${#MISSING[@]} -gt 0 ] || [ ${#MISSING_PKGS[@]} -gt 0 ]; then
        echo -e "${YELLOW}Installing missing dependencies...${NC}"
        sudo dnf install -y "${FEDORA_PACKAGES[@]}"
    else
        echo -e "${GREEN}✓ All dependencies present${NC}"
    fi
}

# ---------------------------------------------------------------------------
# P-core detection for hybrid CPUs (Intel Alder Lake+, ARM big.LITTLE, etc.)
#
# Strategy:
#   1. Try sysfs core_type attribute (Linux 5.18+, Intel Hybrid driver)
#   2. Fallback: compare cpuinfo_max_freq — P-cores run at noticeably higher
#      frequencies than E-cores, so we keep only cores in the top frequency tier.
#   3. Last resort: use all logical CPUs (same as plain nproc).
#
# Returns a taskset CPU list string like "0,2,4,6" or "" if fallback to all.
# ---------------------------------------------------------------------------
get_pcores() {
    local PCORES=()

    # --- Strategy 1: core_type via sysfs ---
    local ANY_HYBRID=0
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/topology/core_type; do
        [ -f "$cpu_dir" ] || continue
        ANY_HYBRID=1
        local TYPE
        TYPE=$(cat "$cpu_dir")
        if [[ "$TYPE" == *"Performance"* || "$TYPE" == *"P-core"* || "$TYPE" == "1" ]]; then
            # Extract CPU index from path like /sys/.../cpu4/topology/core_type
            local IDX
            IDX=$(echo "$cpu_dir" | grep -oP '(?<=cpu)\d+(?=/topology)')
            PCORES+=("$IDX")
        fi
    done

    if [ "$ANY_HYBRID" -eq 1 ] && [ ${#PCORES[@]} -gt 0 ]; then
        echo "${PCORES[*]}" | tr ' ' ','
        return
    fi

    # --- Strategy 2: max frequency comparison ---
    declare -A FREQ_MAP
    for freq_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_max_freq; do
        [ -f "$freq_file" ] || continue
        local IDX FREQ
        IDX=$(echo "$freq_file" | grep -oP '(?<=cpu)\d+(?=/cpufreq)')
        FREQ=$(cat "$freq_file")
        FREQ_MAP[$IDX]=$FREQ
    done

    if [ ${#FREQ_MAP[@]} -gt 0 ]; then
        # Find the maximum frequency across all cores
        local MAX_FREQ=0
        for f in "${FREQ_MAP[@]}"; do
            (( f > MAX_FREQ )) && MAX_FREQ=$f
        done

        # Keep cores within 10% of max frequency (P-cores tier)
        local THRESHOLD=$(( MAX_FREQ * 90 / 100 ))
        for idx in "${!FREQ_MAP[@]}"; do
            (( FREQ_MAP[$idx] >= THRESHOLD )) && PCORES+=("$idx")
        done

        if [ ${#PCORES[@]} -gt 0 ] && [ ${#PCORES[@]} -lt ${#FREQ_MAP[@]} ]; then
            # Only filter if we actually found a subset (i.e. CPU is hybrid)
            IFS=$'\n' SORTED=($(sort -n <<< "${PCORES[*]}")); unset IFS
            echo "${SORTED[*]}" | tr ' ' ','
            return
        fi
    fi

    # --- Strategy 3: all cores ---
    echo ""
}

# ---------------------------------------------------------------------------
# Determine build parallelism
# ---------------------------------------------------------------------------
get_build_flags() {
    local PCORES
    PCORES=$(get_pcores)

    if [ -n "$PCORES" ]; then
        local COUNT
        COUNT=$(echo "$PCORES" | tr ',' '\n' | wc -l)
        echo -e "${GREEN}Hybrid CPU detected — building on P-cores only: ${PCORES}${NC}"
        # Return as two separate values via stdout lines
        echo "taskset -c $PCORES"
        echo "$COUNT"
    else
        local COUNT
        COUNT=$(nproc)
        echo ""
        echo "$COUNT"
    fi
}

# ---------------------------------------------------------------------------
# OBS running check
# ---------------------------------------------------------------------------
check_obs_running() {
    if pgrep -x "obs" > /dev/null; then
        echo -e "${YELLOW}WARNING: OBS Studio is running!${NC}"
        echo "Please close OBS before installing the plugin."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_distro
check_and_install_deps
check_obs_running

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ -d "$REPO_DIR" ]; then
    echo "Updating repository..."
    cd "$REPO_DIR"
    git pull origin master
    git submodule update --init --recursive
else
    echo "Cloning repository..."
    git clone --recursive "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
fi

BUILD_DIR="$REPO_DIR/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "Configuring project..."
# Explicit install paths so 'make install' places files correctly without
# any post-install reshuffling.
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$OBS_PLUGIN_DIR" \
    -DCMAKE_INSTALL_LIBDIR="bin/64bit" \
    -DCMAKE_INSTALL_DATADIR="data"

# Read parallelism settings (two lines: taskset prefix and core count)
mapfile -t BUILD_OPTS < <(get_build_flags)
TASKSET_PREFIX="${BUILD_OPTS[0]}"
CPU_CORES="${BUILD_OPTS[1]}"

echo "Building project ($CPU_CORES cores)..."
if [ -n "$TASKSET_PREFIX" ]; then
    $TASKSET_PREFIX make -j "$CPU_CORES"
else
    make -j "$CPU_CORES"
fi

echo "Installing to user directory..."
rm -rf "$OBS_PLUGIN_DIR"
mkdir -p "$OBS_PLUGIN_DIR/bin/64bit" "$OBS_PLUGIN_DIR/data"
make install

echo "Verifying installation..."
if [ ! -f "$OBS_PLUGIN_DIR/bin/64bit/tuna.so" ]; then
    echo -e "${YELLOW}tuna.so not found at expected path, searching...${NC}"
    SO_FILE=$(find "$OBS_PLUGIN_DIR" -name "tuna.so" -type f | head -1)
    if [ -z "$SO_FILE" ]; then
        echo -e "${RED}ERROR: tuna.so not found after installation.${NC}"
        exit 1
    fi
    mv "$SO_FILE" "$OBS_PLUGIN_DIR/bin/64bit/tuna.so"
    echo -e "${YELLOW}Moved tuna.so from: $SO_FILE${NC}"
fi

echo -e "${GREEN}✓ Installation complete!${NC}"
echo ""
echo "Plugin installed to: $OBS_PLUGIN_DIR"
echo "Restart OBS Studio to load the plugin."
echo ""
echo "To remove: rm -rf $OBS_PLUGIN_DIR"