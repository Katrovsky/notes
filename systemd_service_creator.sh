#!/bin/bash
set -e

show_help() {
cat << 'HELP'
Usage: $0 <executable> [options]
  -n, --name <name>      service name (default: executable basename)
  -c, --config <file>    config file to copy alongside executable
  -h, --help             show this help
HELP
exit 0
}

[ $EUID -ne 0 ] && echo "Run as root" && exit 1
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

mkdir -p "$DIR"
cp "$EXE" "$DIR/"
chmod +x "$DIR/$(basename "$EXE")"
[ -n "$CFG" ] && cp "$CFG" "$DIR/"

cat > "$SVC" << EOF
[Unit]
Description=$NAME service
After=network.target

[Service]
Type=simple
WorkingDirectory=$DIR
ExecStart=$DIR/$(basename "$EXE")
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$NAME.service"
systemctl status "$NAME.service" --no-pager
