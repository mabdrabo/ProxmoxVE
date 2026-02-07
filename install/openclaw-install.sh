#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/openclaw/openclaw

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y ca-certificates curl gnupg git
msg_ok "Installed Dependencies"

# Install Node.js 22 + OpenClaw
NODE_VERSION="22" NODE_MODULE="openclaw@latest" setup_nodejs

# Provider prompt (NO secrets). Save only hints.
PROVIDER="later"
if command -v whiptail >/dev/null 2>&1; then
  PROVIDER=$(whiptail --title "OpenClaw Provider" --menu \
    "Select how OpenClaw should reach an LLM (no keys collected here)." 18 80 10 \
    "ollama-remote" "Use an existing Ollama server (you provide URL)" \
    "later"         "Configure during 'openclaw onboard'" \
    3>&1 1>&2 2>&3) || PROVIDER="later"
fi

mkdir -p /root/.openclaw
PROVIDER_HINT="/root/.openclaw/provider-hint.txt"
: > "${PROVIDER_HINT}"
chmod 0644 "${PROVIDER_HINT}"

case "${PROVIDER}" in
  ollama-remote)
    if command -v whiptail >/dev/null 2>&1; then
      OLLAMA_URL=$(whiptail --inputbox \
        "Enter Ollama base URL (example: http://192.168.1.10:11434)" 10 80 \
        "http://127.0.0.1:11434" 3>&1 1>&2 2>&3) || true
    fi
    OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
    {
      echo "provider=ollama"
      echo "ollama_host=${OLLAMA_URL}"
      echo ""
      echo "Note: Configure OpenClaw to use this during 'openclaw onboard'."
    } >> "${PROVIDER_HINT}"
    ;;
  *)
    {
      echo "provider=later"
      echo ""
      echo "Run 'openclaw onboard' to configure a provider."
    } >> "${PROVIDER_HINT}"
    ;;
esac

# Write a safe default config; ct/openclaw.sh will enforce final bind/port post-build
msg_info "Writing OpenClaw default config"
cat <<'CONF' >/root/.openclaw/openclaw.json
{
  "gateway": {
    "bind": "loopback",
    "port": 18789
  }
}
CONF
msg_ok "Wrote OpenClaw config"

msg_info "Creating systemd service"
cat <<'EOF' >/etc/systemd/system/openclaw.service
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/openclaw gateway --allow-unconfigured
Restart=always
RestartSec=10
Environment=NODE_ENV=production
Environment=PATH=/usr/bin:/usr/local/bin:/bin

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable -q --now openclaw
msg_ok "Created & started service"

motd_ssh
customize
cleanup_lxc

msg_ok "Next steps:"
echo -e "${INFO}${YW}Run (inside the container):${CL}"
echo -e "${TAB}${YW}openclaw onboard${CL}"
echo -e "${INFO}${YW}Provider hint saved to:${CL} ${TAB}${YW}${PROVIDER_HINT}${CL}"
echo -e "${INFO}${YW}Security default: gateway binds to loopback unless changed in the host script.${CL}"

