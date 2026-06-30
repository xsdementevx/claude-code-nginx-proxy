# HTTPS-прокси Claude Code без домена

Скрипт настраивает чистый Ubuntu/Debian VPS как HTTPS-прокси для Claude Code:

- домен не нужен;
- используется публичный IP сервера;
- выпускается Let's Encrypt IP certificate;
- nginx проксирует запросы на `https://api.anthropic.com`;
- токен Anthropic не хранится на сервере.

IP-сертификаты Let's Encrypt являются short-lived: они действуют примерно 6 дней. Certbot ставит автообновление, поэтому сервер должен оставаться включенным, а порты `80` и `443` должны быть открыты.

## Что нужно

```text
IP VPS       Например 203.0.113.10
SSH-доступ   root или пользователь с sudo
Email        Для Let's Encrypt
```

## Установка с компьютера

Открой PowerShell на Windows или Terminal на macOS/Linux.

Замени только `IP_ТВОЕГО_VPS`:

```bash
ssh -t root@IP_ТВОЕГО_VPS "curl -fsSL https://raw.githubusercontent.com/xsdementevx/claude-code-nginx-proxy/main/install.sh | bash"
```

Если у тебя не `root`, а обычный sudo-пользователь:

```bash
ssh -t USER@IP_ТВОЕГО_VPS "curl -fsSL https://raw.githubusercontent.com/xsdementevx/claude-code-nginx-proxy/main/install.sh | sudo bash"
```

Скрипт спросит email:

```text
Let's Encrypt email:
```

Введи свой email, например:

```text
you@example.com
```

## Готовая строка подключения

В конце установки появится строка вида:

```bash
export ANTHROPIC_BASE_URL="https://203.0.113.10/secret-path"
```

Скопируй ее и запусти Claude Code:

```bash
export ANTHROPIC_BASE_URL="https://203.0.113.10/secret-path"
claude
```

Для Windows PowerShell:

```powershell
$env:ANTHROPIC_BASE_URL = "https://203.0.113.10/secret-path"
claude
```

Если закрыл вывод установщика, подключись к серверу и выполни:

```bash
sudo cat /root/claude-proxy-connection.txt
```

## Проверка

Открой в браузере:

```text
https://IP_ТВОЕГО_VPS/health
```

Должно быть:

```text
OK
```

Корневой адрес должен отдавать `404`:

```text
https://IP_ТВОЕГО_VPS/
```

Это нормально: прокси работает только по секретному пути.

## Авторизация через нужный браузер

Если Claude Code открывает обычный браузер, а тебе нужен антидетект-профиль:

1. Открой нужный профиль браузера.
2. В терминале выполни:

```bash
claude setup-token
```

3. Скопируй ссылку авторизации из терминала.
4. Открой ее в нужном браузерном профиле.
5. Заверши вход.
6. Если появится код, вставь его обратно в терминал.
7. Claude Code покажет токен.

Запуск с токеном:

```bash
export ANTHROPIC_BASE_URL="https://203.0.113.10/secret-path"
export CLAUDE_CODE_OAUTH_TOKEN="PASTE_TOKEN_HERE"
claude
```

PowerShell:

```powershell
$env:ANTHROPIC_BASE_URL = "https://203.0.113.10/secret-path"
$env:CLAUDE_CODE_OAUTH_TOKEN = "PASTE_TOKEN_HERE"
claude
```

Токен нельзя публиковать, коммитить или отправлять другим людям.

## Что делает скрипт

- определяет публичный IPv4 сервера;
- устанавливает `nginx`, `certbot`, `ufw`, `fail2ban`, `chrony`;
- выпускает Let's Encrypt certificate на IP через профиль `shortlived`;
- создает случайный секретный URL-путь;
- настраивает HTTPS-прокси к Anthropic API;
- создает пользователя `admin`, если возможно;
- копирует SSH-ключи root/sudo-пользователя в `admin`;
- сохраняет итоговую строку в `/root/claude-proxy-connection.txt`.

Опционально, после проверки входа `ssh admin@IP_ТВОЕГО_VPS`, можно усилить SSH:

```bash
ssh -t root@IP_ТВОЕГО_VPS "curl -fsSL https://raw.githubusercontent.com/xsdementevx/claude-code-nginx-proxy/main/install.sh | bash -s -- --harden-ssh"
```

## Частые проблемы

- `ssh` не подключается: проверь IP, пароль, SSH-ключ или имя пользователя из панели VPS.
- Сертификат не выпускается: проверь, что провайдер VPS открыл входящий порт `80`.
- Проверка HTTPS не открывается: проверь, что открыты входящие порты `80` и `443`.
- Certbot ругается на `--ip-address` или `shortlived`: на сервер поставился старый Certbot; скрипт ставит Certbot через snap, но на некоторых минимальных образах VPS может потребоваться перезапустить установку после установки `snapd`.

## Локальный запуск скрипта

Если ты клонировал репозиторий:

```bash
sudo bash install.sh
```
