#!/bin/sh
set -e

# Re-run as sudo if not already root
if [ "$(id -u)" -ne 0 ]; then
  echo "[INFO] Script not running as root. Re-executing with sudo..."
  exec sudo "$0" "$@"
fi

# Colors for logging
info()  { echo "\033[1;32m[INFO]\033[0m $*"; }
error() { echo "\033[1;31m[ERROR]\033[0m $*" >&2; }

# Detect user
USER_NAME="${SUDO_USER:-$(whoami)}"
USER_HOME="$(eval echo ~"$USER_NAME")"

# Detect package manager
detect_pkg_manager() {
  if command -v apk > /dev/null; then
    echo "apk"
  elif command -v apt > /dev/null; then
    echo "apt"
  elif command -v dnf > /dev/null; then
    echo "dnf"
  elif command -v yum > /dev/null; then
    echo "yum"
  elif command -v pacman > /dev/null; then
    echo "pacman"
  else
    error "No supported package manager found"
    exit 1
  fi
}

PKG_MGR=$(detect_pkg_manager)
info "Using package manager: $PKG_MGR"

# Install a package if it's not installed
install_if_missing() {
  CMD="$1"
  PKG="$2"
  if ! command -v "$CMD" > /dev/null; then
    info "Installing $PKG"
    case "$PKG_MGR" in
      apk)   apk add --no-cache "$PKG" ;;
      apt)   apt update -y && apt install -y "$PKG" ;;
      dnf)   dnf install -y "$PKG" ;;
      yum)   yum install -y "$PKG" ;;
      pacman) pacman -Sy --noconfirm "$PKG" ;;
    esac
  else
    info "$PKG already installed"
  fi
}

# Core dependencies
for pkg in bash curl git zsh unzip; do
  install_if_missing "$pkg" "$pkg"
done

install_if_missing "rg" "ripgrep"
install_if_missing "unzip" "unzip"
install_if_missing "git" "git"
install_if_missing "xclip" "xclip"
install_if_missing "nvim" "neovim"
if [ "$PKG_MGR" = "apk" ]; then
  install_if_missing "make" "build-base"
  install_if_missing "gcc" "build-base"
else
  install_if_missing "make" "make"
  install_if_missing "gcc" "gcc"
fi

# Lazygit install
install_lazygit() {
  if ! command -v lazygit > /dev/null; then
    info "Installing lazygit"
    LAZYGIT_VERSION=$(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep tag_name | cut -d '"' -f4)
    curl -Lo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION#v}_Linux_x86_64.tar.gz"
    tar xf /tmp/lazygit.tar.gz -C /usr/local/bin lazygit
    chmod +x /usr/local/bin/lazygit
    rm /tmp/lazygit.tar.gz
  else
    info "lazygit already installed"
  fi
}

# GitHub CLI install
install_gh() {
  if command -v gh > /dev/null; then
    info "GitHub CLI already installed"
    return
  fi

  case "$PKG_MGR" in
    apt)
      info "Installing GitHub CLI (gh) via apt"
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
      chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
      apt update -y && apt install -y gh
      ;;
    apk)
      info "Installing GitHub CLI (gh) via apk (community)"
      apk add gh || true
      ;;
    *)
      info "Skipping gh install (not supported on $PKG_MGR)"
      ;;
  esac
}

# Docker install
install_docker() {
  if ! command -v docker > /dev/null; then
    info "Installing Docker"
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker "$USER_NAME" || true
  else
    info "Docker already installed"
  fi
}

# Set Zsh as default shell
set_default_shell_zsh() {
  if command -v zsh > /dev/null && [ "$(getent passwd "$USER_NAME" | cut -d: -f7)" != "$(command -v zsh)" ]; then
    info "Setting zsh as default shell for $USER_NAME"
    chsh -s "$(command -v zsh)" "$USER_NAME"
  fi
}

# Dotfiles setup
setup_dotfiles() {
  DOTFILES_REPO="https://github.com/jaredbarranco/.files"
  DOTFILES_DIR="$USER_HOME/.files"

  if [ ! -d "$DOTFILES_DIR" ]; then
    info "Cloning dotfiles"
    git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
    chown -R "$USER_NAME:$USER_NAME" "$DOTFILES_DIR"
    su - "$USER_NAME" -c "cd $DOTFILES_DIR && stow ."
  else
    info "Dotfiles already cloned"
  fi
}

# Run everything
install_lazygit
install_gh
install_docker
set_default_shell_zsh
setup_dotfiles

mkdir -p ~/.config/nvim
cd ~/.config/nvim
git clone
info "✅ Bootstrap complete. You may need to reboot or re-login for all changes to apply."
