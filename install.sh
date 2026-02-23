#!/bin/bash

# Конфигурация
REPO_URL="https://github.com/crazy-alert/CaddyMarzban.git"  # <-- ИСПОЛЬЗУЙТЕ HTTPS URL!
INSTALL_DIR="/opt/CaddyMarzban"                         # <-- Директория для установки

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

info() {
    echo -e "${BLUE}[NOTE]${NC} $1"
}

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   error "Этот скрипт должен запускаться с правами root (используйте sudo)"
   exit 1
fi

log "Начинаем установку..."

# Обновление пакетов
log "Обновление списка пакетов..."
apt-get update

# Установка необходимых пакетов
log "Установка docker, git, curl, mc, nano..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    git \
    mc \
    nano \
    software-properties-common \
    ufw \
    logrotate  # Для ротации логов

# Настройка UFW (фаервол)
log "Настройка базового фаервола..."
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

# Создание директории для установки
log "Создание директории $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/logs"  # Директория для симлинков

# Создание директорий для логов в системе
log "Создание директорий для логов..."
mkdir -p /var/log/marzban
mkdir -p /var/log/caddy

# Настройка прав на директории логов
chmod 755 /var/log/marzban
chmod 755 /var/log/caddy

# СОЗДАНИЕ СИМЛИНКОВ
log "Создание симлинков для логов в $INSTALL_DIR/logs/..."

# Удаляем старые симлинки если они существуют
rm -f "$INSTALL_DIR/logs/marzban" 2>/dev/null
rm -f "$INSTALL_DIR/logs/caddy" 2>/dev/null

# Создаем новые симлинки
ln -s /var/log/marzban "$INSTALL_DIR/logs/marzban"
ln -s /var/log/caddy "$INSTALL_DIR/logs/caddy"

# Проверка создания симлинков
if [ -L "$INSTALL_DIR/logs/marzban" ] && [ -L "$INSTALL_DIR/logs/caddy" ]; then
    log "Симлинки успешно созданы:"
    log "  $INSTALL_DIR/logs/marzban -> /var/log/marzban"
    log "  $INSTALL_DIR/logs/caddy -> /var/log/caddy"
else
    warn "Проблема при создании симлинков"
fi

# Создаем README в директории логов с пояснением
cat > "$INSTALL_DIR/logs/README.md" << EOF
# Директория логов

Это симлинки на системные директории логов:

- `marzban` -> `/var/log/marzban` - логи Marzban
- `caddy` -> `/var/log/caddy` - логи Caddy

Реальные логи хранятся в `/var/log/` для обеспечения:
- Централизованного сбора логов
- Правильной работы logrotate
- Доступа для системных инструментов (fail2ban, auditd)

Для просмотра логов используйте:
\`\`\`bash
# Через симлинки
tail -f $INSTALL_DIR/logs/marzban/*.log
tail -f $INSTALL_DIR/logs/caddy/*.log

# Или напрямую
tail -f /var/log/marzban/*.log
tail -f /var/log/caddy/*.log
\`\`\`
EOF

# Настройка ротации логов
log "Настройка ротации логов..."
cat > /etc/logrotate.d/marzban << EOF
/var/log/marzban/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    sharedscripts
    postrotate
        [ -f /var/run/docker.pid ] && docker kill --signal=USR1 marzban 2>/dev/null || true
    endscript
}
EOF

cat > /etc/logrotate.d/caddy << EOF
/var/log/caddy/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    sharedscripts
    postrotate
        [ -f /var/run/docker.pid ] && docker kill --signal=USR1 caddy 2>/dev/null || true
    endscript
}
EOF

# Установка Docker
if ! command -v docker &> /dev/null; then
    log "Установка Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
else
    log "Docker уже установлен"
fi

# Установка Docker Compose
if ! command -v docker-compose &> /dev/null; then
    log "Установка Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
else
    log "Docker Compose уже установлен"
fi

# Настройка fail2ban
read -p "А не установить ли fail2ban для защиты от брутфорса? (y/n): " setup_fail2ban
if [[ $setup_fail2ban =~ ^[Yy]$ ]]; then
    log "Установка и настройка fail2ban..."

    # Установка fail2ban
    apt-get install -y fail2ban

    # Создание локальной конфигурации
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# Блокировка на 1 час
bantime = 3600
# Время окна проверки (10 минут)
findtime = 600
# Количество попыток (3 неудачных попытки за 10 минут)
maxretry = 3

# Игнорировать локальные сети
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16 172.16.0.0/12 10.0.0.0/8

# Действие по умолчанию - блокировка по iptables
banaction = iptables-multiport

# SSHD jail
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3

# Caddy jail
[caddy]
enabled = true
port = http,https
filter = caddy
logpath = /var/log/caddy/*.log
maxretry = 5

# Marzban jail
[marzban]
enabled = true
port = 8000
filter = marzban
logpath = /var/log/marzban/*.log
maxretry = 5
EOF

    # Создание фильтра для Caddy
    cat > /etc/fail2ban/filter.d/caddy.conf << EOF
[Definition]
failregex = ^<HOST> .* 400 .*$
            ^<HOST> .* 403 .*$
            ^<HOST> .* 404 .*$
            ^<HOST> .* 500 .*$
ignoreregex =
EOF

    # Создание фильтра для Marzban
    cat > /etc/fail2ban/filter.d/marzban.conf << EOF
[Definition]
failregex = .*Failed login attempt from <HOST>.*
            .*Invalid token from <HOST>.*
            .*Too many requests from <HOST>.*
ignoreregex =
EOF

    # Включение и запуск fail2ban
    systemctl enable fail2ban
    systemctl restart fail2ban

    log "Fail2ban успешно установлен и настроен"
else
    log "Пропускаем установку fail2ban"
fi

# Клонирование или обновление репозитория
if [ -d "$INSTALL_DIR/.git" ]; then
    log "Репозиторий уже существует, обновляем..."
    cd "$INSTALL_DIR"
    git pull
else
    log "Клонирование репозитория..."
    if git clone "$REPO_URL" "$INSTALL_DIR"; then
        log "Репозиторий успешно склонирован"
        cd "$INSTALL_DIR"
    else
        error "Не удалось клонировать репозиторий."
        error "Проверьте URL: $REPO_URL"
        exit 1
    fi
fi

# Создание базового Caddyfile если его нет
if [ ! -f "caddy/Caddyfile" ]; then
    log "Создание базового Caddyfile..."
    mkdir -p caddy
    cat > caddy/Caddyfile << EOF
# Глобальные настройки
{
    email {$CADDY_EMAIL}
    log {
        output file /var/log/caddy/access.log
        level INFO
    }
}

{$CADDY_DOMAIN} {
    # Reverse proxy к Marzban API
    handle /api/* {
        reverse_proxy marzban:8000
    }

    # Reverse proxy для прокси протоколов
    handle /vmess/* {
        reverse_proxy marzban:10000-10100
    }

    # Статические файлы
    handle {
        root * /usr/share/caddy/www
        file_server
    }

    # Логи
    log {
        output file /var/log/caddy/error.log
        level ERROR
    }
}
EOF
fi

# Проверяем наличие .env.example
if [ ! -f ".env.example" ]; then
    error "Файл .env.example не найден в репозитории!"
    exit 1
fi

# Копирование .env.example в .env если .env не существует
if [ ! -f ".env" ]; then
    log "Копирование .env.example в .env..."
    cp .env.example .env
    log "Файл .env создан"
else
    log "Файл .env уже существует"
fi

# Функция для обновления переменной в .env
update_env_var() {
    local var_name="$1"
    local var_value="$2"
    local var_comment="$3"

    if grep -q "^#\?$var_name=" ".env"; then
        sed -i "s|^#\?$var_name=.*|$var_name=$var_value|" ".env"
    else
        if [ -n "$var_comment" ]; then
            echo -e "\n#$var_comment\n$var_name=$var_value" >> ".env"
        else
            echo "$var_name=$var_value" >> ".env"
        fi
    fi
}

# Запрос данных у пользователя
log "Настройка конфигурации..."

# CADDY_DOMAIN
read -p "Введите домен для Caddy (например, example.com): " CADDY_DOMAIN
update_env_var "CADDY_DOMAIN" "$CADDY_DOMAIN" "Caddy domain"
update_env_var "XRAY_SUBSCRIPTION_URL_PREFIX" "$CADDY_DOMAIN" "Префикс адреса подписки"

# CADDY_EMAIL
read -p "Введите email для Caddy (для SSL сертификатов): " CADDY_EMAIL
update_env_var "CADDY_EMAIL" "$CADDY_EMAIL" "Caddy email"

# Telegram бот
read -p "Настроить Telegram бота для управления? (y/n): " setup_telegram
if [[ $setup_telegram =~ ^[Yy]$ ]]; then
    read -p "Введите Telegram Bot Token (получить у @BotFather): " TELEGRAM_TOKEN
    read -p "Введите ваш Telegram ID (узнать у @userinfobot): " TELEGRAM_ID

    update_env_var "TELEGRAM_API_TOKEN" "$TELEGRAM_TOKEN" "Telegram bot token"
    update_env_var "TELEGRAM_ADMIN_ID" "$TELEGRAM_ID" "Telegram admin ID"

    log "Telegram бот настроен"
fi

# Запуск docker-compose
log "Запуск docker-compose..."
docker-compose up -d

# Создание systemd сервиса для автозапуска
log "Настройка автозапуска..."
cat > /etc/systemd/system/caddy-marzban.service << EOF
[Unit]
Description=Caddy Marzban Docker Compose
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
Before=fail2ban.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
ExecReload=/usr/local/bin/docker-compose restart
StandardOutput=journal
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable caddy-marzban.service

# Финальная информация
log "Установка завершена!"

echo ""
info "=== ИНФОРМАЦИЯ О СИСТЕМЕ ==="
info "Директория установки: $INSTALL_DIR"
info "Домен: $CADDY_DOMAIN"
info "Email: $CADDY_EMAIL"
info ""
info "=== ЛОГИ (СИМЛИНКИ) ==="
info "Логи доступны по симлинкам:"
info "  $INSTALL_DIR/logs/marzban/ -> /var/log/marzban/"
info "  $INSTALL_DIR/logs/caddy/ -> /var/log/caddy/"
info ""
info "Просмотр логов через симлинки:"
info "  tail -f $INSTALL_DIR/logs/marzban/*.log"
info "  tail -f $INSTALL_DIR/logs/caddy/*.log"
info ""
info "Просмотр логов Docker:"
info "  cd $INSTALL_DIR && docker-compose logs -f"
info ""
info "=== УПРАВЛЕНИЕ ==="
info "Остановка: cd $INSTALL_DIR && docker-compose down"
info "Запуск: cd $INSTALL_DIR && docker-compose up -d"
info "Перезапуск: cd $INSTALL_DIR && docker-compose restart"

# Самоуничтожение скрипта
log "Удаляем скрипт установки..."
rm -- "install.sh"

log "Готово!"