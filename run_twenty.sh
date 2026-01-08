#!/usr/bin/env bash
set -euo pipefail

REQUIRED_NODE="24.5.0"
REQUIRED_YARN="4.9.2"
DOCKER_NETWORK="twenty_network"

RESET_DB=1
INSTALL_DEPS=1

usage() {
  cat <<EOF
Usage: ./dev-run.sh [options]

Options:
  --no-reset        Do not reset database
  --no-install      Do not run yarn install
  --server-only     Start only backend (twenty-server)
  --front-only      Start only frontend (twenty-front)
  --help            Show this help
EOF
}

SERVER_ONLY=0
FRONT_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-reset) RESET_DB=0; shift ;;
    --no-install) INSTALL_DEPS=0; shift ;;
    --server-only) SERVER_ONLY=1; shift ;;
    --front-only) FRONT_ONLY=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

log()  { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$*"; }
err()  { printf "\033[1;31m%s\033[0m\n" "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

need_sudo() {
  command -v sudo >/dev/null 2>&1
}

ensure_inotify_limits() {
  local target_watches=524288
  local target_instances=1024

  # Valeurs actuelles (si sysctl dispo)
  if ! command -v sysctl >/dev/null 2>&1; then
    warn "sysctl not found; cannot check inotify limits. Skipping."
    return 0
  fi

  local cur_watches cur_instances
  cur_watches="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
  cur_instances="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"

  log "Checking inotify limits: watches=$cur_watches instances=$cur_instances"

  # Si déjà OK -> rien à faire
  if [[ "$cur_watches" -ge "$target_watches" && "$cur_instances" -ge "$target_instances" ]]; then
    log "inotify limits OK ✅"
    return 0
  fi

  warn "inotify limits too low for hot reload. Need watches=$target_watches instances=$target_instances"

  if ! need_sudo; then
    err "sudo not available. Run manually:"
    err "  sysctl fs.inotify.max_user_watches=$target_watches"
    err "  sysctl fs.inotify.max_user_instances=$target_instances"
    return 1
  fi

  log "Raising inotify limits (temporary + persistent)..."

  # Temporaire (immédiat)
  sudo sysctl "fs.inotify.max_user_watches=$target_watches" >/dev/null
  sudo sysctl "fs.inotify.max_user_instances=$target_instances" >/dev/null

  # Persistant
  sudo tee /etc/sysctl.d/99-inotify-twenty.conf >/dev/null <<EOF
fs.inotify.max_user_watches=$target_watches
fs.inotify.max_user_instances=$target_instances
EOF

  sudo sysctl --system >/dev/null 2>&1 || true

  log "inotify limits updated ✅"
}


ensure_nvm_node() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
  fi

  if ! need_cmd nvm; then
    err "nvm not found in this shell. Open a new terminal or source your shell rc, then rerun."
    exit 1
  fi

  log "Using Node $REQUIRED_NODE (nvm)..."
  nvm use "$REQUIRED_NODE" >/dev/null 2>&1 || {
    err "Node $REQUIRED_NODE not installed via nvm. Install it: nvm install $REQUIRED_NODE"
    exit 1
  }

  local v
  v="$(node -v | sed 's/^v//')"
  [[ "$v" == "$REQUIRED_NODE" ]] || { err "Node is $v but required is $REQUIRED_NODE"; exit 1; }
}

ensure_yarn_corepack() {
  if ! need_cmd corepack; then
    err "corepack not found (should come with Node)."
    exit 1
  fi

  # If system yarn is ahead in PATH, it can sabotage version checks.
  if [[ "$(command -v yarn 2>/dev/null || true)" == "/usr/bin/yarn" ]]; then
    warn "System yarn detected at /usr/bin/yarn. This may break Twenty."
    warn "Recommended: remove it (apt remove yarn / dnf remove yarn) so corepack controls yarn."
  fi

  log "Ensuring Yarn $REQUIRED_YARN via corepack..."
  corepack enable >/dev/null 2>&1 || true
  corepack prepare "yarn@$REQUIRED_YARN" --activate >/dev/null 2>&1 || true

  # Verify yarn is runnable
  if ! need_cmd yarn; then
    err "yarn not found after corepack activation."
    exit 1
  fi

  log "Yarn OK: v$(yarn -v)"
}

ensure_env_files() {
  log "Ensuring .env files exist..."
  [[ -f packages/twenty-server/.env ]] || cp packages/twenty-server/.env.example packages/twenty-server/.env
  [[ -f packages/twenty-front/.env  ]] || cp packages/twenty-front/.env.example  packages/twenty-front/.env

  # Guard: avoid the 'password must be a string' trap
  if ! grep -Eq '^(DATABASE_URL|PG_PASSWORD)=' packages/twenty-server/.env; then
    warn "DB credentials missing in packages/twenty-server/.env — adding local defaults."
    cat >> packages/twenty-server/.env <<'EOF'

# Added by dev-run.sh (local defaults)
PG_HOST=localhost
PG_PORT=5432
PG_USER=postgres
PG_PASSWORD=postgres
PG_DATABASE=default
EOF
  fi
}

ensure_docker_deps() {
  need_cmd docker || { err "docker not installed"; exit 1; }
  need_cmd make   || { err "make not installed"; exit 1; }

  docker info >/dev/null 2>&1 || {
    err "Docker daemon not reachable from this shell."
    err "If you just joined docker group: run 'newgrp docker' or log out/in."
    exit 1
  }

  log "Ensuring docker network exists..."
  docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || docker network create "$DOCKER_NETWORK" >/dev/null

  # -------- POSTGRES (idempotent, non-blocking) --------
  log "Ensuring Postgres is running..."
  if docker ps --format '{{.Names}}' | grep -q '^twenty_pg$'; then
    log "Postgres already running (twenty_pg)."
  else
    # If exists but stopped, remove it
    if docker ps -a --format '{{.Names}}' | grep -q '^twenty_pg$'; then
      docker rm -f twenty_pg >/dev/null 2>&1 || true
    fi

    # Try make, but DO NOT trust its exit code blindly
    set +e
    make postgres-on-docker
    local rc=$?
    set -e

    # If make failed, validate that Postgres is actually reachable
    if [[ $rc -ne 0 ]]; then
      warn "make postgres-on-docker returned $rc (often happens if DBs already exist). Validating Postgres..."
      if docker ps --format '{{.Names}}' | grep -q '^twenty_pg$' \
         && docker exec twenty_pg pg_isready -U postgres -d postgres >/dev/null 2>&1; then
        warn "Postgres is up. Continuing."
      else
        err "Postgres is NOT reachable and make failed. Aborting."
        exit 1
      fi
    fi
  fi

  # -------- REDIS (idempotent) --------
  log "Ensuring Redis is running..."
  if docker ps --format '{{.Names}}' | grep -q '^twenty_redis$'; then
    log "Redis already running (twenty_redis)."
  else
    if docker ps -a --format '{{.Names}}' | grep -q '^twenty_redis$'; then
      docker rm -f twenty_redis >/dev/null 2>&1 || true
    fi
    make redis-on-docker
  fi
}


install_deps() {
  if [[ "$INSTALL_DEPS" -eq 0 ]]; then
    log "Skipping yarn install (--no-install)."
    return
  fi

  if should_run_yarn_install; then
    log "Dependencies changed → running yarn install..."
    yarn install
    mkdir -p .yarn
    sha256sum yarn.lock | awk '{print $1}' > .yarn/.last-install-lock-hash
  else
    log "Dependencies unchanged → skipping yarn install ✅"
  fi
}

reset_db() {
  if [[ "$RESET_DB" -eq 1 ]]; then
    log "Resetting database..."
    npx nx database:reset twenty-server
  else
    log "Skipping DB reset (--no-reset)."
  fi
}

start_dev() {
  log "Starting dev (hot reload)..."

  if [[ "$SERVER_ONLY" -eq 1 && "$FRONT_ONLY" -eq 1 ]]; then
    err "Choose only one: --server-only or --front-only"
    exit 1
  fi

  if [[ "$SERVER_ONLY" -eq 1 ]]; then
    npx nx start twenty-server
    return
  fi

  if [[ "$FRONT_ONLY" -eq 1 ]]; then
    npx nx start twenty-front
    return
  fi

  # Default: start all
  npx nx start
}

should_run_yarn_install() {
  local lockfile="yarn.lock"
  local stamp=".yarn/.last-install-lock-hash"

  # Si le lockfile n'existe pas, on installe (cas anormal)
  [[ -f "$lockfile" ]] || return 0

  local current_hash
  current_hash="$(sha256sum "$lockfile" | awk '{print $1}')"

  # Si on n'a jamais installé
  [[ -f "$stamp" ]] || return 0

  local last_hash
  last_hash="$(cat "$stamp")"

  [[ "$current_hash" != "$last_hash" ]]
}



main() {
  # Must be run from repo root
  [[ -f package.json && -d packages ]] || {
    err "Run this script from the Twenty repo root (the folder that contains package.json)."
    exit 1
  }

  ensure_nvm_node
  ensure_yarn_corepack
  ensure_env_files
  ensure_docker_deps
  install_deps
  reset_db
  start_dev
}

main

