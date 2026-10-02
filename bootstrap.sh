#!/bin/sh
# Dotfiles bootstrap. Safe to re-run: every step is idempotent.
#
# Designed for ephemeral devcontainers:
#   - multi-arch (nothing hardcodes x86_64)
#   - assumes this repo is ALREADY cloned; only stows
#   - no chsh / usermod (no-ops under remoteUser, harmful in slim images)
#   - docker install is opt-in, since containers inherit the host socket
#
# Env overrides:
#   STOW_TARGET     home to stow into          (default: $HOME)
#   INSTALL_DOCKER  1 to install docker        (default: 0 in a container)
#   LAZYGIT_VERSION pin, e.g. v0.44.1          (skips the GitHub API call)
#   HERDR_VERSION   pin, e.g. v1.2.3
#   OMZ_VERSION     pin an oh-my-zsh commit
#   KICKSTART_VERSION pin a kickstart.nvim ref (branch or tag)
set -eu

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

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

pkg_refresh() {
  case "$PKG_MGR" in
    apt)  DEBIAN_FRONTEND=noninteractive $SUDO apt-get update -qq ;;
    apk)  $SUDO apk update -qq ;;
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
    apt)    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $missing ;;
    apk)    $SUDO apk add --no-cache $missing ;;
    dnf)    $SUDO dnf install -y $missing ;;
    yum)    $SUDO yum install -y $missing ;;
    pacman) $SUDO pacman -Sy --noconfirm --needed $missing ;;
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

# xclip/xsel are for X11 clipboards. Harmless no-ops headless, so don't fail.
install_pkgs xclip || warn "xclip unavailable; clipboard integration off"

# neovim: install latest stable from GitHub releases
install_neovim_github || { error "Failed to install neovim from GitHub releases"; exit 1; }

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
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
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

# ─── dotfiles ─────────────────────────────────────────────────────────
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

  info "Stowing dotfiles from $DOTFILES_DIR into $target"

  # Stow must write as the owner of the target home. Running as root would
  # otherwise leave root-owned symlinks in the user's home directory.
  # GNU and BSD stat disagree on the format flag, so try both.
  owner="$(stat -c %U "$target" 2>/dev/null || stat -f %Su "$target" 2>/dev/null || echo "")"

  # Stow aborts the *entire* run on a single conflict, which is a footgun: one
  # stray file left in the repo stops every other config from being linked, and
  # the resulting "Bootstrap complete." would be a lie. Report the conflict and
  # keep going instead. Nothing should fail stow on a fresh clone -- if you see
  # this, check .stow-local-ignore for a missing upstream-sample exclusion.
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

# ─── run ──────────────────────────────────────────────────────────────
install_lazygit
install_herdr
install_gh
install_docker
install_omz
setup_dotfiles
install_kickstart

info "Bootstrap complete."