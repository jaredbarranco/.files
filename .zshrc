# ─── PATH helpers ─────────────────────────────────────────────────────
# A container image has a subset of a Mac's toolchain. Prepend a directory
# only when it actually exists, so a missing tool is a no-op instead of a
# useless PATH entry or an error.
path_prepend() {
  if [[ -d "$1" ]]; then
    export PATH="$1:$PATH"
  fi
}

path_append() {
  if [[ -d "$1" ]]; then
    export PATH="$PATH:$1"
  fi
}

# ─── oh-my-zsh ────────────────────────────────────────────────────────
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="robbyrussell"

# Add wisely, as too many plugins slow down shell startup.
plugins=(git)

if [[ -f $ZSH/oh-my-zsh.sh ]]; then
  source $ZSH/oh-my-zsh.sh
else
  # oh-my-zsh is missing (fresh container before bootstrap.sh has run).
  # Set up a minimal but working shell rather than erroring on every startup.
  autoload -Uz compinit && compinit
  setopt PROMPT_SUBST
  PROMPT='%~ %# '
  RPROMPT=''
fi

# ─── editor ───────────────────────────────────────────────────────────
# nvim unconditionally: a container image is unlikely to ship vim, and
# falling back to a missing binary on SSH is worse than a missing nicety.
export EDITOR=nvim
export VISUAL=nvim

# ─── aliases ──────────────────────────────────────────────────────────
alias lg='lazygit'

# macOS only; inert elsewhere but the alias still resolves.
if [[ "$(uname -s)" == "Darwin" ]]; then
  alias dg-open='open -a "DataGrip.app"'
  alias gc='gcloud'
fi

# ─── completions ──────────────────────────────────────────────────────
# Angular CLI. `ng` is not present in most images, and sourcing a completion
# script from a missing binary produces garbage on stderr.
if command -v ng > /dev/null 2>&1; then
  source <(ng completion script)
fi

# nvm via homebrew paths.
export NVM_DIR="$HOME/.nvm"
[[ -s "/opt/homebrew/opt/nvm/nvm.sh" ]] && \
  source "/opt/homebrew/opt/nvm/nvm.sh"
[[ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ]] && \
  source "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"

# bun
export BUN_INSTALL="$HOME/.bun"
path_prepend "$BUN_INSTALL/bin"
if [[ -s "$BUN_INSTALL/_bun" ]]; then
  source "$BUN_INSTALL/_bun"
fi

# pyenv. `pyenv init` rewrites PATH and hooks the shell; skipping it when
# pyenv is absent keeps startup quiet in a container.
export PYENV_ROOT="$HOME/.pyenv"
path_prepend "$PYENV_ROOT/bin"
if command -v pyenv > /dev/null 2>&1; then
  eval "$(pyenv init - zsh)"
fi

# ─── tool paths ───────────────────────────────────────────────────────
path_prepend "$HOME/go/bin"
path_prepend "$HOME/.local/bin"
path_prepend "$HOME/.opencode/bin"

# Editor/agent CLIs installed under the user's home on macOS. These were
# previously hardcoded absolute paths, which do not exist in a container.
path_prepend "$HOME/.codeium/windsurf/bin"
path_prepend "$HOME/.antigravity/antigravity/bin"

# Homebrew keg-only binaries.
path_append "/opt/homebrew/opt/libpq/bin"