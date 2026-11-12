#!/usr/bin/env bash
# Ubuntu 24.04 desktop-test dependencies, independent of the runner's extra APT repositories.
set -euo pipefail

case "${1:-}" in
    update|install) phase=$1 ;;
    *) echo "usage: $0 update|install" >&2; exit 2 ;;
esac
# shellcheck source=/dev/null
. /etc/os-release
if [[ $ID != ubuntu || $VERSION_ID != 24.04 || $(dpkg --print-architecture) != amd64 ]]; then
    echo 'Desktop CI setup requires Ubuntu 24.04 amd64.' >&2
    exit 1
fi

apt_work=$(mktemp -d)
trap 'rm -rf "$apt_work"' EXIT
mkdir "$apt_work/empty"
cat > "$apt_work/ubuntu.list" <<'SOURCES'
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
SOURCES
apt_options=(
    -o "Dir::Etc::SourceList=$apt_work/ubuntu.list"
    -o "Dir::Etc::SourceParts=$apt_work/empty"
    -o Acquire::Retries=2
    -o Acquire::http::Timeout=20
    -o Acquire::https::Timeout=20
    -o DPkg::Lock::Timeout=30
)
export DEBIAN_FRONTEND=noninteractive
if [[ $phase == update ]]; then
    apt-get "${apt_options[@]}" --error-on=any update
else
    apt-get "${apt_options[@]}" --yes --no-install-recommends install \
        binutils curl wget git python3 xvfb openbox xdotool x11-utils sway weston \
        gcc pkg-config libwayland-dev wayland-protocols strace zsh fish tcsh dbus \
        xsettingsd xdg-desktop-portal xdg-desktop-portal-gtk dconf-service dconf-cli \
        libglib2.0-bin gsettings-desktop-schemas xkb-data ibus ibus-hangul fonts-nanum \
        fonts-droid-fallback
fi
