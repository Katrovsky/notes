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

check_and_install_deps() {
    echo "Checking dependencies..."
    
    REQUIRED_COMMANDS=("git" "cmake" "gcc" "g++" "make" "pkg-config")
    FEDORA_PACKAGES=("git" "cmake" "gcc" "gcc-c++" "make" "pkgconfig" "obs-studio-devel" "dbus-devel" "qt6-qtbase-devel")
    
    MISSING_COMMANDS=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            MISSING_COMMANDS+=("$cmd")
        fi
    done
    
    MISSING_PACKAGES=()
    for pkg in "obs-studio-devel" "dbus-devel" "qt6-qtbase-devel"; do
        if ! rpm -q "$pkg" &> /dev/null 2>&1; then
            MISSING_PACKAGES+=("$pkg")
        fi
    done
    
    if [ ${#MISSING_COMMANDS[@]} -gt 0 ] || [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
        echo -e "${YELLOW}Installing missing dependencies...${NC}"
        sudo dnf install -y "${FEDORA_PACKAGES[@]}"
    else
        echo -e "${GREEN}✓ All dependencies present${NC}"
    fi
}

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

if [ -d "$BUILD_DIR" ]; then
    echo "Removing old build..."
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "Configuring project..."
cmake .. \
    -DCMAKE_INSTALL_PREFIX="$OBS_PLUGIN_DIR" \
    -DCMAKE_BUILD_TYPE=Release

CPU_CORES=$(nproc --all 2>/dev/null || echo "2")
echo "Building project ($CPU_CORES cores)..."

if ! make -j "$CPU_CORES"; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi

echo "Installing to user directory..."

if [ -d "$OBS_PLUGIN_DIR" ]; then
    echo "Removing old plugin version..."
    rm -rf "$OBS_PLUGIN_DIR"
fi

mkdir -p "$OBS_PLUGIN_DIR/bin/64bit"
mkdir -p "$OBS_PLUGIN_DIR/data"

if ! make install; then
    echo -e "${RED}Installation failed!${NC}"
    exit 1
fi

echo "Organizing plugin structure..."

SO_FILE=$(find "$OBS_PLUGIN_DIR" -name "tuna.so" -type f | head -1)
if [ -n "$SO_FILE" ] && [ "$SO_FILE" != "$OBS_PLUGIN_DIR/bin/64bit/tuna.so" ]; then
    mv "$SO_FILE" "$OBS_PLUGIN_DIR/bin/64bit/tuna.so"
fi

if [ -d "$OBS_PLUGIN_DIR/share/obs/obs-plugins/tuna" ]; then
    mv "$OBS_PLUGIN_DIR/share/obs/obs-plugins/tuna/"* "$OBS_PLUGIN_DIR/data/" 2>/dev/null || true
    rm -rf "$OBS_PLUGIN_DIR/share"
fi

if [ -d "$OBS_PLUGIN_DIR/lib64/obs-plugins" ]; then
    SO_FILE=$(find "$OBS_PLUGIN_DIR/lib64/obs-plugins" -name "tuna.so" -type f | head -1)
    if [ -n "$SO_FILE" ]; then
        mv "$SO_FILE" "$OBS_PLUGIN_DIR/bin/64bit/tuna.so"
    fi
    rm -rf "$OBS_PLUGIN_DIR/lib64"
fi

echo "Verifying installation..."
if [ ! -f "$OBS_PLUGIN_DIR/bin/64bit/tuna.so" ]; then
    echo -e "${RED}ERROR: tuna.so not found after installation${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Installation complete!${NC}"
echo ""
echo "Plugin installed to: $OBS_PLUGIN_DIR"
echo "Restart OBS Studio to load the plugin."
echo ""
echo "To remove plugin: rm -rf $OBS_PLUGIN_DIR"
