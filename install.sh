#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="claude-proxy"
NGINX_SITE="/etc/nginx/sites-available/${APP_NAME}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${APP_NAME}"
CONNECTION_FILE="/root/${APP_NAME}-connection.txt"

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '\n==> %s\n' "$*"; }
die() { red "ERROR: $*"; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root on the server."
  fi
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || die "Only Ubuntu/Debian with apt-get is supported."
}

prompt() {
  local label="$1" default="${2:-}" value
  if [[ -n "${default}" ]]; then
    read -r -p "${label} [${default}]: " value
    printf '%s' "${value:-$default}"
  else
    while true; do
      read -r -p "${label}: " value
      if [[ -n "${value}" ]]; then
        printf '%s' "${value}"
        return
      fi
      yellow "Value is required."
    done
  fi
}

prompt_optional() {
  local label="$1" default="${2:-}" value
  if [[ -n "${default}" ]]; then
    read -r -p "${label} [${default}]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "${label}: " value
    printf '%s' "${value}"
  fi
}

prompt_yes_no() {
  local label="$1" default="${2:-y}" value suffix
  if [[ "${default}" == "y" ]]; then suffix="Y/n"; else suffix="y/N"; fi
  while true; do
    read -r -p "${label} [${suffix}]: " value
    value="${value:-$default}"
    case "${value,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) yellow "Answer y or n." ;;
    esac
  done
}

random_secret_path() {
  openssl rand -hex 16
}

public_ip() {
  curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

domain_a_records() {
  local domain="$1"
  getent ahostsv4 "${domain}" | awk '{print $1}' | sort -u
}

install_packages() {
  info "Installing base packages"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl openssl nginx certbot python3-certbot-nginx \
    ufw fail2ban chrony
}

configure_admin_user() {
  local admin_user="$1" public_key="$2"

  info "Creating sudo user ${admin_user}"
  if ! id "${admin_user}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${admin_user}"
  fi
  usermod -aG sudo "${admin_user}"

  if [[ -n "${public_key}" ]]; then
    install -d -m 0700 -o "${admin_user}" -g "${admin_user}" "/home/${admin_user}/.ssh"
    touch "/home/${admin_user}/.ssh/authorized_keys"
    if ! grep -qxF "${public_key}" "/home/${admin_user}/.ssh/authorized_keys"; then
      printf '%s\n' "${public_key}" >> "/home/${admin_user}/.ssh/authorized_keys"
    fi
    chmod 600 "/home/${admin_user}/.ssh/authorized_keys"
    chown -R "${admin_user}:${admin_user}" "/home/${admin_user}/.ssh"
  fi
}

configure_ssh_hardening() {
  local ssh_port="$1" admin_user="$2"

  info "Configuring SSH hardening"
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-claude-proxy-hardening.conf <<EOF
Port ${ssh_port}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers ${admin_user}
EOF
  sshd -t
  systemctl restart ssh || systemctl restart sshd
}

configure_firewall_fail2ban() {
  local ssh_port="$1"

  info "Configuring UFW and fail2ban"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${ssh_port}/tcp" comment SSH
  ufw allow 80/tcp comment HTTP
  ufw allow 443/tcp comment HTTPS
  ufw --force enable

  cat > /etc/fail2ban/jail.d/sshd-claude-proxy.local <<EOF
[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
backend = systemd
maxretry = 3
findtime = 10m
bantime = 1h
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban
}

configure_sysctl_chrony() {
  info "Configuring sysctl hardening and chrony"
  cat > /etc/sysctl.d/99-claude-proxy-security.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
EOF
  sysctl -p /etc/sysctl.d/99-claude-proxy-security.conf
  systemctl enable chrony
  systemctl restart chrony
}

prepare_nginx_for_certbot() {
  local domain="$1"

  info "Preparing nginx for ACME challenge"
  install -d -m 0755 /var/www/certbot
  rm -f /etc/nginx/sites-enabled/default
  cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 "claude-proxy bootstrap\\n";
        add_header Content-Type text/plain;
    }
}
EOF
  ln -sf "${NGINX_SITE}" "${NGINX_ENABLED}"
  nginx -t
  systemctl enable nginx
  systemctl reload nginx || systemctl restart nginx
}

issue_certificate() {
  local domain="$1" email="$2"

  info "Issuing Let's Encrypt certificate for ${domain}"
  certbot certonly --webroot \
    --webroot-path /var/www/certbot \
    --non-interactive \
    --agree-tos \
    --email "${email}" \
    -d "${domain}"
}

write_nginx_proxy_config() {
  local domain="$1" secret_path="$2"

  info "Writing nginx reverse proxy config"
  [[ "${secret_path}" == /* ]] && secret_path="${secret_path#/}"
  secret_path="${secret_path%/}"

  if [[ -f "${NGINX_SITE}" ]]; then
    cp "${NGINX_SITE}" "${NGINX_SITE}.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  cat > "${NGINX_SITE}" <<EOF
limit_req_zone \$binary_remote_addr zone=claude_api:10m rate=30r/s;

upstream anthropic_backend {
    zone anthropic_backend 64k;
    resolver 1.1.1.1 8.8.8.8 valid=30s ipv6=off;
    resolver_timeout 5s;
    server api.anthropic.com:443 resolve;
    keepalive 16;
    keepalive_timeout 60s;
    keepalive_requests 100;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name ${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${domain}/chain.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;

    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Content-Type-Options "nosniff" always;

    access_log /var/log/nginx/claude-proxy-access.log combined;
    error_log  /var/log/nginx/claude-proxy-error.log  warn;

    client_max_body_size      64m;
    client_body_buffer_size   1m;
    client_body_timeout       120s;
    proxy_max_temp_file_size  0;

    limit_req zone=claude_api burst=50 nodelay;

    location / {
        return 404;
    }

    location /${secret_path}/ {
        rewrite ^/${secret_path}/(.*)\$ /\$1 break;
        proxy_pass https://anthropic_backend;
        proxy_http_version 1.1;
        proxy_pass_request_headers on;
        proxy_set_header Host api.anthropic.com;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_connect_timeout 30s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        proxy_ssl_server_name on;
        proxy_ssl_name api.anthropic.com;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_ssl_session_reuse on;
    }

    location = /${secret_path} {
        return 301 /${secret_path}/;
    }

    location /health {
        access_log off;
        return 200 "OK\\n";
        add_header Content-Type text/plain;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
  ln -sf "${NGINX_SITE}" "${NGINX_ENABLED}"
  nginx -t
  systemctl reload nginx
}

write_connection_file() {
  local domain="$1" secret_path="$2"
  local base_url="https://${domain}/${secret_path}"

  cat > "${CONNECTION_FILE}" <<EOF
Claude Code proxy is ready.

Base URL:
${base_url}

Bash/Zsh:
export ANTHROPIC_BASE_URL="${base_url}"
claude

PowerShell:
\$env:ANTHROPIC_BASE_URL = "${base_url}"
claude

Claude Code with OAuth token, if needed:
export ANTHROPIC_BASE_URL="${base_url}"
export CLAUDE_CODE_OAUTH_TOKEN="<your Claude Code OAuth token>"
claude

Health check:
curl -i https://${domain}/health

Proxy smoke test, requires a valid Claude Code/Auth header on the client:
curl -i "${base_url}/v1/models" \\
  -H "Authorization: Bearer <your Claude Code OAuth token>"
EOF
  chmod 600 "${CONNECTION_FILE}"
}

main() {
  require_root
  require_apt

  cat <<'EOF'
Claude Code nginx proxy installer

This reproduces the existing lightweight production layout:
- nginx terminates TLS
- a random secret URL path hides the proxy
- requests under that path are rewritten and proxied to https://api.anthropic.com
- client Authorization/x-api-key headers pass through to Anthropic
- no Anthropic secrets are stored on the server
EOF

  local domain email secret_path ssh_port server_ip dns_ips
  local setup_admin setup_ssh setup_security admin_user public_key confirm

  domain="$(prompt "Proxy domain, e.g. claudecode.example.com")"
  email="$(prompt "Let's Encrypt email")"
  ssh_port="$(prompt "SSH port to keep open" "22")"

  if prompt_yes_no "Generate random secret URL path" "y"; then
    secret_path="$(random_secret_path)"
  else
    secret_path="$(prompt "Secret URL path without leading slash")"
    secret_path="${secret_path#/}"
    secret_path="${secret_path%/}"
  fi
  [[ "${secret_path}" =~ ^[A-Za-z0-9_-]+$ ]] || die "Secret path may contain only letters, digits, underscore, and hyphen."

  server_ip="$(public_ip)"
  dns_ips="$(domain_a_records "${domain}" || true)"
  if [[ -n "${server_ip}" ]]; then
    info "DNS check"
    echo "Server public IP: ${server_ip}"
    echo "Domain A records: ${dns_ips:-none}"
    if ! grep -qxF "${server_ip}" <<<"${dns_ips:-}"; then
      yellow "Domain does not currently resolve to this server IP."
      yellow "Create an A record: ${domain} -> ${server_ip}, wait for DNS propagation, then continue."
      if ! prompt_yes_no "Continue anyway" "n"; then
        exit 1
      fi
    fi
  fi

  if prompt_yes_no "Create/update a non-root sudo admin user" "y"; then
    setup_admin="y"
    admin_user="$(prompt "Admin sudo username" "admin")"
    public_key="$(prompt_optional "Admin SSH public key, leave empty to skip key install")"
  else
    setup_admin="n"
    admin_user="$(id -un 2>/dev/null || echo admin)"
    public_key=""
  fi

  if prompt_yes_no "Configure UFW, fail2ban, sysctl, and chrony" "y"; then
    setup_security="y"
  else
    setup_security="n"
    yellow "Security stack skipped. Make sure SSH, 80, and 443 are reachable safely."
  fi

  setup_ssh="n"

  install_packages

  if [[ "${setup_admin}" == "y" ]]; then
    configure_admin_user "${admin_user}" "${public_key}"
    yellow "Open a second terminal now and test: ssh ${admin_user}@${domain} 'sudo whoami'"
    if prompt_yes_no "After testing key login in another terminal, disable root/password SSH" "n"; then
      read -r -p "Type I_HAVE_TESTED_SSH_LOGIN to confirm: " confirm
      if [[ "${confirm}" == "I_HAVE_TESTED_SSH_LOGIN" ]]; then
        setup_ssh="y"
      else
        yellow "SSH lockout-prone hardening skipped."
      fi
    fi
  fi
  if [[ "${setup_ssh}" == "y" ]]; then
    configure_ssh_hardening "${ssh_port}" "${admin_user}"
  fi
  if [[ "${setup_security}" == "y" ]]; then
    configure_firewall_fail2ban "${ssh_port}"
    configure_sysctl_chrony
  fi

  prepare_nginx_for_certbot "${domain}"
  issue_certificate "${domain}" "${email}"
  write_nginx_proxy_config "${domain}" "${secret_path}"
  write_connection_file "${domain}" "${secret_path}"

  info "Verification"
  curl -fsS "https://${domain}/health" >/dev/null
  systemctl is-active --quiet nginx
  green "Done. Connection details saved to ${CONNECTION_FILE}"
  cat "${CONNECTION_FILE}"
}

main "$@"
