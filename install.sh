#!/bin/sh
# Nyxe Drive CLI installer. Downloads the right prebuilt `ndrive` binary from the latest
# GitHub Release and installs it. Usage:
#
#   curl -fsSL https://drive.nyxe.app/install | sh
#
# Override the install dir with NDRIVE_INSTALL_DIR, or a specific version with
# NDRIVE_VERSION=cli-v0.1.1. No Rust toolchain required.
set -eu

# Public releases repo (the source repo is private/closed; binaries + this script
# live here so anonymous users can download them).
REPO="raymond-UI/nyxe-drive-releases"

err() { printf 'install: %s\n' "$1" >&2; exit 1; }

# --- detect platform → release target triple -------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Darwin) os_part="apple-darwin" ;;
  Linux)  os_part="unknown-linux-musl" ;;
  *) err "unsupported OS '$os' (macOS and Linux only; on Windows use WSL)" ;;
esac
case "$arch" in
  arm64|aarch64) arch_part="aarch64" ;;
  x86_64|amd64)  arch_part="x86_64" ;;
  *) err "unsupported architecture '$arch'" ;;
esac
target="${arch_part}-${os_part}"

# --- the app's own ndrive ----------------------------------------------------
# The Nyxe Drive app for macOS puts its own ndrive on the PATH, as a link into
# the app, and keeps it up to date with the app. Leave that link alone unless
# asked for a version or a folder: the app's copy is the one to use. (The app
# replaces a command of its own version or older with its link, and keeps a
# newer one.)
app_link() {
  [ -L "$1/ndrive" ] && [ -e "$1/ndrive" ] || return 1
  to="$(readlink "$1/ndrive")"
  case "$to" in /*) ;; *) to="$1/$to" ;; esac
  case "$to" in *.app/Contents/MacOS/ndrive) ;; *) return 1 ;; esac
  grep -q '<string>app.nyxe.drive</string>' "${to%/MacOS/ndrive}/Info.plist" 2>/dev/null
}
if [ -z "${NDRIVE_VERSION:-}" ] && [ -z "${NDRIVE_INSTALL_DIR:-}" ]; then
  for d in /usr/local/bin "$HOME/.local/bin"; do
    if app_link "$d"; then
      printf 'The Nyxe Drive app already gives you ndrive at %s/ndrive, and keeps it up to date.\n' "$d"
      printf 'To install the command on its own anyway, set NDRIVE_INSTALL_DIR.\n'
      printf 'Get started:  ndrive login\n'
      exit 0
    fi
  done
fi

# --- resolve the release tag -----------------------------------------------
tag="${NDRIVE_VERSION:-}"
if [ -z "$tag" ]; then
  # Resolve the latest tag from the releases/latest REDIRECT on github.com, NOT
  # the api.github.com endpoint: the API caps anonymous callers at 60 requests/hr
  # PER IP, which a shared/NAT'd network (office, CI, café) can exhaust — turning
  # `curl | sh` into a 403. The web redirect (…/releases/latest →
  # …/releases/tag/<tag>) has no such limit. Fall back to the API only if the
  # redirect yields nothing.
  tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      "https://github.com/${REPO}/releases/latest" 2>/dev/null \
    | sed -n 's#.*/releases/tag/##p' | tr -d '\r')"
  # This repo also carries the macOS app (`app-v*`) and its Sparkle feed
  # (`appcast-mac`). Neither holds an `ndrive` tarball, so a tag outside the
  # `cli-v*` namespace is not an answer to this question — fall through and ask
  # for the CLI's own newest release rather than 404 on an asset that was never
  # in there. `gh release create --latest=false` on the app side should keep the
  # redirect off those tags; this is the belt to that suspenders.
  case "$tag" in cli-v*) ;; *) tag="" ;; esac
  if [ -z "$tag" ]; then
    tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=100" \
      | grep '"tag_name"' | cut -d'"' -f4 | grep '^cli-v' | head -1)"
  fi
  [ -n "$tag" ] || err "could not find the latest release (set NDRIVE_VERSION to pin one)"
fi

asset="ndrive-${target}.tar.gz"
url="https://github.com/${REPO}/releases/download/${tag}/${asset}"

# --- download + verify + install -------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'Downloading %s (%s)…\n' "$asset" "$tag"
curl -fsSL "$url" -o "$tmp/$asset" || err "download failed: $url"

# Best-effort checksum verification if the .sha256 is published.
if curl -fsSL "${url}.sha256" -o "$tmp/$asset.sha256" 2>/dev/null; then
  ( cd "$tmp" && (sha256sum -c "$asset.sha256" >/dev/null 2>&1 \
      || shasum -a 256 -c "$asset.sha256" >/dev/null 2>&1) ) \
    || err "checksum verification failed"
fi

tar -xzf "$tmp/$asset" -C "$tmp"

# Pick a writable install dir.
dest="${NDRIVE_INSTALL_DIR:-}"
if [ -z "$dest" ]; then
  if [ -w /usr/local/bin ] 2>/dev/null; then dest="/usr/local/bin"; else dest="$HOME/.local/bin"; fi
fi
mkdir -p "$dest"
mv "$tmp/ndrive-${target}/ndrive" "$dest/ndrive"
chmod +x "$dest/ndrive"

printf '\nInstalled ndrive %s to %s/ndrive\n' "$tag" "$dest"
case ":$PATH:" in
  *":$dest:"*) ;;
  *) printf 'Add it to your PATH:  export PATH="%s:$PATH"\n' "$dest" ;;
esac
printf 'Get started:  ndrive login\n'
