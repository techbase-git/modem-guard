#!/bin/bash
# install.sh - installer for the ModemManager-based modem handling package.
#
# Usage: sudo ./install.sh install
#
# Idempotent: existing configuration files are never overwritten, so an
# operator's APN/PIN/GPIO settings survive a reinstall.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODEM_CONF="/etc/modem.conf"
NM_PROFILE="/etc/NetworkManager/system-connections/modem.nmconnection"
UNIT_DIR="/etc/systemd/system"
GUARD_BIN="/usr/sbin/modem-guard"

PACKAGES=(
    modemmanager
    network-manager
    gpiod
    libqmi-utils
    libmbim-utils
    raspi-utils
)

TIMERS=(
    modem-guard.timer
)

log() { echo "[install] $*"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: run this script as root." >&2
        exit 1
    fi
}

install_packages() {
    log "Installing packages: ${PACKAGES[*]}"
    apt-get update
    apt-get install -y "${PACKAGES[@]}"
}

install_units() {
    log "Installing systemd units to $UNIT_DIR"
    install -m 644 systemd/*.service systemd/*.timer "$UNIT_DIR/"
    systemctl daemon-reload
}

install_guard() {
    log "Installing helpers to /usr/sbin"
    install -m 755 bin/modem-guard /usr/sbin/modem-guard
    install -m 755 bin/modem-gpio  /usr/sbin/modem-gpio
}

install_modem_conf() {
    if [ -e "$MODEM_CONF" ]; then
        log "$MODEM_CONF already exists - keeping current settings"
    else
        log "Installing default $MODEM_CONF"
        install -m 644 etc/modem.conf "$MODEM_CONF"
        log "ACTION REQUIRED: set MODEM_POWER_GPIO in $MODEM_CONF"
    fi
}

install_nm_profile() {
    if [ -e "$NM_PROFILE" ]; then
        log "$NM_PROFILE already exists - keeping current settings"
    else
        log "Installing connection profile $NM_PROFILE"
        # NetworkManager silently ignores keyfiles that are not root:root 0600.
        install -m 600 -o root -g root etc/modem.nmconnection.example "$NM_PROFILE"
        log "ACTION REQUIRED: set APN/PIN in $NM_PROFILE, then: nmcli connection reload"
    fi
}

enable_services() {
    log "Enabling services and timers"
    systemctl enable ModemManager.service NetworkManager.service
    systemctl enable --now modem-gpio-init.service
    systemctl enable --now modem-power.service
    systemctl enable --now "${TIMERS[@]}"
}

verify() {
    log "Verifying installation"
    if ! command -v pinctrl >/dev/null; then
        log "WARNING: pinctrl not found in PATH - the GPIO units will fail."
        log "         Check where raspi-utils installed it and adjust the"
        log "         ExecStart paths in $UNIT_DIR/modem-power.service and"
        log "         $UNIT_DIR/modem-hard-reset.service."
    fi
    if ! command -v mmcli >/dev/null; then
        log "WARNING: mmcli not found in PATH."
    fi
    log "Modems seen by ModemManager:"
    mmcli -L || true
}

perform_installation() {
    check_root
    log "=== Installing modem package ==="
    install_packages
    install_units
    install_guard
    install_modem_conf
    install_nm_profile
    enable_services
    verify
    log "=== Done ==="
    log "Next: set the GPIO in $MODEM_CONF and APN/PIN in $NM_PROFILE,"
    log "then reboot or run: systemctl restart modem-power.service && nmcli connection reload"
}

case "${1:-}" in
    install) perform_installation ;;
    *)
        echo "Usage: sudo ./install.sh install"
        exit 1
        ;;
esac
