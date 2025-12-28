#!/bin/bash

set -e

WORK_DIR="$(pwd)/tuna_build"
REPO_URL="https://github.com/univrsal/tuna.git"
REPO_DIR="$WORK_DIR/tuna"
OBS_PLUGIN_DIR="$HOME/.config/obs-studio/plugins/tuna"

echo "Building Tuna OBS plugin"
echo "Install directory: $OBS_PLUGIN_DIR"

if ! command -v git &> /dev/null; then
    echo "Error: Install git: sudo dnf install git"
    exit 1
fi

if ! command -v cmake &> /dev/null; then
    echo "Error: Install cmake: sudo dnf install cmake"
    exit 1
fi

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ -d "$REPO_DIR" ]; then
    echo "Updating repository..."
    cd "$REPO_DIR"
    git pull origin master
    git submodule update --init --recursive
else
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
cmake .. -DCMAKE_INSTALL_PREFIX="$OBS_PLUGIN_DIR"

CPU_CORES=$(nproc --all 2>/dev/null || echo "2")
echo "Building project ($CPU_CORES cores)..."
make -j "$CPU_CORES"

echo "Installing to user directory..."

if [ -d "$OBS_PLUGIN_DIR" ]; then
    echo "Removing old plugin version..."
    rm -rf "$OBS_PLUGIN_DIR"
fi

mkdir -p "$OBS_PLUGIN_DIR/bin/64bit"
mkdir -p "$OBS_PLUGIN_DIR/data"

INSTALL_LOG="$(mktemp)"
if make install 2>&1 | tee "$INSTALL_LOG"; then
    echo "Installation complete!"
    
    echo "Checking installation structure..."
    
    SO_FILE=$(find "$OBS_PLUGIN_DIR" -name "tuna.so" -type f)
    if [ -n "$SO_FILE" ] && [ "$SO_FILE" != "$OBS_PLUGIN_DIR/bin/64bit/tuna.so" ]; then
        echo "Moving $SO_FILE -> $OBS_PLUGIN_DIR/bin/64bit/tuna.so"
        mv "$SO_FILE" "$OBS_PLUGIN_DIR/bin/64bit/tuna.so"
    fi
    
    if [ -d "$OBS_PLUGIN_DIR/share/obs/obs-plugins/tuna" ]; then
        echo "Moving plugin data..."
        mv "$OBS_PLUGIN_DIR/share/obs/obs-plugins/tuna/"* "$OBS_PLUGIN_DIR/data/" 2>/dev/null || true
        rm -rf "$OBS_PLUGIN_DIR/share"
    fi
    
    if [ -d "$OBS_PLUGIN_DIR/lib64/obs-plugins" ]; then
        SO_FILE=$(find "$OBS_PLUGIN_DIR/lib64/obs-plugins" -name "tuna.so" -type f)
        if [ -n "$SO_FILE" ]; then
            echo "Moving $SO_FILE -> $OBS_PLUGIN_DIR/bin/64bit/tuna.so"
            mv "$SO_FILE" "$OBS_PLUGIN_DIR/bin/64bit/tuna.so"
        fi
        rm -rf "$OBS_PLUGIN_DIR/lib64"
    fi
    
    echo "Final structure:"
    tree "$OBS_PLUGIN_DIR" 2>/dev/null || find "$OBS_PLUGIN_DIR" -type f | sort
    
    rm -f "$INSTALL_LOG"
else
    echo "Installation error!"
    rm -f "$INSTALL_LOG"
    exit 1
fi

echo ""
echo "Plugin installed to: $OBS_PLUGIN_DIR"
echo "Restart OBS Studio to load the plugin."
echo ""
echo "To remove plugin:"
echo "rm -rf $OBS_PLUGIN_DIR"