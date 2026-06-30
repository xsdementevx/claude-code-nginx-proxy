#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="claude-proxy"
NGINX_SITE="/etc/nginx/sites-available/${APP_NAME}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${APP_NAME}"
CONNECTION_FILE="/root/${APP_NAME}-connection.txt"

EMAIL=""
SECRET_PATH=""
ADMIN_USER="admin"
SSH_PORT=""
SETUP_ADMIN=1
SETUP_SECURITY=1
HARDEN_SSH=0
PUBLIC_IP=""

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '\n==> %s\n' "$*"; }
die() { red "ERROR: $*"; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash install.sh

Options:
  --email EMAIL          Let's Encrypt email.
  --secret-path PATH     Secret URL path. Default: random.
  --admin-user USER      Non-root sudo user to create/update. Default: admin.
  --ssh-port PORT        SSH port to keep open. Default: detected or 22.
  --no-admin             Do not create/update admin user.
  --no-security          Do not configure ufw/fail2ban/sysctl/chrony.
  --harden-ssh           Disable root/password SSH for --admin-user. Use only after testing key login.
  -h, --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) EMAIL="${2:?}"; shift 2 ;;
    --secret-path) SECRET_PATH="${2:?}"; shift 2 ;;
    --admin-user) ADMIN_USER="${2:?}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:?}"; shift 2 ;;
    --no-admin) SETUP_ADMIN=0; shift ;;
    --no-security) SETUP_SECURITY=0; shift ;;
    --harden-ssh) HARDEN_SSH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

prompt_if_missing() {
  local var_name="$1" label="$2" value
  if [[ -z "${!var_name}" ]]; then
    if [[ -r /dev/tty ]]; then
      read -r -p "${label}: " value </dev/tty
    elif [[ -t 0 ]]; then
      read -r -p "${label}: " value
    else
      die "${label} is required. Pass --${var_name,,}."
    fi
    [[ -n "${value}" ]] || die "${label} is required."
    printf -v "${var_name}" '%s' "${value}"
  fi
}

public_ipv4() {
  curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash install.sh"
  command -v apt-get >/dev/null 2>&1 || die "Only Ubuntu/Debian with apt-get is supported."
}

validate_inputs() {
  prompt_if_missing EMAIL "Let's Encrypt email"
  [[ "${EMAIL}" == *@*.* ]] || die "Invalid email: ${EMAIL}"

  PUBLIC_IP="$(public_ipv4)"
  [[ "${PUBLIC_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Could not detect public IPv4."

  if [[ -z "${SECRET_PATH}" ]]; then
    SECRET_PATH="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  SECRET_PATH="${SECRET_PATH#/}"
  SECRET_PATH="${SECRET_PATH%/}"
  [[ "${SECRET_PATH}" =~ ^[A-Za-z0-9_-]+$ ]] || die "Secret path may contain only letters, digits, underscore, and hyphen."

  if [[ -z "${SSH_PORT}" ]]; then
    SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
    SSH_PORT="${SSH_PORT:-22}"
  fi
  [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "Invalid SSH port: ${SSH_PORT}"
}

install_packages() {
  info "Installing packages"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl openssl nginx snapd ufw fail2ban chrony
  systemctl enable --now snapd || true
  snap install core || true
  snap refresh core || true
  snap list certbot >/dev/null 2>&1 || snap install --classic certbot
  ln -sf /snap/bin/certbot /usr/bin/certbot
}

first_authorized_keys() {
  local candidates=()
  [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && candidates+=("/home/${SUDO_USER}/.ssh/authorized_keys")
  candidates+=("/root/.ssh/authorized_keys")
  for file in "${candidates[@]}"; do
    [[ -s "${file}" ]] && { printf '%s' "${file}"; return; }
  done
}

configure_admin_user() {
  local key_file
  info "Configuring sudo user ${ADMIN_USER}"
  id "${ADMIN_USER}" >/dev/null 2>&1 || useradd -m -s /bin/bash "${ADMIN_USER}"
  usermod -aG sudo "${ADMIN_USER}"

  key_file="$(first_authorized_keys || true)"
  if [[ -n "${key_file}" ]]; then
    install -d -m 0700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
    install -m 0600 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${key_file}" "/home/${ADMIN_USER}/.ssh/authorized_keys"
    green "Copied SSH keys from ${key_file} to ${ADMIN_USER}."
  else
    yellow "No authorized_keys found to copy. ${ADMIN_USER} was created, but SSH key login was not configured."
  fi
}

configure_ssh_hardening() {
  [[ -s "/home/${ADMIN_USER}/.ssh/authorized_keys" ]] || die "--harden-ssh requires working keys for ${ADMIN_USER}."
  info "Hardening SSH"
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-claude-proxy-hardening.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers ${ADMIN_USER}
EOF
  sshd -t
  systemctl restart ssh || systemctl restart sshd
}

configure_security() {
  info "Configuring firewall, fail2ban, sysctl, chrony"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment SSH
  ufw allow 80/tcp comment HTTP
  ufw allow 443/tcp comment HTTPS
  ufw --force enable

  cat > /etc/fail2ban/jail.d/sshd-claude-proxy.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
maxretry = 3
findtime = 10m
bantime = 1h
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban

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
  info "Preparing nginx for IP certificate issue"
  install -d -m 0755 /var/www/certbot
  rm -f /etc/nginx/sites-enabled/default
  cat > "${NGINX_SITE}" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 "claude-proxy bootstrap\n";
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
  info "Issuing Let's Encrypt IP certificate for ${PUBLIC_IP}"
  certbot certonly --webroot \
    --webroot-path /var/www/certbot \
    --non-interactive \
    --agree-tos \
    --keep-until-expiring \
    --email "${EMAIL}" \
    --deploy-hook "systemctl reload nginx" \
    --preferred-profile shortlived \
    --ip-address "${PUBLIC_IP}"
}

configure_certificate_renewal() {
  info "Configuring automatic certificate renewal"
  cat > /etc/systemd/system/claude-proxy-certbot-renew.service <<'EOF'
[Unit]
Description=Renew Claude proxy Let's Encrypt certificate

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF

  cat > /etc/systemd/system/claude-proxy-certbot-renew.timer <<'EOF'
[Unit]
Description=Run Claude proxy certificate renewal twice daily

[Timer]
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now claude-proxy-certbot-renew.timer
}

write_nginx_proxy_config() {
  info "Writing nginx proxy"
  [[ -f "${NGINX_SITE}" ]] && cp "${NGINX_SITE}" "${NGINX_SITE}.bak.$(date +%Y%m%d-%H%M%S)"
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
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    http2 on;
    server_name _;

    ssl_certificate     /etc/letsencrypt/live/${PUBLIC_IP}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PUBLIC_IP}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${PUBLIC_IP}/chain.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
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

    location /${SECRET_PATH}/ {
        rewrite ^/${SECRET_PATH}/(.*)\$ /\$1 break;
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

    location = /${SECRET_PATH} {
        return 301 /${SECRET_PATH}/;
    }

    location /health {
        access_log off;
        return 200 "OK\\n";
        add_header Content-Type text/plain;
    }
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://${PUBLIC_IP}\$request_uri;
    }
}
EOF
  ln -sf "${NGINX_SITE}" "${NGINX_ENABLED}"
  nginx -t
  systemctl reload nginx
}

write_connection_file() {
  local base_url="https://${PUBLIC_IP}/${SECRET_PATH}"
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

Health check:
curl -i https://${PUBLIC_IP}/health
EOF
  chmod 600 "${CONNECTION_FILE}"
}

verify_install() {
  info "Verifying"
  curl -fsS "https://${PUBLIC_IP}/health" >/dev/null
  curl -sSI "https://${PUBLIC_IP}/" | grep -q " 404 "
  systemctl is-active --quiet nginx
}

main() {
  require_root
  validate_inputs
  install_packages
  [[ "${SETUP_ADMIN}" -eq 1 ]] && configure_admin_user
  [[ "${SETUP_SECURITY}" -eq 1 ]] && configure_security
  [[ "${HARDEN_SSH}" -eq 1 ]] && configure_ssh_hardening
  prepare_nginx_for_certbot
  issue_certificate
  configure_certificate_renewal
  write_nginx_proxy_config
  write_connection_file
  verify_install
  green "Done. Connection details saved to ${CONNECTION_FILE}"
  cat "${CONNECTION_FILE}"
}

main "$@"
