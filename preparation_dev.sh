#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/twentyhq/twenty.git"
TARGET_DIR="twenty"
REQUIRED_NODE="24.5.0"
REQUIRED_YARN="4.9.2"
DOCKER_NETWORK="twenty_network"

log()  { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$*"; }
err()  { printf "\033[1;31m%s\033[0m\n" "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

have_sudo() {
  if need_cmd sudo; then sudo -n true >/dev/null 2>&1 || true; return 0; fi
  return 1
}

require_sudo() {
  if ! need_cmd sudo; then
    err "sudo is required for installing system packages (docker/curl/git/make). Install sudo or run as root."
    exit 1
  fi
}

detect_distro() {
  # outputs: debian|rhel
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    local id_like="${ID_LIKE:-}"
    local id="${ID:-}"
    if [[ "$id" =~ (debian|ubuntu) ]] || [[ "$id_like" =~ debian ]]; then
      echo "debian"; return
    fi
    if [[ "$id" =~ (fedora|rhel|rocky|centos|almalinux) ]] || [[ "$id_like" =~ (rhel|fedora|centos) ]]; then
      echo "rhel"; return
    fi
  fi
  err "Unsupported distro (could not detect via /etc/os-release)."
  exit 1
}

install_packages_debian() {
  require_sudo
  log "Installing prerequisites via apt (curl, git, make, ca-certificates, gnupg)..."
  sudo apt-get update -y
  sudo apt-get install -y curl git make ca-certificates gnupg lsb-release
}

install_packages_rhel() {
  require_sudo
  log "Installing prerequisites via dnf/yum (curl, git, make)..."
  if need_cmd dnf; then
    sudo dnf -y install curl git make ca-certificates
  elif need_cmd yum; then
    sudo yum -y install curl git make ca-certificates
  else
    err "Neither dnf nor yum found. Cannot install packages."
    exit 1
  fi
}

install_docker_debian() {
  require_sudo
  if need_cmd docker; then
    log "Docker already installed."
    return
  fi

  log "Installing Docker on Debian/Ubuntu..."
  # Prefer official Docker repo (more reliable than distro docker.io versions).
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  if [[ -z "$codename" ]]; then
    codename="$(lsb_release -cs 2>/dev/null || true)"
  fi

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
    $codename stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rhel() {
  require_sudo
  if need_cmd docker; then
    log "Docker already installed."
    return
  fi

  log "Installing Docker on Fedora/Rocky/RHEL-like..."
  if need_cmd dnf; then
    # Add Docker repo
    sudo dnf -y install dnf-plugins-core || true
    sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || true
    # On Rocky/RHEL, repo URL "fedora" usually still works for docker-ce packages; if not, user must adjust manually.
    sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  elif need_cmd yum; then
    sudo yum -y install yum-utils
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    err "Neither dnf nor yum found."
    exit 1
  fi
}

enable_start_docker() {
  require_sudo
  log "Enabling & starting Docker service..."
  sudo systemctl enable --now docker || true
  # Some systems use service scripts
  sudo service docker start >/dev/null 2>&1 || true
}

ensure_docker_group() {
  require_sudo
  local user="${SUDO_USER:-$USER}"

  if getent group docker >/dev/null 2>&1; then
    true
  else
    log "Creating docker group..."
    sudo groupadd docker || true
  fi

  if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
    log "User '$user' is already in docker group."
  else
    log "Adding user '$user' to docker group..."
    sudo usermod -aG docker "$user"
    warn "Group change applied, but your current shell may not have it yet."
    warn "You can run: newgrp docker   (or log out/in) to apply immediately."
  fi
}

check_docker_access() {
  # Don't hard-fail here if group isn't applied yet; give actionable output.
  if docker info >/dev/null 2>&1; then
    log "Docker daemon reachable ✅"
  else
    warn "Docker daemon not reachable from this shell."
    warn "If you just added yourself to docker group, run: newgrp docker"
    warn "Or log out and log back in."
  fi
}

ensure_git_clone() {
  log "Cloning repo (or updating if already present)..."
  if [[ -d "$TARGET_DIR/.git" ]]; then
    log "Repo already exists in ./$TARGET_DIR — pulling latest..."
    git -C "$TARGET_DIR" fetch --all --prune
  else
    git clone "$REPO_URL" "$TARGET_DIR"
  fi
}

ensure_nvm_node_yarn() {
  # Optional: sets up the dev runtime without touching system node.
  log "Ensuring nvm + Node $REQUIRED_NODE + Yarn $REQUIRED_YARN (user-space)..."

  if ! need_cmd curl; then
    warn "curl missing; cannot install nvm automatically."
    return
  fi

  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    log "Installing nvm..."
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi

  # shellcheck disable=SC1090
  [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"

  if ! need_cmd nvm; then
    warn "nvm still not available in this shell. Restart your terminal after the script."
    return
  fi

  nvm install "$REQUIRED_NODE" >/dev/null
  nvm use "$REQUIRED_NODE" >/dev/null

  corepack enable >/dev/null 2>&1 || true
  corepack prepare "yarn@$REQUIRED_YARN" --activate >/dev/null 2>&1 || true

  log "Runtime OK: node=$(node -v) yarn=$(yarn -v 2>/dev/null || echo 'n/a')"
}

main() {
  local distro
  distro="$(detect_distro)"

  log "Bootstrap for Twenty on distro family: $distro"

  # Base tools
  if [[ "$distro" == "debian" ]]; then
    install_packages_debian
    install_docker_debian
  else
    install_packages_rhel
    install_docker_rhel
  fi

  enable_start_docker
  ensure_docker_group
  check_docker_access

  # Clone
  ensure_git_clone

  # cd into repo
  log "Entering repo directory: $TARGET_DIR"
  cd "$TARGET_DIR"

  # Optional: also ensure Node/Yarn toolchain via nvm (matches Twenty constraints)
  ensure_nvm_node_yarn

  log "Done. You are now in: $(pwd)"
  warn "If Docker access still fails, run: newgrp docker  (or relog) then continue."
}

main "$@"

