#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/mabdrabo/ProxmoxVE/feature/openclaw/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/openclaw/openclaw

APP="OpenClaw"
var_tags="${var_tags:-ai;assistant;chatops}"

# --- Dev/Test override (lets fork installs work even though build.func uses upstream for install scripts) ---
SCRIPT_REPO="${SCRIPT_REPO:-mabdrabo/ProxmoxVE}"
SCRIPT_BRANCH="${SCRIPT_BRANCH:-feature/openclaw}"

# --- App Defaults (lightweight, configurable via env when invoking script) ---
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

# Security-first defaults (NOT whitelisted by build.func; we apply them post-build)
# User may override via:
#   var_gateway_port=18789 var_gateway_bind=lan bash -c "$(curl -fsSL .../ct/openclaw.sh)"
var_gateway_port="${var_gateway_port:-18789}"
var_gateway_bind="${var_gateway_bind:-loopback}" # loopback | lan

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  if [[ ! -f /etc/systemd/system/openclaw.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Stopping OpenClaw"
  systemctl stop openclaw
  msg_ok "Stopped OpenClaw"

  NODE_VERSION="22" NODE_MODULE="openclaw@latest" setup_nodejs

  msg_info "Starting OpenClaw"
  systemctl start openclaw
  msg_ok "Started OpenClaw"

  msg_ok "Updated successfully!"
  exit
}

# -------------------- APT Cacher Detection (host-side) --------------------
function detect_apt_cacher_ng() {
  # Respect explicit user/app/global configuration
  if [[ -n "${var_apt_cacher:-}" || -n "${var_apt_cacher_ip:-}" ]]; then
    return 0
  fi

  local detected="no"
  if systemctl is-active --quiet apt-cacher-ng 2>/dev/null; then
    detected="yes"
  elif dpkg -s apt-cacher-ng >/dev/null 2>&1; then
    detected="yes"
  fi
  [[ "${detected}" != "yes" ]] && return 0

  local brg="${var_brg:-vmbr0}"
  local host_ip
  host_ip="$(ip -4 addr show dev "${brg}" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
  if [[ -z "${host_ip}" ]]; then
    host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  [[ -z "${host_ip}" ]] && return 0

  if ! curl -s --connect-timeout 2 "http://${host_ip}:3142" >/dev/null 2>&1; then
    msg_warn "apt-cacher-ng detected but not reachable at ${host_ip}:3142"
    return 0
  fi

  if command -v whiptail >/dev/null 2>&1; then
    if whiptail --title "APT Cacher Detected" --yesno \
      "apt-cacher-ng is running and reachable at:\n\n  http://${host_ip}:3142\n\nUse it to speed up APT downloads for this install?" 14 72; then
      var_apt_cacher="yes"
      var_apt_cacher_ip="${host_ip}"
      msg_ok "APT cacher enabled: ${var_apt_cacher_ip}:3142"
    else
      msg_info "APT cacher will not be used"
    fi
  else
    # Non-interactive: enable automatically if detected/reachable
    var_apt_cacher="yes"
    var_apt_cacher_ip="${host_ip}"
    msg_ok "APT cacher enabled: ${var_apt_cacher_ip}:3142"
  fi
}

function apply_openclaw_gateway_config_postbuild() {
  # Apply bind/port deterministically (don’t rely on passing custom env vars through build.func)
  # Uses CTID variable created by build.func. Also IP is populated.
  local port="${var_gateway_port}"
  local bind="${var_gateway_bind}"

  msg_info "Applying OpenClaw gateway config (bind=${bind}, port=${port})"

  pct exec "$CTID" -- bash -lc "mkdir -p /root/.openclaw"
  pct exec "$CTID" -- bash -lc "cat > /root/.openclaw/openclaw.json <<'EOF'
{
  \"gateway\": {
    \"bind\": \"${bind}\",
    \"port\": ${port}
  }
}
EOF"

  # Restart to apply (service is created+enabled in install script)
  pct exec "$CTID" -- bash -lc "systemctl daemon-reload >/dev/null 2>&1 || true"
  pct exec "$CTID" -- bash -lc "systemctl restart openclaw >/dev/null 2>&1 || systemctl start openclaw >/dev/null 2>&1 || true"

  msg_ok "OpenClaw gateway config applied"
}

start
detect_apt_cacher_ng
build_container

# Verify install happened; if not, fallback to running install from this fork/branch
if ! pct exec "$CTID" -- bash -lc 'command -v openclaw >/dev/null 2>&1'; then
  msg_warn "Upstream install script fetch likely 404'd. Running fallback installer from ${SCRIPT_REPO}@${SCRIPT_BRANCH}..."

  pct exec "$CTID" -- bash -lc "
    set -euo pipefail
    export FUNCTIONS_FILE_PATH=\"\$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/install.func)\"
    export APPLICATION='${APP}'
    export app='${NSAPP}'
    export VERBOSE='${VERBOSE:-no}'
    bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${SCRIPT_REPO}/${SCRIPT_BRANCH}/install/${var_install}.sh)\"
  "

  # Re-check
  if ! pct exec "$CTID" -- bash -lc 'command -v openclaw >/dev/null 2>&1'; then
    msg_error "Install failed: openclaw still not found after fallback installer."
    exit
  fi

  msg_ok "Fallback installer completed."
fi

description

# Enforce our (possibly user-overridden) bind/port after build completes
apply_openclaw_gateway_config_postbuild

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Next step (inside the container):${CL}"
echo -e "${TAB}${YW}openclaw onboard${CL}"
echo -e "${INFO}${YW}Access (service started):${CL}"
if [[ "${var_gateway_bind}" == "loopback" ]]; then
  echo -e "${TAB}${YW}Default bind is loopback (safe). Use SSH port-forwarding:${CL}"
  echo -e "${TAB}${YW}ssh -L ${var_gateway_port}:localhost:${var_gateway_port} root@${IP}${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://localhost:${var_gateway_port}${CL}"
else
  echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:${var_gateway_port}${CL}"
fi

