#!/bin/sh
# get.sh - install vmbench from a GitHub release. POSIX sh. No sudo, no packages are installed.
#
#   curl -fsSL https://raw.githubusercontent.com/chaloemph/vmbench/main/get.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/chaloemph/vmbench/main/get.sh | sh -s -- --version v0.1.0
#
# Read it first if you like: curl -fsSLO <url above>; less get.sh; sh get.sh
#
# What it does:
#   1. finds the release (the newest one, or the one you pin) and downloads vmbench-<version>.tar.gz and SHA256SUMS
#   2. checks the sha256 of the tarball; on a mismatch it stops and extracts nothing
#   3. lists the tarball and refuses absolute paths, "..", and links, then extracts it
#   4. installs into <prefix>/<version>, points <prefix>/current at it, links ~/.local/bin/vmbench to current
# Everything is inside your home folder. The whole script is one function called on the last line, so a
# download that is cut short runs nothing.
#
# Options (environment variable in brackets):
#   --version V     release tag, for example v0.1.0 (VMBENCH_VERSION, default: latest). Anything that is not a
#                   release tag such as main or a commit is installed from the GitHub source archive, which
#                   has no checksum file (a warning says so)
#   --prefix DIR    where versions live (VMBENCH_HOME, default ~/.local/share/vmbench)
#   --dir DIR       install exactly into DIR (no <version> subfolder, no "current" link)
#   --bin-dir DIR   where the vmbench symlink goes (VMBENCH_BIN_DIR, default ~/.local/bin)
#   --uninstall     remove the install (with --version: only that version)
#   --dry-run       print every action, change nothing (nothing is downloaded either)
#   --allow-root    allow running as root (refused by default)
#   -h, --help      this text
# Other environment: VMBENCH_REPO (default chaloemph/vmbench), VMBENCH_BASE_URL and VMBENCH_LATEST_URL
# (replace the GitHub download and "latest" URLs, for a mirror or the tests; any scheme is then allowed).
#
# Exit codes: 0 done, 1 failed (nothing half-installed), 2 usage error.

usage() {
  cat <<'USAGE'

  curl -fsSL https://raw.githubusercontent.com/chaloemph/vmbench/main/get.sh | sh
  curl -fsSL https://raw.githubusercontent.com/chaloemph/vmbench/main/get.sh | sh -s -- --version v0.1.0

Read it first if you like: curl -fsSLO <url above>; less get.sh; sh get.sh

What it does:
  1. finds the release (the newest one, or the one you pin) and downloads vmbench-<version>.tar.gz and SHA256SUMS
  2. checks the sha256 of the tarball; on a mismatch it stops and extracts nothing
  3. lists the tarball and refuses absolute paths, "..", and links, then extracts it
  4. installs into <prefix>/<version>, points <prefix>/current at it, links ~/.local/bin/vmbench to current
Everything is inside your home folder. The whole script is one function called on the last line, so a
download that is cut short runs nothing.

Options (environment variable in brackets):
  --version V     release tag, for example v0.1.0 (VMBENCH_VERSION, default: latest). Anything that is not a
                  release tag such as main or a commit is installed from the GitHub source archive, which
                  has no checksum file (a warning says so)
  --prefix DIR    where versions live (VMBENCH_HOME, default ~/.local/share/vmbench)
  --dir DIR       install exactly into DIR (no <version> subfolder, no "current" link)
  --bin-dir DIR   where the vmbench symlink goes (VMBENCH_BIN_DIR, default ~/.local/bin)
  --uninstall     remove the install (with --version: only that version)
  --dry-run       print every action, change nothing (nothing is downloaded either)
  --allow-root    allow running as root (refused by default)
  -h, --help      this text
Other environment: VMBENCH_REPO (default chaloemph/vmbench), VMBENCH_BASE_URL and VMBENCH_LATEST_URL
(replace the GitHub download and "latest" URLs, for a mirror or the tests; any scheme is then allowed).

Exit codes: 0 done, 1 failed (nothing half-installed), 2 usage error.
USAGE
}

say() { printf '%s\n' "$*"; }
err() { printf 'get.sh: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
usage_error() { err "$*"; err "try: sh get.sh --help"; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

# act "text" cmd args...: print the action in a dry run, run it otherwise
act() {
  _text=$1; shift
  if [ "$DRY" = 1 ]; then say "[dry-run] $_text"; else "$@"; fi
}

download() { # url dest
  if have curl; then
    if [ -n "$INSECURE_URL" ]; then curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"
    else curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 -o "$2" "$1"; fi
  else
    wget -q --tries=3 --timeout=15 -O "$2" "$1"
  fi
}

sha256_of() { # file -> hash
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

check_tools() {
  _missing=""
  have curl || have wget || _missing="$_missing curl(or wget)"
  have tar || _missing="$_missing tar"
  have sha256sum || have shasum || _missing="$_missing sha256sum(or shasum)"
  have mktemp || _missing="$_missing mktemp"
  if [ -n "$_missing" ]; then
    err "missing tools:$_missing"
    err "install them first, for example: sudo apt-get install -y curl tar coreutils"
    exit 1
  fi
}

resolve_latest() { # prints the tag of the newest release
  _lurl=${VMBENCH_LATEST_URL:-https://github.com/$REPO/releases/latest}
  if have curl; then
    if [ -n "$INSECURE_URL" ]; then
      _eff=$(curl -fsSIL --retry 3 --connect-timeout 15 -o /dev/null -w '%{url_effective}' "$_lurl") || _eff=""
    else
      _eff=$(curl -fsSIL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 -o /dev/null -w '%{url_effective}' "$_lurl") || _eff=""
    fi
  else
    # wget: follow no redirect, read the Location header
    _eff=$(wget -q -S --spider --max-redirect=0 "$_lurl" 2>&1 | sed -n 's/^ *[Ll]ocation: *//p' | head -1 | tr -d '\r')
  fi
  case $_eff in
    */releases/tag/?*) printf '%s\n' "${_eff##*/}" ;;
    *)
      err "could not find a release of $REPO (looked at $_lurl, got: ${_eff:-nothing})"
      err "there may be no release yet. Nothing was installed."
      err "to install a specific release:     VMBENCH_VERSION=v0.1.0   (or --version v0.1.0)"
      err "to install the development branch: VMBENCH_VERSION=main     (or a commit id; no checksum file exists for these)"
      err "or use a clone:                    git clone https://github.com/$REPO.git"
      return 1 ;;
  esac
}

valid_version() {
  case $1 in
    ""|-*|.*|*[!A-Za-z0-9._-]*|*..*) return 1 ;;
  esac
}

# refuse tarballs that could write outside the target: absolute paths, "..", links
check_tar_list() { # tarball
  _list=$(tar -tzf "$1") || { err "cannot read the tarball (not a valid .tar.gz)"; return 1; }
  [ -n "$_list" ] || { err "the tarball is empty"; return 1; }
  if printf '%s\n' "$_list" | grep -Eq '^/|(^|/)\.\.(/|$)|[[:cntrl:]]'; then
    err "the tarball contains an absolute path, a '..' path or a control character; refusing to extract it"
    return 1
  fi
  if tar -tvzf "$1" | cut -c1 | grep -Eq '^[lh]$'; then
    err "the tarball contains a symlink or hard link; refusing to extract it"
    return 1
  fi
}

looks_like_install() { # dir: only delete folders that are vmbench
  [ -f "$1/vmbench" ] && [ -f "$1/lib/common.sh" ]
}

link_target() { readlink "$1" 2>/dev/null; }

do_uninstall() {
  if [ -n "$DIR" ]; then
    if [ -d "$DIR" ]; then
      looks_like_install "$DIR" || die "$DIR does not look like a vmbench install (no vmbench and lib/common.sh); not deleting it"
      act "rm -rf $DIR" rm -rf "$DIR"
    else say "nothing to remove: $DIR does not exist"; fi
    remove_bin_link "$DIR"
    return 0
  fi
  if [ -n "$VERSION_ARG" ]; then
    _vdir=$PREFIX/$VERSION_ARG
    valid_version "$VERSION_ARG" || usage_error "bad version '$VERSION_ARG'"
    if [ -d "$_vdir" ]; then
      looks_like_install "$_vdir" || die "$_vdir does not look like a vmbench install; not deleting it"
      act "rm -rf $_vdir" rm -rf "$_vdir"
    else say "nothing to remove: $_vdir does not exist"; fi
    if [ "$(link_target "$PREFIX/current")" = "$_vdir" ]; then
      act "rm $PREFIX/current" rm -f "$PREFIX/current"
      remove_bin_link "$PREFIX/current"
    fi
    return 0
  fi
  if [ -d "$PREFIX" ]; then
    [ -f "$PREFIX/.vmbench-install" ] || die "$PREFIX has no .vmbench-install marker, so it was not made by get.sh; not deleting it"
    act "rm -rf $PREFIX" rm -rf "$PREFIX"
  else say "nothing to remove: $PREFIX does not exist"; fi
  remove_bin_link "$PREFIX/current"
}

remove_bin_link() { # dir the link must point into (or to)
  _bl=$BINDIR/vmbench
  _t=$(link_target "$_bl")
  case $_t in
    "$1"|"$1"/*) act "rm $_bl" rm -f "$_bl" ;;
    "") [ -e "$_bl" ] && say "left $_bl alone (not a symlink made by get.sh)" ;;
    *) say "left $_bl alone (it points to $_t, not into $1)" ;;
  esac
  return 0
}

do_install() {
  if [ "$VERSION" = latest ]; then
    say "resolving the latest release of $REPO ..."
    VERSION=$(resolve_latest) || exit 1
    say "latest release is $VERSION"
  fi
  valid_version "$VERSION" || usage_error "bad version '$VERSION' (use a tag such as v0.1.0, or main, or a commit id)"

  case $VERSION in
    v[0-9]*) KIND=release ;;
    *) KIND=ref ;;
  esac
  NAME=vmbench-$VERSION.tar.gz
  if [ "$KIND" = release ]; then
    BASE=${VMBENCH_BASE_URL:-https://github.com/$REPO/releases/download}/$VERSION
    TARBALL_URL=$BASE/$NAME
    SUMS_URL=$BASE/SHA256SUMS
  else
    TARBALL_URL=${VMBENCH_BASE_URL:-https://codeload.github.com/$REPO/tar.gz}/$VERSION
    SUMS_URL=""
    err "WARNING: '$VERSION' is not a release. It is installed from the GitHub source archive, which has no SHA256SUMS,"
    err "         so only HTTPS protects it, and a branch name can change under you. Prefer a release tag."
  fi

  if [ -n "$DIR" ]; then DEST=$DIR; else DEST=$PREFIX/$VERSION; fi

  if [ "$DRY" = 1 ]; then
    say "[dry-run] version:        $VERSION ($KIND)"
    say "[dry-run] download:       $TARBALL_URL"
    [ -n "$SUMS_URL" ] && say "[dry-run] download:       $SUMS_URL"
    say "[dry-run] verify:         sha256 of $NAME against SHA256SUMS (stop on mismatch, extract nothing)"
    say "[dry-run] check:          tar -tzf listing has no absolute path, '..' or links"
    say "[dry-run] install into:   $DEST"
    [ -z "$DIR" ] && say "[dry-run] symlink:         $PREFIX/current -> $DEST"
    if [ -z "$DIR" ]; then say "[dry-run] symlink:         $BINDIR/vmbench -> $PREFIX/current/vmbench"
    else say "[dry-run] symlink:         $BINDIR/vmbench -> $DEST/vmbench"; fi
    say "[dry-run] nothing was changed"
    return 0
  fi

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/vmbench-get.XXXXXX") || die "cannot make a temporary folder"
  trap 'rm -rf "$WORK"' EXIT HUP INT TERM

  say "downloading $TARBALL_URL"
  download "$TARBALL_URL" "$WORK/$NAME" || die "download failed: $TARBALL_URL (is $VERSION a real release?)"

  if [ -n "$SUMS_URL" ]; then
    download "$SUMS_URL" "$WORK/SHA256SUMS" || die "download failed: $SUMS_URL"
    want=$(awk -v f="$NAME" '($2 == f || $2 == "*" f) { print $1 }' "$WORK/SHA256SUMS")
    [ -n "$want" ] || die "$NAME is not listed in SHA256SUMS of $VERSION"
    [ "$(printf '%s\n' "$want" | wc -l | tr -d ' ')" = 1 ] || die "$NAME is listed more than once in SHA256SUMS"
    got=$(sha256_of "$WORK/$NAME")
    if [ "$got" != "$want" ]; then
      err "CHECKSUM MISMATCH for $NAME"
      err "  expected $want"
      err "  got      $got"
      die "refusing to install; nothing was extracted"
    fi
    say "sha256 ok: $got"
  fi

  check_tar_list "$WORK/$NAME" || die "refusing to install; nothing was extracted"
  mkdir -p "$WORK/x" || die "cannot make $WORK/x"
  tar -xzf "$WORK/$NAME" -C "$WORK/x" --strip-components=1 --no-same-owner \
    || die "extraction failed; nothing was installed"
  looks_like_install "$WORK/x" || die "the tarball is not a vmbench release (no vmbench and lib/common.sh at its top level)"
  [ -s "$WORK/x/VERSION" ] || printf '%s\n' "$VERSION" > "$WORK/x/VERSION"

  mkdir -p "$(dirname "$DEST")" "$BINDIR" || die "cannot create the install folders"
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    looks_like_install "$DEST" || die "$DEST exists and is not a vmbench install; not replacing it"
    say "replacing the existing $DEST"
    rm -rf "$DEST"
  fi
  mv "$WORK/x" "$DEST" || die "cannot move the files to $DEST"
  if [ -z "$DIR" ]; then
    : > "$PREFIX/.vmbench-install"
    ln -sfn "$DEST" "$PREFIX/current" || die "cannot link $PREFIX/current"
    LINKTO=$PREFIX/current/vmbench
  else
    LINKTO=$DEST/vmbench
  fi
  if [ -e "$BINDIR/vmbench" ] && [ ! -L "$BINDIR/vmbench" ]; then
    err "$BINDIR/vmbench exists and is not a symlink; left untouched"
  else
    ln -sfn "$LINKTO" "$BINDIR/vmbench" || die "cannot link $BINDIR/vmbench"
  fi

  say "installed vmbench $VERSION in $DEST"
  say "linked $BINDIR/vmbench -> $LINKTO"
  case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) err "note: $BINDIR is not in your PATH. Add this to your shell profile:  export PATH=\"$BINDIR:\$PATH\"" ;;
  esac
  _need=""
  for t in bash python3 curl jq; do have "$t" || _need="$_need $t"; done
  [ -z "$_need" ] || err "note: vmbench also needs:$_need"
  say "next: vmbench setup cpubench && vmbench list"
  say "the benchmark tools are not installed by this script; vmbench list shows what is missing. On Ubuntu:"
  say "  sudo apt-get install -y sysbench fio 7zip iperf3 sockperf stressapptest lmbench gcc numactl sysstat jq tmux"
}

main() {
  DRY=0 UNINSTALL=0 ALLOW_ROOT=0 DIR="" VERSION_ARG=""
  REPO=${VMBENCH_REPO:-chaloemph/vmbench}
  PREFIX=${VMBENCH_HOME:-}
  BINDIR=${VMBENCH_BIN_DIR:-}
  VERSION=${VMBENCH_VERSION:-latest}
  while [ $# -gt 0 ]; do
    case $1 in
      --version) [ $# -ge 2 ] || usage_error "--version needs a value"; VERSION=$2; VERSION_ARG=$2; shift 2 ;;
      --version=*) VERSION=${1#*=}; VERSION_ARG=$VERSION; shift ;;
      --prefix) [ $# -ge 2 ] || usage_error "--prefix needs a value"; PREFIX=$2; shift 2 ;;
      --prefix=*) PREFIX=${1#*=}; shift ;;
      --dir) [ $# -ge 2 ] || usage_error "--dir needs a value"; DIR=$2; shift 2 ;;
      --dir=*) DIR=${1#*=}; shift ;;
      --bin-dir) [ $# -ge 2 ] || usage_error "--bin-dir needs a value"; BINDIR=$2; shift 2 ;;
      --bin-dir=*) BINDIR=${1#*=}; shift ;;
      --uninstall) UNINSTALL=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --allow-root) ALLOW_ROOT=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) usage_error "unknown option '$1'" ;;
    esac
  done
  [ -z "$VERSION_ARG" ] && [ -n "${VMBENCH_VERSION:-}" ] && VERSION_ARG=$VMBENCH_VERSION
  [ "$VERSION_ARG" = latest ] && VERSION_ARG=""

  if [ "$(id -u)" = 0 ] && [ "$ALLOW_ROOT" != 1 ]; then
    die "refusing to run as root: vmbench installs into your home folder and needs no sudo. Run it as a normal user (or pass --allow-root)."
  fi
  [ -n "${HOME:-}" ] || die "HOME is not set"
  [ -n "$PREFIX" ] || PREFIX=$HOME/.local/share/vmbench
  [ -n "$BINDIR" ] || BINDIR=$HOME/.local/bin
  for p in "$PREFIX" "$BINDIR" ${DIR:+"$DIR"}; do
    case $p in /*) ;; *) usage_error "paths must be absolute: $p" ;; esac
  done

  INSECURE_URL=""
  if [ -n "${VMBENCH_BASE_URL:-}${VMBENCH_LATEST_URL:-}" ]; then
    INSECURE_URL=1
    err "note: using VMBENCH_BASE_URL / VMBENCH_LATEST_URL instead of GitHub"
  fi

  check_tools
  if [ "$UNINSTALL" = 1 ]; then do_uninstall; else do_install; fi
}

main "$@"
