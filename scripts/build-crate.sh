#!/bin/sh
# Builds the crate engine (a fork with vsock) as Crate.xcframework and copies
# it to Frameworks/, where Package.swift's CrateEngine target expects it.
#
#     scripts/build-crate.sh [ENGINE_DIR]    # default ../crate-engine
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
engine=${1:-$root/../crate-engine}
PATH=$HOME/.cargo/bin:$PATH "$engine/tools/xcframework.sh" >&2
rm -rf "$root/Frameworks/Crate.xcframework"
mkdir -p "$root/Frameworks"
cp -R "$engine/target/xcframework/Crate.xcframework" "$root/Frameworks/"
echo "$root/Frameworks/Crate.xcframework"
