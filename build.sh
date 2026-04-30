#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

build_one() {
  local scheme="$1"
  unset THEOS_PACKAGE_SCHEME
  [[ "$scheme" == "rootless" ]] && export THEOS_PACKAGE_SCHEME=rootless
  make clean
  make package FINALPACKAGE=1
}

build_one rootful
build_one rootless
ls -1 packages/*.deb
