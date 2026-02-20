# notes

A collection of personal scripts and utilities.

## Scripts

### `build_tuna.sh`

Builds and installs the [Tuna](https://github.com/univrsal/tuna) OBS Studio plugin
from source. Designed for Fedora/RHEL-based systems. Installs to
`~/.config/obs-studio/plugins/tuna`.

**Usage:** `bash build_tuna.sh`

### `systemd_service_creator.sh`

Creates and enables a systemd service for a given executable. Copies the binary
(and optionally a config file) to `/opt/<name>/` and registers it as a
persistent service.

**Usage:** `sudo bash systemd_service_creator.sh <executable> [-n name] [-c config]`
