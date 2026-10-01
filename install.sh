#!/bin/sh
# Installs the latest sapu release.
#
#   curl -fsSL https://raw.githubusercontent.com/idhin/sapu-mac/main/install.sh | sh
#
# Environment:
#   SAPU_BIN_DIR   where to put the binary (default: /usr/local/bin if writable, else ~/.local/bin)
#   SAPU_BASE_URL  where to download from (default: the latest GitHub release)
set -eu

REPO="idhin/sapu-mac"
ARCHIVE="sapu-macos-universal.tar.gz"
BASE_URL="${SAPU_BASE_URL:-https://github.com/$REPO/releases/latest/download}"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "sapu only runs on macOS." >&2
    exit 1
fi

if [ -n "${SAPU_BIN_DIR:-}" ]; then
    bin_dir="$SAPU_BIN_DIR"
elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    bin_dir="/usr/local/bin"
else
    bin_dir="$HOME/.local/bin"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "Downloading $BASE_URL/$ARCHIVE"
curl -fsSL "$BASE_URL/$ARCHIVE" -o "$work/$ARCHIVE"
curl -fsSL "$BASE_URL/$ARCHIVE.sha256" -o "$work/$ARCHIVE.sha256"

expected=$(awk '{print $1}' "$work/$ARCHIVE.sha256")
actual=$(shasum -a 256 "$work/$ARCHIVE" | awk '{print $1}')
if [ "$expected" != "$actual" ]; then
    echo "Checksum mismatch: expected $expected, got $actual." >&2
    exit 1
fi

tar -xzf "$work/$ARCHIVE" -C "$work"
binary=$(find "$work" -type f -name sapu | head -n 1)
if [ -z "$binary" ]; then
    echo "The archive does not contain a sapu binary." >&2
    exit 1
fi

mkdir -p "$bin_dir"
install -m 755 "$binary" "$bin_dir/sapu"
echo "Installed $("$bin_dir/sapu" --version) to $bin_dir/sapu"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "Note: $bin_dir is not on your PATH. Add it, or run $bin_dir/sapu directly." ;;
esac
