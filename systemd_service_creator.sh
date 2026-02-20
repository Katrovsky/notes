#!/bin/bash

set -euo pipefail

show_help() {
cat << HELP
Usage: $0 <executable> [options]
  -n, --name <name>      service name (default: executable basename)
  -c, --config <file>    config file to copy alongside executable
  -h, --help             show this help
HELP
exit 0
}

[ "${EUID}" -ne 0 ] && echo "Run as root" && exit 1
[ $# -lt 1 ] && show_help

EXE="$1"
shift
NAME=""
CFG=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) show_help ;;
    -n|--name) NAME="$2"; shift 2 ;;
    -c|--config) CFG="$2"; shift 2 ;;
    *) echo "Unknown option: $1" && exit 1 ;;
  esac
done

[ -z "$NAME" ] && NAME="$(basename "$EXE")"
DIR="/opt/$NAME"
SVC="/etc/systemd/system/$NAME.service"

[ ! -f "$EXE" ] && echo "File not found: $EXE" && exit 1
[ -n "$CFG" ] && [ ! -f "$CFG" ] && echo "Config not found: $CFG" && exit 1

# ---------------------------------------------------------------------------
# Guard against overwriting an existing service
# ---------------------------------------------------------------------------
if [ -f "$SVC" ] || systemctl list-units --full --all | grep -q "^${NAME}.service"; then
    echo "WARNING: Service '$NAME' already exists."
    read -rp "Overwrite? (y/N): " -n 1 REPLY
    echo
    [[ ! "$REPLY" =~ ^[Yy]$ ]] && echo "Aborted." && exit 0
    systemctl stop "$NAME.service" 2>/dev/null || true
    systemctl disable "$NAME.service" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Dedicated system user
# ---------------------------------------------------------------------------
if ! id "$NAME" &>/dev/null; then
    echo "Creating system user '$NAME'..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "$NAME"
fi

# ---------------------------------------------------------------------------
# Install files
# ---------------------------------------------------------------------------
mkdir -p "$DIR"
cp "$EXE" "$DIR/"
chmod +x "$DIR/$(basename "$EXE")"
chown -R "$NAME:$NAME" "$DIR"

[ -n "$CFG" ] && cp "$CFG" "$DIR/" && chown "$NAME:$NAME" "$DIR/$(basename "$CFG")"

# ---------------------------------------------------------------------------
# Detect shebang to set ExecStart correctly
# ---------------------------------------------------------------------------
EXE_BASENAME="$(basename "$EXE")"
SHEBANG=$(head -1 "$EXE" | grep '^#!' | sed 's/^#!//' | awk '{print $1}' || true)

if [ -n "$SHEBANG" ] && [ "$SHEBANG" != "/bin/sh" ] && [ "$SHEBANG" != "/bin/bash" ]; then
    EXEC_START="$SHEBANG $DIR/$EXE_BASENAME"
    echo "Detected interpreter: $SHEBANG"
else
    EXEC_START="$DIR/$EXE_BASENAME"
fi

# ---------------------------------------------------------------------------
# Write service unit
# ---------------------------------------------------------------------------
cat > "$SVC" << EOF
[Unit]
Description=$NAME service
After=network.target

[Service]
Type=simple
User=$NAME
Group=$NAME
WorkingDirectory=$DIR
ExecStart=$EXEC_START
Restart=always
RestartSec=2
TimeoutStopSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$NAME.service"
systemctl status "$NAME.service" --no-pager

echo ""
echo "Service '$NAME' installed and started."
echo "To remove: systemctl disable --now $NAME && rm -rf $DIR $SVC && userdel $NAME"