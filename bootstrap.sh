#!/bin/sh
# Dotfiles bootstrap. Safe to re-run: every step is idempotent.
#
# Designed for ephemeral devcontainers:
#   - multi-arch (nothing hardcodes x86_64)
#   - assumes this repo is ALREADY cloned; only stows
#   - sets the login shell to zsh, because every config here is zsh-only
#   - docker install is opt-in, since containers inherit the host socket
#
# Env overrides:
#   STOW_TARGET     home to stow into          (default: $HOME)
#   STOW_USER       user whose shell to set    (default: owner of $STOW_TARGET)
#   SKIP_SHELL      1 to leave the login shell alone
#   SKIP_NVIM_PLUGINS 1 to skip the headless lazy.nvim install
#   INSTALL_DOCKER  1 to install docker        (default: 0 in a container)
#   LAZYGIT_VERSION pin, e.g. v0.44.1          (skips the GitHub API call)
#   TREE_SITTER_VERSION pin, e.g. v0.27.0      (skips the GitHub API call)
#   NEOVIM_VERSION  pin, e.g. v0.11.2          (installed/updated from GitHub release)
#   HERDR_VERSION   pin, e.g. v1.2.3
#   BUN_VERSION     pin, e.g. 1.1.34              (default: latest)
#   OMZ_VERSION     pin an oh-my-zsh commit
#   KICKSTART_VERSION pin a kickstart.nvim ref (branch or tag)
#   PKG_LOCK_TIMEOUT seconds to wait out package-manager lock contention
#                    (default: 600)
#   PKG_LOCK_DELAY  first lock retry delay in seconds, doubled each retry
#                    (default: 5)
set -eu

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# Slim container images often ship without TMPDIR. Neovim plugins that shell
# out through temp files (json-nvim, and anything else using vim.loop's
# os_tmpname) hard-error without it, so default to /tmp. Both this script and
# ~/.zshrc set it, since an export here does not survive into later shells.
export TMPDIR="${TMPDIR:-/tmp}"

info()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
skip()  { printf '\033[2m[SKIP]\033[0m %s\n' "$*"; }

# ─── privilege handling ───────────────────────────────────────────────
# Root: run directly. Non-root: prefix privileged steps with sudo. Under a
# devcontainer remoteUser we are already non-root and never call sudo, so a
# slim image with no sudo installed still works.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  if ! command -v sudo > /dev/null 2>&1; then
    error "Not root and sudo is unavailable. Run as root, or install sudo."
    exit 1
  fi
  SUDO="sudo"
fi

# ─── architecture ─────────────────────────────────────────────────────
# dpkg knows the *Debian* arch, which is what GitHub release assets are named
# after. uname -m is the fallback for non-debian package managers.
detect_arch() {
  if command -v dpkg > /dev/null 2>&1; then
    raw="$(dpkg --print-architecture)"
  else
    raw="$(uname -m)"
  fi
  case "$raw" in
    x86_64|amd64)       echo "x86_64" ;;
    aarch64|arm64)      echo "aarch64" ;;
    armv7l|armv7|armhf) echo "armv7" ;;
    i386|i686)          echo "i386" ;;
    *)                  echo "$raw" ;;
  esac
}

ARCH="$(detect_arch)"
info "Architecture: $ARCH"

# ─── package manager ──────────────────────────────────────────────────
detect_pkg_manager() {
  if command -v apt-get > /dev/null 2>&1; then echo "apt"
  elif command -v apk    > /dev/null 2>&1; then echo "apk"
  elif command -v dnf    > /dev/null 2>&1; then echo "dnf"
  elif command -v yum    > /dev/null 2>&1; then echo "yum"
  elif command -v pacman > /dev/null 2>&1; then echo "pacman"
  else echo "none"; fi
}

PKG_MGR="$(detect_pkg_manager)"
info "Package manager: $PKG_MGR"

if [ "$PKG_MGR" = "none" ]; then
  error "No supported package manager found."
  exit 1
fi

# ─── startup delay ─────────────────────────────────────────────────────
WAIT_SECS="${BOOTSTRAP_WAIT:-20}"
for arg in "$@"; do
  case "$arg" in
    --no-wait|--nowait)
      WAIT_SECS=0
      ;;
    --wait=*)
      WAIT_SECS="${arg#--wait=}"
      ;;
  esac
done
[ "$WAIT_SECS" -ge 0 ] 2> /dev/null || WAIT_SECS=20
if [ "$WAIT_SECS" -gt 0 ]; then
  info "Starting in ${WAIT_SECS}s (use --no-wait to skip)"
  sleep "$WAIT_SECS"
fi

# ─── package manager lock retries ─────────────────────────────────────
# On a freshly booted machine this script is not the only apt/dpkg client:
# cloud-init, unattended-upgrades, image provisioning and possibly another
# copy of this script all start at once. Whichever one is late to the lock
# dies with a message like:
#
#   E: Could not get lock /var/lib/apt/lists/lock. It is held by process 5400 (apt-get)
#   E: Unable to lock directory /var/lib/apt/lists/
#
# The failure is transient -- the holder finishes and releases the lock -- so
# retry it instead of aborting the bootstrap. Only lock contention is retried;
# a missing package or a permission error would otherwise spin for the whole
# timeout and bury the real error. After PKG_LOCK_TIMEOUT seconds the original
# failure is returned, so a genuinely stuck lock still fails loudly instead of
# hanging the bootstrap forever.
PKG_LOCK_TIMEOUT="${PKG_LOCK_TIMEOUT:-600}"
PKG_LOCK_DELAY="${PKG_LOCK_DELAY:-5}"
[ "$PKG_LOCK_TIMEOUT" -ge 0 ] 2> /dev/null || PKG_LOCK_TIMEOUT=600

# pkg_retry <package-manager command...>
# Variables are prefixed because POSIX sh has no `local`: without it, this
# would clobber same-named state in the calling function.
pkg_retry() {
  _pr_waited=0
  _pr_delay="$PKG_LOCK_DELAY"
  # A zero (or nonsense) delay would turn the timeout into a busy loop that
  # never advances the clock.
  [ "$_pr_delay" -ge 1 ] 2> /dev/null || _pr_delay=1
  _pr_log="$(mktemp)"
  _pr_status_file="$(mktemp)"

  while :; do
    # Stream the output so long installs stay visible, while keeping a copy to
    # classify the failure. POSIX sh has no PIPESTATUS, so the real exit status
    # travels through its own file; the braces keep `set -e` from aborting the
    # subshell before it can record the failure.
    { _pr_status=0; "$@" 2>&1 || _pr_status=$?; echo "$_pr_status" > "$_pr_status_file"; } | tee "$_pr_log"
    _pr_status="$(cat "$_pr_status_file" 2> /dev/null || echo 1)"
    [ -n "$_pr_status" ] || _pr_status=1

    if [ "$_pr_status" -eq 0 ]; then
      rm -f "$_pr_log" "$_pr_status_file"
      return 0
    fi

    _pr_out="$(cat "$_pr_log" 2> /dev/null || true)"

    # A permission problem is worded like a lock problem but never clears up by
    # waiting, so fail it immediately instead of spinning out the timeout.
    case "$_pr_out" in
      *"Permission denied"* | *"permission denied"* | *"Read-only file system"*)
        rm -f "$_pr_log" "$_pr_status_file"
        return "$_pr_status"
        ;;
    esac

    # apt/dpkg, apk, dnf/yum and pacman each word lock contention differently.
    case "$_pr_out" in
      *"Could not get lock"* | *"Unable to lock"* | \
        *"Unable to acquire the dpkg frontend lock"* | *"dpkg frontend lock"* | \
        *"is held by process"* | *"temporary error (try again later)"* | \
        *"Waiting for process with pid"* | *"Cannot get the lock"* | \
        *"unable to lock database"*)
        ;;
      *)
        rm -f "$_pr_log" "$_pr_status_file"
        return "$_pr_status"
        ;;
    esac

    if [ "$_pr_waited" -ge "$PKG_LOCK_TIMEOUT" ]; then
      error "package manager lock still busy after ${_pr_waited}s; giving up"
      rm -f "$_pr_log" "$_pr_status_file"
      return "$_pr_status"
    fi

    warn "package manager lock busy; retrying in ${_pr_delay}s (waited ${_pr_waited}s/${PKG_LOCK_TIMEOUT}s)"
    sleep "$_pr_delay"
    _pr_waited=$((_pr_waited + _pr_delay))
    [ "$_pr_delay" -ge 30 ] || _pr_delay=$((_pr_delay * 2))
  done
}

pkg_refresh() {
  case "$PKG_MGR" in
    apt)  pkg_retry $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq ;;
    apk)  pkg_retry $SUDO apk update -qq ;;
    *)    : ;;
  esac
}

# install_pkgs <pkg> [pkg...]
# Skips the whole call if every package's command is already present.
install_pkgs() {
  missing=""
  for spec in "$@"; do
    case "$spec" in
      *::*) cmd="${spec%%::*}"; pkg="${spec#*::}" ;;
      *)    cmd="$spec";        pkg="$spec" ;;
    esac
    if command -v "$cmd" > /dev/null 2>&1; then
      info "$cmd already present"
    else
      missing="$missing $pkg"
    fi
  done
  if [ -z "$missing" ]; then
    return 0
  fi

  info "Installing:$missing"
  # shellcheck disable=SC2086
  case "$PKG_MGR" in
    apt)    pkg_retry $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $missing ;;
    apk)    pkg_retry $SUDO apk add --no-cache $missing ;;
    dnf)    pkg_retry $SUDO dnf install -y $missing ;;
    yum)    pkg_retry $SUDO yum install -y $missing ;;
    pacman) pkg_retry $SUDO pacman -Sy --noconfirm --needed $missing ;;
  esac
}

pkg_refresh

# ─── base tooling ─────────────────────────────────────────────────────
# stow is GNU stow on every one of these managers. The cmd::pkg form lets you
# pass a binary name that differs from the package name.
install_pkgs bash git curl zsh unzip
install_pkgs rg::ripgrep
install_pkgs stow
install_pkgs make
install_pkgs gcc
# tmux: the repo stows a .tmux.conf, and install_tmux_plugins below clones tpm,
# which the config sources on its last line. Neither works without the binary.
install_pkgs tmux

# node + npm: hosts for LSP servers and the nvim plugins that drive them.
# The command is `node` on every distro, but the *package* is `nodejs` on
# debian/alpine and only `node` on fedora/arch, so map the name per manager.
# Distro packages are fine here -- anything needing a specific node version
# pins it in that project's own tooling instead.
case "$PKG_MGR" in
  apt|apk) install_pkgs node::nodejs npm ;;
  *)        install_pkgs node npm ;;
esac

# xclip/xsel are for X11 clipboards. Harmless no-ops headless, so don't fail.
install_pkgs xclip || warn "xclip unavailable; clipboard integration off"

# ─── github release helper ────────────────────────────────────────────
latest_version() {
  # $1 = owner/repo. Returns bare version with no leading v.
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' \
    | head -n 1
}

download_to() {
  # $1 = url, $2 = destination path
  curl -fSL --retry 3 --retry-delay 2 -o "$2" "$1"
}

# version_gt <a> <b>: succeeds (0) when <a> is strictly newer than <b>.
# Dotted numeric versions only (0.11.2, 1.2.3). awk keeps this portable;
# `sort -V` is GNU-only and BSD/macOS sort has no equivalent.
version_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) {
      av = (i <= na) ? x[i] + 0 : 0
      bv = (i <= nb) ? y[i] + 0 : 0
      if (av > bv) exit 0
      if (av < bv) exit 1
    }
    exit 1
  }'
}

# ─── neovim (github release) ──────────────────────────────────────────
# Installed from upstream releases, not the distro package: distro neovim on
# LTS images is frequently too old for the kickstart config (e.g. newer
# autocmd events and APIs). No package-manager fallback on purpose.
install_neovim_github() {
  version="${NEOVIM_VERSION:-$(latest_version neovim/neovim)}"
  version="${version#v}"

  if command -v nvim > /dev/null 2>&1; then
    installed="$(nvim --version | sed -n '1s/^NVIM v\([0-9][0-9.]*\).*/\1/p')"
    # "Already installed" is not the same as "good enough": kickstart and the
    # plugins installed below track recent neovim APIs, so an nvim older than
    # the latest stable release is exactly what breaks a fresh plugin install.
    # Only short-circuit when no newer release is resolvable, or the installed
    # build is already current (or ahead, e.g. a nightly).
    if [ -z "$version" ] || ! version_gt "$version" "$installed"; then
      info "nvim already present (v${installed:-unknown})"
      return 0
    fi
    info "Updating neovim v$installed -> v$version"
  else
    [ -n "$version" ] || { error "Could not resolve neovim version"; return 1; }
  fi

  case "$(uname -s)" in
    Linux)  nv_os="linux" ;;
    Darwin) nv_os="macos" ;;
    *) error "No neovim build for $(uname -s)"; return 1 ;;
  esac

  case "$ARCH" in
    x86_64)  nv_arch="x86_64" ;;
    aarch64) nv_arch="arm64" ;;
    armv7)   error "No neovim build for $ARCH"; return 1 ;;
    *) error "No neovim build for $ARCH"; return 1 ;;
  esac

  info "Installing neovim $version ($nv_os/$nv_arch)"
  tmp="$(mktemp -d)"
  tarball="nvim-${nv_os}-${nv_arch}.tar.gz"
  url="https://github.com/neovim/neovim/releases/download/v${version}/${tarball}"

  if download_to "$url" "$tmp/$tarball"; then
    # The tarball unpacks to a versioned directory; point a stable symlink at it.
    $SUDO rm -rf "/opt/nvim-${nv_os}-${nv_arch}"
    $SUDO mkdir -p /opt
    if $SUDO tar xf "$tmp/$tarball" -C /opt; then
      $SUDO ln -sf "/opt/nvim-${nv_os}-${nv_arch}/bin/nvim" /usr/local/bin/nvim
    else
      error "neovim extract failed"
    fi
  else
    error "neovim download failed"
  fi
  rm -rf "$tmp"

  command -v nvim > /dev/null 2>&1 || return 1
  nvim --version | head -n 1
}

# neovim: install latest stable from GitHub releases
install_neovim_github || { error "Failed to install neovim from GitHub releases"; exit 1; }

# ─── lazygit ──────────────────────────────────────────────────────────
install_lazygit() {
  if command -v lazygit > /dev/null 2>&1; then
    info "lazygit already installed"
    return 0
  fi

  # lazygit names its assets with the *uname* spelling, not the Debian one.
  case "$ARCH" in
    x86_64) lg_arch="x86_64" ;;
    aarch64) lg_arch="arm64" ;;
    armv7)  lg_arch="armv6" ;;
    *) error "No lazygit build for $ARCH"; return 0 ;;
  esac

  version="${LAZYGIT_VERSION:-$(latest_version jesseduffield/lazygit)}"
  [ -n "$version" ] || { error "Could not resolve lazygit version"; return 0; }
  version="${version#v}"

  info "Installing lazygit $version ($lg_arch)"
  tmp="$(mktemp -d)"
  if download_to \
    "https://github.com/jesseduffield/lazygit/releases/download/v${version}/lazygit_${version}_Linux_${lg_arch}.tar.gz" \
    "$tmp/lazygit.tar.gz"; then
    tar xf "$tmp/lazygit.tar.gz" -C "$tmp" lazygit
    $SUDO install -m 0755 "$tmp/lazygit" /usr/local/bin/lazygit
  else
    error "lazygit download failed"
  fi
  rm -rf "$tmp"
}

# ─── herdr ────────────────────────────────────────────────────────────
install_herdr() {
  if command -v herdr > /dev/null 2>&1; then
    info "herdr already installed"
    return 0
  fi

  case "$ARCH" in
    x86_64|aarch64) : ;; # herdr uses the Debian spelling
    *) error "No herdr build for $ARCH"; return 0 ;;
  esac

  version="${HERDR_VERSION:-$(latest_version herdrdev/herdr)}"
  [ -n "$version" ] || { error "Could not resolve herdr version"; return 0; }
  version="${version#v}"

  info "Installing herdr $version ($ARCH)"
  tmp="$(mktemp -d)"
  if download_to \
    "https://github.com/herdrdev/herdr/releases/download/v${version}/herdr-linux-${ARCH}" \
    "$tmp/herdr"; then
    $SUDO install -m 0755 "$tmp/herdr" /usr/local/bin/herdr
  else
    error "herdr download failed"
  fi
  rm -rf "$tmp"
}

# ─── tree-sitter cli ─────────────────────────────────────────────────
# Not optional: the vim.pack-era nvim-treesitter (nvim-treesitter main)
# installs parsers by shelling out to the `tree-sitter` CLI rather than
# building them itself. Without the binary on PATH every parser install fails
# with "ENOENT: no such file or directory (cmd: 'tree-sitter')" -- which shows
# up as broken highlighting rather than as an obvious "tool missing" error.
# Release assets are gzipped single binaries (not tarballs), named with the
# *Go* arch spelling: x64 / arm64.
install_tree_sitter() {
  if command -v tree-sitter > /dev/null 2>&1; then
    info "tree-sitter already present"
    return 0
  fi

  case "$(uname -s)" in
    Linux)  ts_os="linux" ;;
    Darwin) ts_os="macos" ;;
    *) error "No tree-sitter build for $(uname -s)"; return 0 ;;
  esac

  case "$ARCH" in
    x86_64)  ts_arch="x64" ;;
    aarch64) ts_arch="arm64" ;;
    *) error "No tree-sitter build for $ARCH"; return 0 ;;
  esac

  version="${TREE_SITTER_VERSION:-$(latest_version tree-sitter/tree-sitter)}"
  [ -n "$version" ] || { error "Could not resolve tree-sitter version"; return 0; }
  version="${version#v}"

  info "Installing tree-sitter $version ($ts_os/$ts_arch)"
  tmp="$(mktemp -d)"
  if download_to \
    "https://github.com/tree-sitter/tree-sitter/releases/download/v${version}/tree-sitter-${ts_os}-${ts_arch}.gz" \
    "$tmp/tree-sitter.gz"; then
    gunzip -c "$tmp/tree-sitter.gz" > "$tmp/tree-sitter" &&
      chmod +x "$tmp/tree-sitter" &&
      $SUDO install -m 0755 "$tmp/tree-sitter" /usr/local/bin/tree-sitter
  else
    error "tree-sitter download failed"
  fi
  rm -rf "$tmp"

  command -v tree-sitter > /dev/null 2>&1 || \
    warn "tree-sitter not on PATH; nvim-treesitter parser installs will fail"
}

# Run a command as the owner of the stow target, so anything it writes into
# that home stays writable by the real user. A root-run step would otherwise
# leave root-owned files behind, and the first non-root session then cannot
# update them.
run_as_owner() {
  target="${STOW_TARGET:-$HOME}"
  owner="$(stat -c %U "$target" 2>/dev/null || stat -f %Su "$target" 2>/dev/null || echo "")"
  if [ "$(id -u)" -eq 0 ] && [ -n "$owner" ] && [ "$owner" != "root" ]; then
    $SUDO -u "$owner" -H "$@"
  else
    "$@"
  fi
}

# ─── tmux plugins (tpm) ───────────────────────────────────────────────
# ~/.tmux.conf ends with `run '~/.tmux/plugins/tpm/tpm'`, so a stowed config
# without tpm is a config whose plugin manager silently does nothing -- no
# error, just no vim-tmux-navigator, no resurrect, no continuum.
install_tmux_plugins() {
  if ! command -v tmux > /dev/null 2>&1; then
    skip "tmux not found; not installing tmux plugins"
    return 0
  fi

  home="${STOW_TARGET:-$HOME}"
  tpm_dir="$home/.tmux/plugins/tpm"

  if [ -d "$tpm_dir" ]; then
    info "tpm already installed"
  else
    info "Installing tpm"
    run_as_owner mkdir -p "$home/.tmux/plugins" || return 0
    run_as_owner git clone --depth 1 https://github.com/tmux-plugins/tpm "$tpm_dir" || return 0
  fi

  # tpm installs the @plugin entries when a tmux server starts, which in a
  # container does not happen until someone attaches. Run its installer
  # directly -- it needs no server -- so the first real tmux is already
  # complete. Same reason as the nvim pre-install: nothing is there to answer
  # a prompt.
  info "Installing tmux plugins via tpm"
  run_as_owner "$tpm_dir/bin/install_plugins" ||
    warn "tpm did not finish cleanly; plugins will install on first tmux launch"
}

# ─── github cli ───────────────────────────────────────────────────────
install_gh() {
  if command -v gh > /dev/null 2>&1; then
    info "gh already installed"
    return 0
  fi

  case "$PKG_MGR" in
    apt)
      info "Installing GitHub CLI via apt"
      keyring=/usr/share/keyrings/githubcli-archive-keyring.gpg
      if [ ! -f "$keyring" ]; then
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          | $SUDO dd of="$keyring" status=none 2>/dev/null || \
          curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          | $SUDO tee "$keyring" > /dev/null
      fi
      $SUDO chmod go+r "$keyring"
      # dpkg --print-architecture keeps this correct on arm64.
      printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' \
        "$ARCH" "$keyring" \
        | $SUDO tee /etc/apt/sources.list.d/github-cli.list > /dev/null
      pkg_retry $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
      install_pkgs gh
      ;;
    apk)
      install_pkgs gh || warn "gh unavailable on apk"
      ;;
    *)
      skip "gh install not implemented for $PKG_MGR"
      ;;
  esac
}

# ─── 1password cli ────────────────────────────────────────────────────
# The binary is `op`. It only ships through 1Password's own repos (apt, apk,
# rpm), so each manager needs its key/repo configured first. On apt the
# packages are additionally signed with debsig-verify: without the policy and
# its keyring, `apt install 1password-cli` dies with "debsig: No policy
# found", which reads like a broken package rather than a missing setup step.
install_op() {
  if command -v op > /dev/null 2>&1; then
    info "1password cli already installed"
    return 0
  fi

  case "$PKG_MGR" in
    apt)
      # The repo key is ASCII-armored, and apt needs it dearmored, so gpg is a
      # hard requirement here -- slim images do not all ship it.
      if ! install_pkgs gpg::gnupg; then
        warn "gpg unavailable; 1password cli not installed"
        return 0
      fi

      info "Installing 1Password CLI via apt"
      keyring=/usr/share/keyrings/1password-archive-keyring.gpg
      policy_dir=/etc/debsig/policies/AC2D62742012EA22
      debsig_keyring_dir=/usr/share/debsig/keyrings/AC2D62742012EA22

      if [ ! -s "$keyring" ]; then
        curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
          | $SUDO gpg --dearmor --yes --output "$keyring" || {
          warn "could not fetch the 1Password repo key; op not installed"
          return 0
        }
      fi
      $SUDO chmod go+r "$keyring"

      # $ARCH is already the Debian spelling, which is what this repo's paths
      # use (amd64/arm64/386/arm).
      printf 'deb [arch=%s signed-by=%s] https://downloads.1password.com/linux/debian/%s stable main\n' \
        "$ARCH" "$keyring" "$ARCH" \
        | $SUDO tee /etc/apt/sources.list.d/1password.list > /dev/null

      $SUDO mkdir -p "$policy_dir" "$debsig_keyring_dir"
      if ! curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol \
        | $SUDO tee "$policy_dir/1password.pol" > /dev/null; then
        warn "could not fetch the 1Password debsig policy; op not installed"
        return 0
      fi
      if ! curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
        | $SUDO gpg --dearmor --yes --output "$debsig_keyring_dir/debsig.gpg"; then
        warn "could not fetch the 1Password debsig keyring; op not installed"
        return 0
      fi

      pkg_retry $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
      install_pkgs op::1password-cli ||
        warn "1password cli install failed; the op command will be missing"
      ;;
    apk)
      # Upstream publishes this repo for x86_64 only.
      if [ "$ARCH" != "x86_64" ]; then
        skip "1password cli has no alpine repo for $ARCH"
        return 0
      fi

      info "Installing 1Password CLI via apk"
      repo=https://downloads.1password.com/linux/alpinelinux/stable/
      if ! grep -qxF "$repo" /etc/apk/repositories 2> /dev/null; then
        printf '%s\n' "$repo" | $SUDO tee -a /etc/apk/repositories > /dev/null
      fi

      key=/etc/apk/keys/support@1password.com-61ddfc31.rsa.pub
      if [ ! -s "$key" ]; then
        curl -fsSL https://downloads.1password.com/linux/keys/alpinelinux/support@1password.com-61ddfc31.rsa.pub \
          | $SUDO tee "$key" > /dev/null || {
          warn "could not fetch the 1Password apk key; op not installed"
          return 0
        }
      fi

      pkg_retry $SUDO apk update -qq
      install_pkgs op::1password-cli ||
        warn "1password cli install failed; the op command will be missing"
      ;;
    dnf|yum)
      info "Installing 1Password CLI via $PKG_MGR"
      pkg_retry $SUDO rpm --import https://downloads.1password.com/linux/keys/1password.asc ||
        warn "could not import the 1Password rpm key; op install may fail"

      if [ ! -f /etc/yum.repos.d/1password.repo ]; then
        # Single-quoted so $basearch stays literal for dnf to expand.
        printf '%s\n' \
          '[1password]' \
          'name=1Password Stable Channel' \
          'baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch' \
          'enabled=1' \
          'gpgcheck=1' \
          'repo_gpgcheck=1' \
          'gpgkey=https://downloads.1password.com/linux/keys/1password.asc' \
          | $SUDO tee /etc/yum.repos.d/1password.repo > /dev/null
      fi

      install_pkgs op::1password-cli ||
        warn "1password cli install failed; the op command will be missing"
      ;;
    *)
      skip "1password cli install not implemented for $PKG_MGR"
      ;;
  esac

  # `if` rather than `cmd && op --version`: a missing op at the end of the
  # function would return non-zero and, under `set -e`, abort the bootstrap
  # even though the failure above was only a warning.
  if command -v op > /dev/null 2>&1; then
    op --version
  fi
}

# ─── tldr ─────────────────────────────────────────────────────────────
# Official client from tldr-pages, installed via npm (already present from
# the node install above). Pages download lazily on first use.
install_tldr() {
  if command -v tldr > /dev/null 2>&1; then
    info "tldr already installed"
    return 0
  fi

  if ! command -v npm > /dev/null 2>&1; then
    warn "npm not available; tldr not installed"
    return 0
  fi

  info "Installing tldr (npm)"
  # Distro node installs npm's global prefix under system paths, so this
  # needs root; $SUDO is empty when already root.
  $SUDO npm install -g tldr ||
    warn "tldr install failed; pages client will be missing"
}

# ─── bruno cli ────────────────────────────────────────────────────────
# Bruno's CLI is what runs collections from a terminal and in CI. It ships only
# on npm as @usebruno/cli, and the binary it provides is `bru`.
install_bruno() {
  if command -v bru > /dev/null 2>&1; then
    info "bruno cli already installed"
    return 0
  fi

  if ! command -v npm > /dev/null 2>&1; then
    warn "npm not available; bruno cli not installed"
    return 0
  fi

  info "Installing bruno cli (npm)"
  # Same as tldr: distro node puts the global prefix under system paths.
  $SUDO npm install -g @usebruno/cli ||
    warn "bruno cli install failed; the bru command will be missing"
}

# ─── aws cli ──────────────────────────────────────────────────────────
# AWS CLI v2 ships as a self-contained bundled installer rather than through
# distro repos (and the distro packages, where they exist, lag badly), so this
# follows the upstream "command line installer" flow:
#   https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
# On Linux the installer script is identical on every distro -- it bundles its
# own python -- so only the asset name varies, by arch. macOS uses a pkg.
install_awscli() {
  if command -v aws > /dev/null 2>&1; then
    info "aws already installed"
    return 0
  fi

  case "$(uname -s)" in
    Linux)
      case "$ARCH" in
        x86_64)  aws_arch="x86_64" ;;
        aarch64) aws_arch="aarch64" ;;
        *) error "No aws-cli build for $ARCH"; return 0 ;;
      esac

      info "Installing aws-cli ($aws_arch)"
      tmp="$(mktemp -d)"
      if download_to \
        "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" \
        "$tmp/awscliv2.zip"; then
        unzip -q "$tmp/awscliv2.zip" -d "$tmp" &&
          $SUDO "$tmp/aws/install" --update
      else
        error "aws-cli download failed"
      fi
      rm -rf "$tmp"
      ;;
    Darwin)
      info "Installing aws-cli (macOS)"
      tmp="$(mktemp -d)"
      if download_to \
        "https://awscli.amazonaws.com/AWSCLIV2.pkg" "$tmp/AWSCLIV2.pkg"; then
        $SUDO installer -pkg "$tmp/AWSCLIV2.pkg" -target /
      else
        error "aws-cli download failed"
      fi
      rm -rf "$tmp"
      ;;
    *)
      skip "aws-cli install not implemented for $(uname -s)"
      ;;
  esac

  command -v aws > /dev/null 2>&1 && aws --version
}

# ─── mise + bun ───────────────────────────────────────────────────────
# Neuron (mark.nvim's terminal markdown preview) needs the Bun runtime. Bun is
# installed through mise, which also owns the other user-level toolchains. mise
# is not part of every base image and its installer is user-local, so install
# it (into the stow target's home, as its owner) before recording the tool.
install_mise() {
  home="${STOW_TARGET:-$HOME}"
  mise_bin="$home/.local/bin/mise"

  if command -v mise > /dev/null 2>&1 || [ -x "$mise_bin" ]; then
    info "mise already installed"
    return 0
  fi

  info "Installing mise"
  run_as_owner sh -c 'curl -fsSL https://mise.run | sh' ||
    warn "mise install failed; bun will not be installed"
}

install_bun() {
  home="${STOW_TARGET:-$HOME}"
  mise_bin="$home/.local/bin/mise"

  install_mise

  # Prefer mise on PATH, but fall back to the path the installer just used: the
  # current script's PATH predates this run.
  mise_cmd="$(command -v mise 2> /dev/null || true)"
  [ -n "$mise_cmd" ] && [ -x "$mise_cmd" ] || mise_cmd="$mise_bin"
  if [ ! -x "$mise_cmd" ]; then
    skip "mise not available; not installing bun"
    return 0
  fi

  if command -v bun > /dev/null 2>&1; then
    info "bun already installed"
    return 0
  fi

  # `use -g` records the pin in the owner's global mise config (declarative and
  # idempotent); `install` then materializes it and its shims.
  bun_version="${BUN_VERSION:-latest}"
  info "Installing bun@$bun_version via mise"
  run_as_owner "$mise_cmd" use -g "bun@$bun_version" ||
    warn "mise use failed; bun will be missing"
  run_as_owner "$mise_cmd" install ||
    warn "mise install failed; bun may be incomplete"
}

# ─── docker (opt-in) ──────────────────────────────────────────────────
in_container() {
  [ -f /.dockerenv ] && return 0
  grep -qa 'docker\|kubepods\|containerd' /proc/1/cgroup 2> /dev/null && return 0
  return 1
}

install_docker() {
  if command -v docker > /dev/null 2>&1; then
    info "docker already available"
    return 0
  fi
  if in_container; then
    skip "docker inside a container; expected via bind-mounted socket + remoteUser"
    return 0
  fi
  info "Installing docker"
  curl -fsSL https://get.docker.com | sh
  # No usermod: under remoteUser docker access comes from the socket's group
  # already being present in the image.
}

# ─── oh-my-zsh ────────────────────────────────────────────────────────
install_omz() {
  target="${STOW_TARGET:-$HOME}/.oh-my-zsh"
  if [ -f "$target/oh-my-zsh.sh" ]; then
    info "oh-my-zsh already installed"
    return 0
  fi
  info "Installing oh-my-zsh"
  if [ -n "${OMZ_VERSION:-}" ]; then
    git clone --depth 1 --branch "$OMZ_VERSION" \
      https://github.com/ohmyzsh/ohmyzsh "$target" || return 0
  else
    # Shallow clone: the default full-history clone is the slowest step here.
    git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh "$target" || return 0
  fi
}

# ─── kickstart.nvim ───────────────────────────────────────────────────
# kickstart owns all of ~/.config/nvim, so it can only be cloned when the
# dotfiles repo is not stowing a config of its own into that same path.
install_kickstart() {
  target="${STOW_TARGET:-$HOME}/.config/nvim"
  if [ -f "$target/init.lua" ]; then
    info "kickstart.nvim already installed"
    return 0
  fi

  if [ -L "$target" ]; then
    warn "$target is a symlink (stowed from the dotfiles repo); skipping"
    return 0
  fi

  if [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null || true)" ]; then
    warn "$target exists and is not empty; leaving it alone"
    return 0
  fi

  info "Installing kickstart.nvim into $target"
  mkdir -p "$(dirname "$target")"
  if [ -n "${KICKSTART_VERSION:-}" ]; then
    git clone --depth 1 --branch "$KICKSTART_VERSION" \
      https://github.com/jaredbarranco/kickstart.nvim "$target" || return 0
  else
    git clone --depth 1 \
      https://github.com/jaredbarranco/kickstart.nvim "$target" || return 0
  fi
}

# ─── nvim plugins (lazy.nvim) ─────────────────────────────────────────
# A fresh lazy.nvim asks "install missing plugins?" interactively on the first
# launch, which is the wrong shape for a container: there is nobody there to
# answer. Running the same install headlessly answers it in advance.
#
# `Lazy! install` (bang, not `Lazy sync`) is deliberate: bang installs whatever
# is missing and leaves already-installed plugins at their current version, so
# a re-run is a no-op instead of silently upgrading the config.
install_nvim_plugins() {
  if [ "${SKIP_NVIM_PLUGINS:-0}" = "1" ]; then
    skip "SKIP_NVIM_PLUGINS=1; not pre-installing nvim plugins"
    return 0
  fi

  target="${STOW_TARGET:-$HOME}"
  if [ ! -f "$target/.config/nvim/init.lua" ]; then
    skip "no $target/.config/nvim/init.lua; not pre-installing plugins"
    return 0
  fi

  if ! command -v nvim > /dev/null 2>&1; then
    warn "nvim not found; plugins will install on first launch"
    return 0
  fi

  info "Pre-installing nvim plugins via lazy.nvim"

  # Same reason stow runs as the target's owner: a root-run nvim would leave
  # root-owned files under ~/.local/share/nvim, and the first real launch then
  # cannot write its own plugin state.
  owner="$(stat -c %U "$target" 2>/dev/null || stat -f %Su "$target" 2>/dev/null || echo "")"
  log="$(mktemp)"

  # `if ! ...` rather than a bare call: `set -e` would abort the whole script on
  # a failed nvim, and this step is explicitly allowed to degrade.
  if [ "$(id -u)" -eq 0 ] && [ -n "$owner" ] && [ "$owner" != "root" ]; then
    if ! $SUDO -u "$owner" -H nvim --headless "+Lazy! install" +qa > "$log" 2>&1; then
      status=1
    else
      status=0
    fi
  elif ! nvim --headless "+Lazy! install" +qa > "$log" 2>&1; then
    status=1
  else
    status=0
  fi

  if [ "$status" -eq 0 ]; then
    info "nvim plugins installed"
    rm -f "$log"
  else
    # A config that does not use lazy.nvim fails here with "Not an editor
    # command: Lazy"; a real failure is anything else. Either way it is not
    # fatal: the first interactive launch is the fallback.
    warn "nvim plugin pre-install failed; plugins will be offered on first launch:"
    while IFS= read -r line; do warn "  $line"; done < "$log"
    rm -f "$log"
  fi
}

# ─── dotfiles ─────────────────────────────────────────────────────────
# stow never overwrites: if a real file already sits where a symlink should go
# it aborts the whole run with "existing target is neither a link nor a
# directory" and links nothing else. A fresh home -- or a devcontainer image
# seeded from /etc/skel -- ships its own .zshrc/.tmux.conf, and oh-my-zsh even
# writes ~/.oh-my-zsh/custom/example.zsh, any of which stops every config from
# being linked. Delete just the paths we are about to link before stowing.
# Anything absent from the package is left untouched, and .stow-local-ignore is
# honoured so a file stow would have skipped (e.g. ~/.gitignore, the oh-my-zsh
# samples) is never deleted.
clear_stow_conflicts() {
  pkg="$1"
  target="$2"

  # Effective ignore list: stow's own defaults plus .stow-local-ignore, minus
  # comments and blanks (an empty line is a regex that matches every path).
  patterns="$(mktemp)"
  {
    if [ -f "$pkg/.stow-local-ignore" ]; then
      grep -v '^[[:space:]]*#' "$pkg/.stow-local-ignore"
    fi
    printf '%s\n' '\.git$' '\.gitignore$' '\.gitmodules$' '\.stow-local-ignore$'
  } 2> /dev/null | grep -v '^[[:space:]]*$' > "$patterns" || true

  # A path is ignored if it, or any parent directory, matches a pattern: stow
  # prunes an ignored directory and everything beneath it. The loop variable is
  # deliberately not `rel`: POSIX sh has no `local`, so touching the caller's
  # variable would corrupt the destination path.
  is_ignored() {
    _ig_path="$1"
    while :; do
      if printf '%s\n' "$_ig_path" | grep -qEf "$patterns"; then
        return 0
      fi
      case "$_ig_path" in
        */*) _ig_path="${_ig_path%/*}" ;;
        *) break ;;
      esac
    done
    return 1
  }

  find "$pkg" -mindepth 1 \( -name .git -o -name .stow-local-ignore \) -prune -o -print |
    while IFS= read -r src; do
      rel="${src#"$pkg"/}"
      if is_ignored "$rel"; then
        continue
      fi

      dst="$target/$rel"

      # The package wants a directory here, but the target has a file in the way.
      if [ -d "$src" ] && [ ! -L "$src" ]; then
        if [ -e "$dst" ] && [ ! -d "$dst" ]; then
          warn "removing $dst (file in the way of directory $rel)"
          rm -rf "$dst"
        fi
      # A real file where a symlink should go: the actual conflict stow aborts on.
      # A symlink is left for --restow to relink, so re-runs stay clean.
      elif [ -e "$dst" ] && [ ! -L "$dst" ]; then
        info "removing existing $dst so stow can link $rel"
        rm -f "$dst"
      fi
    done

  rm -f "$patterns"
}

setup_dotfiles() {
  target="${STOW_TARGET:-$HOME}"
  if [ ! -d "$target" ]; then
    error "stow target does not exist: $target"
    return 0
  fi

  if ! command -v stow > /dev/null 2>&1; then
    warn "stow not found; dotfiles not linked"
    return 0
  fi

  clear_stow_conflicts "$DOTFILES_DIR" "$target"

  info "Stowing dotfiles from $DOTFILES_DIR into $target"

  # Stow must write as the owner of the target home. Running as root would
  # otherwise leave root-owned symlinks in the user's home directory.
  # GNU and BSD stat disagree on the format flag, so try both.
  owner="$(stat -c %U "$target" 2>/dev/null || stat -f %Su "$target" 2>/dev/null || echo "")"

  # Stow aborts the *entire* run on a single conflict, which is a footgun: one
  # stray file stops every other config from being linked, and the resulting
  # "Bootstrap complete." would be a lie. clear_stow_conflicts above has already
  # removed the usual culprits (a pre-existing ~/.zshrc etc.); anything still
  # conflicting comes from the repo itself, so report it and keep going.
  if [ "$(id -u)" -eq 0 ] && [ -n "$owner" ] && [ "$owner" != "root" ]; then
    $SUDO -u "$owner" -H sh -c \
      "cd '$DOTFILES_DIR' && stow --restow --target='$target' ." ||
      warn "stow reported a conflict; some files were not linked (see output above)"
  else
    # --restow so re-runs pick up .zshrc edits instead of silently no-op'ing.
    ( cd "$DOTFILES_DIR" && stow --restow --target="$target" . ) ||
      warn "stow reported a conflict; some files were not linked (see output above)"
  fi
}

# ─── login shell ──────────────────────────────────────────────────────
# Every config in this repo is zsh-only: .zshrc is never read by bash, so
# without this a container logs in to a shell with no oh-my-zsh, none of the
# custom functions (finder, gitr, npd, pa, ...), and no PATH tweaks. The
# login shell comes from field 7 of /etc/passwd, which is exactly what ssh,
# `coder` and `docker exec -it` read, so fixing that one field is what makes
# the next session correct. Skipping this was the bug: it looks harmless on
# a container that spawns an explicit shell, and silently breaks one that
# does not.
install_login_shell() {
  if [ "${SKIP_SHELL:-0}" = "1" ]; then
    skip "SKIP_SHELL=1; leaving the login shell alone"
    return 0
  fi

  case "$(uname -s)" in
    Linux) ;;
    *)
      # macOS/BSD: chsh only accepts shells listed in /etc/shells and needs the
      # user's password, which nobody wants in a script.
      skip "not Linux; not changing the login shell (run: chsh -s $(command -v zsh || echo /usr/bin/zsh))"
      return 0
      ;;
  esac

  if ! command -v zsh > /dev/null 2>&1; then
    error "zsh is not installed; cannot set the login shell"
    return 0
  fi

  zsh_path="$(command -v zsh)"

  # Resolve the user from the stow target's owner rather than $USER: under root
  # (the common container case) $USER is root, but the shell that matters
  # belongs to remoteUser, whose home is what we just stowed into.
  target="${STOW_TARGET:-$HOME}"
  owner="$(stat -c %U "$target" 2>/dev/null || stat -f %Su "$target" 2>/dev/null || echo "")"
  [ -n "$owner" ] || owner="$(id -un)"

  current="$(awk -F: -v u="$owner" '$1 == u { print $7 }' /etc/passwd 2> /dev/null || true)"
  if [ "$current" = "$zsh_path" ]; then
    info "login shell for $owner is already $zsh_path"
    return 0
  fi

  info "Setting login shell for $owner: ${current:-unknown} -> $zsh_path"

  # usermod lives in the `passwd` package, which slim images often drop.
  # Editing /etc/passwd directly is the fallback: only field 7 changes, and
  # rewriting one field beats leaving the shell wrong.
  if command -v usermod > /dev/null 2>&1; then
    if $SUDO usermod -s "$zsh_path" "$owner"; then
      info "login shell set via usermod"
      return 0
    fi
    warn "usermod failed; editing /etc/passwd directly"
  fi

  # cat > keeps the existing inode, so passwd's ownership and mode survive.
  # A truncated /etc/passwd locks out every account, so back it up first.
  passwd_tmp="$(mktemp)"
  awk -F: -v OFS=: -v u="$owner" -v s="$zsh_path" \
    '$1 == u { $7 = s } { print }' /etc/passwd > "$passwd_tmp"

  if [ ! -s "$passwd_tmp" ] || ! grep -q "^${owner}:" "$passwd_tmp"; then
    error "could not rewrite the $owner entry in /etc/passwd; leaving it untouched"
    rm -f "$passwd_tmp"
    return 0
  fi

  # Refuse to touch passwd if the backup cannot be taken: a truncated passwd
  # locks out every account, which is worse than a wrong login shell.
  if ! $SUDO cp -p /etc/passwd /etc/passwd.bak; then
    error "could not back up /etc/passwd; leaving the login shell unchanged"
    rm -f "$passwd_tmp"
    return 0
  fi

  if $SUDO sh -c "cat '$passwd_tmp' > /etc/passwd"; then
    rm -f "$passwd_tmp"
    info "login shell set via /etc/passwd"
  else
    rm -f "$passwd_tmp"
    $SUDO cp -p /etc/passwd.bak /etc/passwd 2> /dev/null || true
    error "failed to write /etc/passwd (restored from backup)"
    return 0
  fi
}

# ─── run ──────────────────────────────────────────────────────────────
install_login_shell
install_lazygit
install_herdr
install_tree_sitter
install_gh
install_op
install_tldr
install_bruno
install_awscli
install_bun
install_docker
install_omz
install_tmux_plugins
setup_dotfiles
install_kickstart
install_nvim_plugins

info "Bootstrap complete."

# Report the shell the *next* session will get. A stale login is the single
# most confusing post-bootstrap failure -- everything looks installed, then
# none of it exists in the terminal.
case "$(uname -s)" in
  Linux)
    shell_now="$(awk -F: -v u="$(id -un)" '$1 == u { print $7 }' /etc/passwd 2> /dev/null || true)"
    case "$(basename "${shell_now:-none}")" in
      zsh)
        info "Next shell: ${shell_now} -- \`exec zsh\` to switch this session now."
        ;;
      *)
        warn "Login shell is ${shell_now:-unknown}, not zsh: .zshrc and every"
        warn "~/.oh-my-zsh custom plugin (finder, gitr, npd, pa, ...) will not load."
        warn "Fix with: chsh -s $(command -v zsh || echo /usr/bin/zsh) && exec zsh"
        ;;
    esac
    ;;
  *)
    skip "not Linux; login shell not managed here (chsh -s $(command -v zsh || echo /usr/bin/zsh))"
    ;;
esac