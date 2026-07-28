#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

append_once() {
  local file="$1"
  local line="$2"

  touch "$file"
  grep -qxF -- "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

# All personal paths are overridable from dev.yaml envVars.
readonly BEAKER_SETUP_HOME="${BEAKER_SETUP_HOME:-/weka/oe-training-default/xiangf/beaker-setup}"
readonly BEAKER_SSH_KEY_PATH="${BEAKER_SSH_KEY_PATH:-${BEAKER_SETUP_HOME}/.key}"
readonly BEAKER_API_ENV_FILE="${BEAKER_API_ENV_FILE:-${BEAKER_SETUP_HOME}/api.env.sh}"
readonly BEAKER_AGENT_HOME="${BEAKER_AGENT_HOME:-/weka/oe-training-default/xiangf/agent-home}"
readonly SETUP_REPO_SSH_URL="${SETUP_REPO_SSH_URL:-git@github.com:ZNNaliNZ/beaker-setup.git}"
readonly GITHUB_ED25519_FINGERPRINT="${GITHUB_ED25519_FINGERPRINT:-SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU}"
readonly CLAUDE_CHANNEL="${CLAUDE_CHANNEL:-stable}"

readonly SHELL_RC="${DEV_SHELL_RC:-${HOME}/.bashrc}"
export PATH="${HOME}/.local/bin:${PATH}"
export CODEX_HOME="${CODEX_HOME:-${BEAKER_AGENT_HOME}/codex}"
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${BEAKER_AGENT_HOME}/claude}"

append_once "$SHELL_RC" 'export PATH="$HOME/.local/bin:$PATH"'
append_once "$SHELL_RC" "export CODEX_HOME=$(printf '%q' "$CODEX_HOME")"
append_once "$SHELL_RC" "export CLAUDE_CONFIG_DIR=$(printf '%q' "$CLAUDE_CONFIG_DIR")"

mkdir -p "$BEAKER_SETUP_HOME" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"
chmod 0700 "$BEAKER_SETUP_HOME" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"

install_system_tools() {
  local -a root_cmd=()

  if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 \
      || die "system package installation requires root or sudo"
    root_cmd=(sudo -n)
  fi

  command -v apt-get >/dev/null 2>&1 \
    || die "this script currently requires an Ubuntu/Debian base image"

  log "Installing system development tools"
  "${root_cmd[@]}" apt-get update
  "${root_cmd[@]}" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      ffmpeg \
      gdb \
      git \
      htop \
      libgl1 \
      libglib2.0-0 \
      nano \
      openssh-client \
      tmux \
      wget
  "${root_cmd[@]}" apt-get clean
}

install_ai_tools() {
  local installer_dir
  installer_dir="$(mktemp -d)"

  log "Installing Claude Code (${CLAUDE_CHANNEL})"
  curl -fsSL https://claude.ai/install.sh -o "${installer_dir}/claude-install.sh"
  bash "${installer_dir}/claude-install.sh" "$CLAUDE_CHANNEL"

  log "Installing Codex CLI"
  curl -fsSL https://chatgpt.com/codex/install.sh -o "${installer_dir}/codex-install.sh"
  CODEX_NON_INTERACTIVE=true \
    sh "${installer_dir}/codex-install.sh"

  rm -rf -- "$installer_dir"
}

load_api_config() {
  if [[ ! -f "$BEAKER_API_ENV_FILE" ]]; then
    log "No API environment file found; OAuth or existing persistent login can still be used"
    printf 'Optional API file: %s\n' "$BEAKER_API_ENV_FILE"
    return
  fi

  local file_mode
  file_mode="$(stat -c '%a' "$BEAKER_API_ENV_FILE")"
  case "$file_mode" in
    400|600) ;;
    *) die "$BEAKER_API_ENV_FILE must have mode 0400 or 0600 (found $file_mode)" ;;
  esac

  # This is a trusted, user-owned shell file outside the Git repository.
  # shellcheck disable=SC1090
  source "$BEAKER_API_ENV_FILE"
  append_once "$SHELL_RC" "[[ -f $(printf '%q' "$BEAKER_API_ENV_FILE") ]] && source $(printf '%q' "$BEAKER_API_ENV_FILE")"

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    printf '%s\n' "$OPENAI_API_KEY" | codex login --with-api-key >/dev/null
  fi
}

configure_github_ssh() {
  [[ -f "$BEAKER_SSH_KEY_PATH" ]] \
    || die "SSH private key not found: $BEAKER_SSH_KEY_PATH (create it once and add ${BEAKER_SSH_KEY_PATH}.pub to GitHub)"

  local source_mode
  source_mode="$(stat -c '%a' "$BEAKER_SSH_KEY_PATH")"
  case "$source_mode" in
    400|600) ;;
    *) die "$BEAKER_SSH_KEY_PATH must have mode 0400 or 0600 (found $source_mode)" ;;
  esac

  log "Configuring persistent GitHub SSH identity"
  install -d -m 0700 "${HOME}/.ssh"
  install -m 0600 "$BEAKER_SSH_KEY_PATH" "${HOME}/.ssh/beaker_github"
  touch "${HOME}/.ssh/known_hosts"
  chmod 0600 "${HOME}/.ssh/known_hosts"

  if ! ssh-keygen -lf "${HOME}/.ssh/known_hosts" -E sha256 2>/dev/null \
      | awk '{print $2}' \
      | grep -qxF "$GITHUB_ED25519_FINGERPRINT"; then
    local scan_file
    scan_file="$(mktemp)"
    ssh-keyscan -T 10 -t ed25519 github.com > "$scan_file" 2>/dev/null \
      || die "could not fetch the GitHub SSH host key"

    ssh-keygen -lf "$scan_file" -E sha256 \
      | awk '{print $2}' \
      | grep -qxF "$GITHUB_ED25519_FINGERPRINT" \
      || die "GitHub SSH host-key fingerprint did not match the expected value"

    cat "$scan_file" >> "${HOME}/.ssh/known_hosts"
    rm -f -- "$scan_file"
  fi

  local ssh_config="${HOME}/.ssh/config"
  touch "$ssh_config"
  chmod 0600 "$ssh_config"
  if ! grep -qF '# beaker-setup github identity' "$ssh_config"; then
    cat >> "$ssh_config" <<'EOF'

# beaker-setup github identity
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/beaker_github
  IdentitiesOnly yes
  StrictHostKeyChecking yes
EOF
  fi

  local ssh_output=""
  local ssh_status=0
  ssh_output="$(ssh -T -o BatchMode=yes git@github.com 2>&1)" || ssh_status=$?
  if [[ "$ssh_output" != *"successfully authenticated"* ]]; then
    printf '%s\n' "$ssh_output" >&2
    die "GitHub SSH authentication failed (ssh exit status $ssh_status)"
  fi
  printf '%s\n' "$ssh_output"
}

configure_git() {
  git config --global user.name "${GIT_USER_NAME:-ZNNaliNZ}"
  if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
    git config --global user.email "$GIT_USER_EMAIL"
  else
    printf 'Warning: GIT_USER_EMAIL is unset; set it before creating commits.\n' >&2
  fi

  local script_dir setup_repo_root
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  setup_repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
  git -C "$setup_repo_root" remote set-url origin "$SETUP_REPO_SSH_URL"
  git -C "$setup_repo_root" ls-remote origin HEAD >/dev/null
  log "Setup repository now uses SSH: $SETUP_REPO_SSH_URL"
}

configure_shell_tools() {
  append_once "$SHELL_RC" "alias claudec='DISABLE_TELEMETRY=1 claude'"

  local tmux_config="${HOME}/.tmux.conf"
  append_once "$tmux_config" 'set -g mouse on'
  if tmux list-sessions >/dev/null 2>&1; then
    tmux source-file "$tmux_config"
  fi
}

clone_optional_target_repo() {
  [[ -n "${TARGET_REPO_SSH_URL:-}" ]] || return
  [[ "$TARGET_REPO_SSH_URL" == git@github.com:* ]] \
    || die "TARGET_REPO_SSH_URL must be an SSH URL such as git@github.com:OWNER/REPO.git"

  local repo_name target_dir
  repo_name="${TARGET_REPO_SSH_URL##*/}"
  repo_name="${repo_name%.git}"
  target_dir="${TARGET_REPO_DIR:-${HOME}/Projects/${repo_name}}"
  mkdir -p "$(dirname -- "$target_dir")"

  if [[ -d "${target_dir}/.git" ]]; then
    git -C "$target_dir" remote set-url origin "$TARGET_REPO_SSH_URL"
    git -C "$target_dir" fetch --prune origin
    log "Fetched existing target repository: $target_dir"
  else
    git clone "$TARGET_REPO_SSH_URL" "$target_dir"
    log "Cloned target repository: $target_dir"
  fi
}

install_system_tools
install_ai_tools
load_api_config
configure_github_ssh
configure_git
configure_shell_tools
clone_optional_target_repo

log "Installed versions"
claude --version
codex --version
git --version
tmux -V
ffmpeg -version | sed -n '1p'

printf '\nSetup complete.\n'
printf 'Persistent SSH key: %s\n' "$BEAKER_SSH_KEY_PATH"
printf 'Persistent Codex state: %s\n' "$CODEX_HOME"
printf 'Persistent Claude state: %s\n' "$CLAUDE_CONFIG_DIR"
printf 'Run `source %s` in an existing shell to load aliases and environment.\n' "$SHELL_RC"

if [[ "${DEV_KEEP_ALIVE:-1}" == "1" ]]; then
  log "Keeping the Beaker development container alive"
  exec /bin/sleep infinity
fi
