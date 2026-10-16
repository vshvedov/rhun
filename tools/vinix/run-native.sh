#!/bin/sh
# Launch the experiment in a native Vinix desktop window.
set -eu
base=${RHUN_VINIX_DIR:-/root/rhun-vinix}
mkdir -p "$base/home"
export HOME="$base/home"
if [ "$#" -eq 0 ] && [ -d "$base/project" ]; then
    cd "$base/project"
    set -- "$base/project"
fi
exec "${RHUN_VINIX_BIN:-$base/rhun-native}" --wait --empty "$@"
