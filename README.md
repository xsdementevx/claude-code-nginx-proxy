# Claude Code nginx proxy

This kit sets up a lightweight Claude Code proxy like the current production server:

- Ubuntu/Debian VPS
- `nginx` terminates HTTPS
- a random secret URL path hides the proxy endpoint
- requests under that path are proxied to `https://api.anthropic.com`
- Claude Code auth headers pass through from your local machine
- no Anthropic token is stored on the server

The installer is `install.sh`.

## Beginner quick start

Use this if you just bought a VPS and do not want to learn server administration.

You need three things:

```text
SERVER_IP     The IP address from your VPS provider panel
DOMAIN        A domain or subdomain you control, for example claude.example.com
EMAIL         Your email for the free HTTPS certificate
```

### Step 1. Point the domain to the VPS

Open your domain/DNS panel and create one record:

```text
Type: A
Name: claude
Value: SERVER_IP
```

Example:

```text
Domain: example.com
Name: claude
Value: 203.0.113.10
Result: claude.example.com
```

If you see an `AAAA` record for the same name and you do not use IPv6, delete it.

Wait 5-15 minutes.

### Step 2. Open a terminal on your computer

Windows:

```text
Start menu -> PowerShell
```

macOS:

```text
Applications -> Utilities -> Terminal
```

Linux:

```text
Open Terminal
```

### Step 3. Run one command from your computer

Replace only `SERVER_IP`:

```bash
ssh -t root@SERVER_IP "curl -fsSL https://raw.githubusercontent.com/xsdementevx/claude-code-nginx-proxy/main/install.sh | bash"
```

If your VPS provider gave you a username that is not `root`, use it:

```bash
ssh -t USER@SERVER_IP "curl -fsSL https://raw.githubusercontent.com/xsdementevx/claude-code-nginx-proxy/main/install.sh | sudo bash"
```

### Step 4. Answer two questions

When the installer asks:

```text
Proxy domain:
```

enter your domain:

```text
claude.example.com
```

When it asks:

```text
Let's Encrypt email:
```

enter your email:

```text
you@example.com
```

### Step 5. Copy the final Claude Code setting

At the end you will see something like:

```bash
export ANTHROPIC_BASE_URL="https://claude.example.com/random-secret-path"
```

On macOS/Linux, run it before Claude Code:

```bash
export ANTHROPIC_BASE_URL="https://claude.example.com/random-secret-path"
claude
```

On Windows PowerShell:

```powershell
$env:ANTHROPIC_BASE_URL = "https://claude.example.com/random-secret-path"
claude
```

### How to know it worked

Open this in your browser:

```text
https://claude.example.com/health
```

You should see:

```text
OK
```

Open the root page:

```text
https://claude.example.com/
```

It should show `404`. That is normal.

### Common beginner problems

- SSH says password is wrong: use the root password or SSH key from your VPS provider.
- Certificate fails: the domain does not point to the VPS yet.
- Certificate fails with IPv6: remove the wrong `AAAA` DNS record.
- Browser health page does not open: check that the VPS firewall/provider allows ports `80` and `443`.
- You closed the final output: reconnect and run `sudo cat /root/claude-proxy-connection.txt`.

## 1. Prepare a VPS

Use a fresh Ubuntu/Debian server. The current reference server is Ubuntu with:

- `nginx`
- `certbot`
- `ufw`
- `fail2ban`
- `chrony`

You need initial SSH access as `root` or another sudo-capable user.

## 2. Create a domain

Create a DNS `A` record pointing to the VPS public IPv4 address.

Example:

```text
Type: A
Name: claudecode
Value: 203.0.113.10
TTL: Auto or 300
```

If your domain is `example.com`, this creates:

```text
claudecode.example.com
```

Wait until DNS resolves:

```bash
dig +short claudecode.example.com
```

The output must be your VPS IP. On Windows:

```powershell
Resolve-DnsName claudecode.example.com
```

If your domain has an `AAAA` record, make sure it also points to this server or remove it. Let's Encrypt and some clients may prefer IPv6 when it exists.

## 3. Run the installer from your computer

From your computer, run one command. Replace only `SERVER_IP`.

```bash
ssh -t root@SERVER_IP "curl -fsSL https://raw.githubusercontent.com/xsdementevx/claude-code-nginx-proxy/main/install.sh | bash"
```

This works from macOS, Linux, Windows PowerShell, and Windows Terminal if `ssh` is installed.

The installer asks for missing required values:

- proxy domain, for example `claude.example.com`
- Let's Encrypt email, for example `you@example.com`

Everything else is automatic:

- secret URL path is generated
- SSH port is detected
- packages are installed
- `nginx`, TLS, `ufw`, `fail2ban`, `sysctl`, and `chrony` are configured
- `admin` sudo user is created if possible
- existing SSH keys are copied from the current/root user to `admin`
- connection details are saved to `/root/claude-proxy-connection.txt`

If your VPS provider gives you a non-root sudo user instead of root:

```bash
ssh -t USER@SERVER_IP "curl -fsSL https://raw.githubusercontent.com/xsdementevx/claude-code-nginx-proxy/main/install.sh | sudo bash"
```

Manual copy mode:

```bash
scp install.sh root@SERVER_IP:/root/
ssh root@SERVER_IP
sudo bash /root/install.sh
```

## 4. Optional SSH hardening

By default, the installer does not disable root/password SSH. This avoids lockouts.

After install, test the created admin user from another terminal:

```bash
ssh admin@YOUR_DOMAIN
sudo whoami
```

Only after that works, you can rerun with:

```bash
ssh -t root@SERVER_IP "curl -fsSL https://raw.githubusercontent.com/xsdementevx/claude-code-nginx-proxy/main/install.sh | bash -s -- --harden-ssh"
```

This disables root login and password auth, and allows SSH only for `admin`.

## 5. What the server config looks like

The generated nginx site is:

```text
/etc/nginx/sites-available/claude-proxy
/etc/nginx/sites-enabled/claude-proxy
```

It serves:

```text
https://YOUR_DOMAIN/health
```

and proxies only:

```text
https://YOUR_DOMAIN/YOUR_SECRET_PATH/*
```

The root path returns `404` by design.

## 6. Use with Claude Code

After install, the server prints and saves connection details to:

```text
/root/claude-proxy-connection.txt
```

On Linux/macOS:

```bash
export ANTHROPIC_BASE_URL="https://YOUR_DOMAIN/YOUR_SECRET_PATH"
claude
```

On Windows PowerShell:

```powershell
$env:ANTHROPIC_BASE_URL = "https://YOUR_DOMAIN/YOUR_SECRET_PATH"
claude
```

If your Claude Code setup needs an OAuth token:

```bash
export ANTHROPIC_BASE_URL="https://YOUR_DOMAIN/YOUR_SECRET_PATH"
export CLAUDE_CODE_OAUTH_TOKEN="your-token"
claude
```

You can also put the env vars into `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://YOUR_DOMAIN/YOUR_SECRET_PATH",
    "CLAUDE_CODE_OAUTH_TOKEN": "your-token"
  }
}
```

## 7. Verify

Health check:

```bash
curl -i https://YOUR_DOMAIN/health
```

Expected:

```text
HTTP/2 200
OK
```

Root should not expose anything:

```bash
curl -i https://YOUR_DOMAIN/
```

Expected:

```text
HTTP/2 404
```

Claude Code status:

```bash
claude /status
```

Check that the base URL is your proxy URL.

## 8. Operations

Nginx status:

```bash
sudo systemctl status nginx
```

Reload nginx after manual config edits:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Logs:

```bash
sudo tail -f /var/log/nginx/claude-proxy-access.log
sudo tail -f /var/log/nginx/claude-proxy-error.log
```

Firewall:

```bash
sudo ufw status verbose
```

Fail2ban:

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

Certificates:

```bash
sudo certbot certificates
sudo systemctl list-timers | grep certbot
```

## 9. Rotate the secret path

Run the installer again and choose a new secret path, or edit:

```text
/etc/nginx/sites-available/claude-proxy
```

Change both occurrences of the old secret path:

```nginx
location /NEW_SECRET_PATH/ {
    rewrite ^/NEW_SECRET_PATH/(.*)$ /$1 break;
}

location = /NEW_SECRET_PATH {
    return 301 /NEW_SECRET_PATH/;
}
```

Then:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Update your local `ANTHROPIC_BASE_URL`.

## 10. Important notes

Do not publish the secret path. It is part of the access control model.

Do not store Claude/Anthropic tokens on the server. This proxy is designed to pass client headers through to Anthropic.

If Claude Code works in CLI but not in VS Code, fully close all VS Code processes and restart VS Code from a terminal that has the same environment variables.

## 11. macOS setup for Claude Code

Use this section after the server is already installed and you have the final proxy URL:

```text
https://YOUR_DOMAIN/YOUR_SECRET_PATH
```

Claude Code reads `ANTHROPIC_BASE_URL` to route API calls through a proxy or gateway. For a persistent setup, prefer `~/.claude/settings.json` because it is read at Claude Code startup no matter how the CLI was launched.

### Shared user config

Create or edit:

```bash
mkdir -p ~/.claude
nano ~/.claude/settings.json
```

Minimal proxy config:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://YOUR_DOMAIN/YOUR_SECRET_PATH",
    "API_TIMEOUT_MS": "1200000"
  }
}
```

If your setup uses a Claude Code OAuth token, add it here:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://YOUR_DOMAIN/YOUR_SECRET_PATH",
    "CLAUDE_CODE_OAUTH_TOKEN": "your-token",
    "API_TIMEOUT_MS": "1200000"
  }
}
```

Keep this file private:

```bash
chmod 700 ~/.claude
chmod 600 ~/.claude/settings.json
```

### CLI on macOS

Install Claude Code using the native installer:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Or use Homebrew:

```bash
brew install --cask claude-code
```

Homebrew installations do not auto-update, so upgrade manually:

```bash
brew upgrade claude-code
```

Start a new terminal after editing `~/.claude/settings.json`, then verify:

```bash
claude /status
```

The status output should show your custom Anthropic base URL.

For one terminal session only:

```bash
export ANTHROPIC_BASE_URL="https://YOUR_DOMAIN/YOUR_SECRET_PATH"
claude
```

To make shell exports persistent, add them to `~/.zshrc`:

```bash
echo 'export ANTHROPIC_BASE_URL="https://YOUR_DOMAIN/YOUR_SECRET_PATH"' >> ~/.zshrc
source ~/.zshrc
```

The settings file is still recommended because GUI apps and IDEs do not always inherit your interactive shell environment.

### Claude Desktop app on macOS

Install the Claude Desktop app from Anthropic and open the Code tab. The Desktop app includes Claude Code for the Code tab, so the separate CLI install is only required if you also want the `claude` command in Terminal.

For local Desktop Code sessions, configure proxy variables in one of two ways:

1. Recommended for Claude sessions: put `ANTHROPIC_BASE_URL` in `~/.claude/settings.json` as shown above.
2. Recommended when preview/dev servers also need variables: open the environment dropdown in the Desktop prompt box, hover over Local, click the gear icon, and add variables in the local environment editor.

Important macOS behavior: when Desktop is launched from Dock or Finder, it does not inherit your full shell environment. It reads shell profile files only for `PATH` and a fixed set of Claude Code variables. If a variable is not taking effect, set it in `~/.claude/settings.json` or in Desktop's local environment editor, then quit and reopen the app.

Desktop session types:

- Local: runs on the Mac and can use the local proxy config.
- SSH: runs Claude Code on a remote Linux/macOS host; configure the proxy on that remote host too.
- Cloud/Remote: runs on Anthropic-managed infrastructure; local machine env vars do not automatically apply.

### VS Code extension on macOS

Install the Claude Code extension:

1. Open VS Code.
2. Press `Cmd+Shift+X`.
3. Search for `Claude Code`.
4. Install and reload VS Code if prompted.

The extension bundles its own Claude Code binary for the graphical panel. To use `claude` in VS Code's integrated terminal, install the standalone CLI separately.

Recommended proxy setup:

1. Put `ANTHROPIC_BASE_URL` in `~/.claude/settings.json`.
2. Fully quit VS Code:

```bash
osascript -e 'quit app "Visual Studio Code"'
```

3. Start VS Code from a terminal:

```bash
cd /path/to/project
code .
```

Launching with `code .` helps VS Code inherit terminal environment variables. The settings file remains the more reliable option for shared CLI/extension configuration.

If you configure provider/proxy auth through environment variables and the extension still shows a login prompt:

- open VS Code Settings with `Cmd+,`
- search `Claude Code login`
- enable `Disable Login Prompt` for third-party/provider setups
- reload the window with `Cmd+Shift+P` -> `Developer: Reload Window`

The extension also has an `environmentVariables` setting, but use Claude Code settings files for shared configuration between CLI and extension.

### Quick macOS verification

Check the proxy itself:

```bash
curl -i https://YOUR_DOMAIN/health
curl -i https://YOUR_DOMAIN/
```

Expected:

- `/health` returns `200 OK`
- `/` returns `404`

Check Claude Code:

```bash
claude /status
```

If the CLI works but Desktop or VS Code does not:

1. Quit the app completely.
2. Confirm `~/.claude/settings.json` contains the proxy URL.
3. Reopen the app.
4. For VS Code, prefer launching with `code .` from Terminal.
5. Check that you are using the Code tab in Desktop, not a normal Chat tab.

### Official docs used for this section

- Claude Code environment variables: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and settings-file `env`.
- Claude Code setup on macOS: native installer and Homebrew.
- Claude Code Desktop: local environment editor, shared settings, and macOS environment inheritance behavior.
- VS Code extension: bundled CLI, standalone CLI requirement for integrated terminal, and extension environment settings.
