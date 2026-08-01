#!/bin/sh
# Builds the Rust static library for the Apple slice Xcode is currently
# building, and leaves one fat archive at $BUILT_PRODUCTS_DIR/librk_quic.a.
#
# WHY A STATIC LIBRARY AND NOT A DYLIB, WHICH IS WHAT WINDOWS AND LINUX GET.
#
# Flutter's Podfile templates carry `use_frameworks!`
# (templates/cocoapods/Podfile-ios-swift, Podfile-macos). A pod built that way
# becomes `rk_quic.framework`, and Dart opens it as
# `rk_quic.framework/rk_quic` — a single Mach-O binary. So the cargo artefact
# has to end up *inside* that binary. On Windows and Linux it was enough to
# hand CMake an absolute path and let the tool copy the file next to the
# runner; here there is no "next to".
#
# A static archive plus `-force_load` in OTHER_LDFLAGS does exactly that: the
# linker pulls every object, including the ones nothing references, into the
# framework binary. Without `-force_load` the whole crate would be dropped,
# because no Objective-C or Swift code calls it — the caller is Dart, at
# runtime, by name.
#
# NOT VERIFIED BY A BUILD. There is no Mac on this project. Everything above is
# read off the tools; the file is here so the Apple path is a stated design
# with a named failure mode rather than a blank.
#
# The likeliest failure is NOT any of the above. It is `aws-lc-sys`, which
# builds C and needs CMake and a compiler it can find for the target. On
# Android the same step works only once both CARGO_TARGET_<TRIPLE>_LINKER and
# AR_<triple> are set — without the second, `cc-rs` looks for a tool named
# `<triple>-ar` that the NDK does not ship, and the error names a program
# rather than the missing variable. Expect the same shape here under different
# names, and set them below rather than in someone's ~/.cargo/config.toml.

set -eu

CRATE_DIR="$(cd "$(dirname "$0")/../rust" && pwd)"
TARGET_DIR="${CARGO_TARGET_DIR:-$CRATE_DIR/target}"

: "${PLATFORM_NAME:?PLATFORM_NAME is set by Xcode; this script only runs from a pod script phase}"
: "${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR is set by Xcode}"
: "${ARCHS:?ARCHS is set by Xcode}"

if [ "${CONFIGURATION:-Release}" = "Debug" ]; then
  CARGO_PROFILE_ARG=""
  PROFILE_DIR="debug"
else
  CARGO_PROFILE_ARG="--release"
  PROFILE_DIR="release"
fi

# Xcode names a platform and a list of architectures; cargo wants triples.
# Nothing keeps the two lists in step, so an unmapped combination stops here
# rather than producing an archive with a missing slice.
triple_for() {
  arch="$1"
  case "$PLATFORM_NAME:$arch" in
    macosx:arm64)            echo aarch64-apple-darwin ;;
    macosx:x86_64)           echo x86_64-apple-darwin ;;
    iphoneos:arm64)          echo aarch64-apple-ios ;;
    iphonesimulator:arm64)   echo aarch64-apple-ios-sim ;;
    iphonesimulator:x86_64)  echo x86_64-apple-ios ;;
    *)
      echo "rk_quic: no Rust triple for PLATFORM_NAME=$PLATFORM_NAME arch=$arch" >&2
      exit 1
      ;;
  esac
}

SLICES=""
for arch in $ARCHS; do
  triple="$(triple_for "$arch")"
  rustup target add "$triple" >/dev/null 2>&1 || true
  ( cd "$CRATE_DIR" && cargo build $CARGO_PROFILE_ARG --target "$triple" --target-dir "$TARGET_DIR" )
  SLICES="$SLICES $TARGET_DIR/$triple/$PROFILE_DIR/librk_quic.a"
done

mkdir -p "$BUILT_PRODUCTS_DIR"
# `lipo -create` with a single input is a copy, so the one-arch case needs no
# special handling.
# shellcheck disable=SC2086
lipo -create $SLICES -output "$BUILT_PRODUCTS_DIR/librk_quic.a"
