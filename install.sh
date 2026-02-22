#!/bin/bash
set -e
# Конфигурация
INSTALL_DIR="/opt/CaddyMarzban"
REPO_URL="git@github.com:crazy-alert/CaddyMarzban.git" #


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
    software-properties-common

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

# Docker контейнеры (если есть логи)
[docker-auth]
enabled = true
filter = docker-auth
logpath = /var/lib/docker/containers/*/*-json.log
EOF

    # Создание фильтра для Docker (опционально)
    cat > /etc/fail2ban/filter.d/docker-auth.conf << EOF
[Definition]
failregex = ^.*Failed password for .* from <HOST> port .* ssh2$
            ^.*Invalid user .* from <HOST> port .*$
ignoreregex =
EOF

    # Настройка автоматических обновлений для fail2ban (опционально)
    cat > /etc/cron.daily/fail2ban-update << 'EOF'
#!/bin/bash
# Ежедневное обновление списков блокировки
fail2ban-client unban --all > /dev/null 2>&1
systemctl reload fail2ban
EOF
    chmod +x /etc/cron.daily/fail2ban-update

    # Включение и запуск fail2ban
    systemctl enable fail2ban
    systemctl restart fail2ban

    # Настройка уведомлений по email (опционально)
    read -p "Настроить email уведомления о блокировках? (y/n): " setup_email
    if [[ $setup_email =~ ^[Yy]$ ]]; then
        read -p "Введите email для уведомлений: " admin_email

        # Установка mailutils для отправки писем
        apt-get install -y mailutils

        # Добавление email в конфигурацию fail2ban
        sed -i "s/^# destemail = .*/destemail = $admin_email/" /etc/fail2ban/jail.local
        sed -i "s/^# action = .*/action = %(action_mwl)s/" /etc/fail2ban/jail.local

        systemctl restart fail2ban
        log "Email уведомления настроены на $admin_email"
    fi

    # Информация о статусе
    info "Fail2ban установлен и запущен. Статус можно проверить командой: fail2ban-client status"
    info "Заблокированные IP: fail2ban-client status sshd"

    log "Fail2ban успешно установлен и настроен"
else
    log "Пропускаем установку fail2ban"
fi

# Создание директории для установки
log "Создание директории $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Клонирование или обновление репозитория
if [ -d "$INSTALL_DIR/.git" ]; then
    log "Репозиторий уже существует, обновляем..."
    cd "$INSTALL_DIR"
    git pull
else
    log "Клонирование репозитория..."
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# Копирование .env.example в .env если .env не существует
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        log "Копирование .env.example в .env..."
        cp .env.example .env
    else
        error "Файл .env.example не найден в репозитории"
        exit 1
    fi
else
    log "Файл .env уже существует"
fi

# Запрос данных у пользователя
log "Настройка конфигурации..."

# Функция для обновления переменной в .env
update_env_var() {
    local var_name="$1"
    local var_value="$2"
    local var_comment="$3"

    if grep -q "^#\?$var_name=" ".env"; then
        # Переменная существует (закомментирована или нет)
        sed -i "s|^#\?$var_name=.*|$var_name=$var_value|" ".env"
    else
        # Переменная не существует, добавляем
        if [ -n "$var_comment" ]; then
            echo -e "\n#$var_comment\n$var_name=$var_value" >> ".env"
        else
            echo "$var_name=$var_value" >> ".env"
        fi
    fi
}

# CADDY_DOMAIN
read -p "Введите домен для Caddy (например, example.com): " CADDY_DOMAIN
update_env_var "CADDY_DOMAIN" "$CADDY_DOMAIN" "Caddy domain"

# CADDY_EMAIL
read -p "Введите email для Caddy (для SSL сертификатов): " CADDY_EMAIL
update_env_var "CADDY_EMAIL" "$CADDY_EMAIL" "Caddy email"

# Telegram бот
read -p "Настроить Telegram бота для управления? (y/n): " setup_telegram
if [[ $setup_telegram =~ ^[Yy]$ ]]; then
    read -p "Введите Telegram Bot Token (получить у @BotFather): " TELEGRAM_TOKEN
    read -p "Введите ваш Telegram ID (узнать у @userinfobot): " TELEGRAM_ID

    update_env_var "TELEGRAM_API_TOKEN" "$TELEGRAM_TOKEN" "Telegram bot token (get from @BotFather)"
    update_env_var "TELEGRAM_ADMIN_ID" "$TELEGRAM_ID" "Telegram admin ID (get from @userinfobot)"

    log "Telegram бот настроен"
else
    log "Telegram бот не будет настроен"
fi

# Запуск docker-compose
log "Запуск docker-compose..."
if [ -f "docker-compose.yml" ]; then
    docker-compose up -d

    # Добавление в автозапуск
    log "Настройка автозапуска..."

    # Создание systemd сервиса для автозапуска
    cat > /etc/systemd/system/myapp-docker.service << EOF
[Unit]
Description=MyApp Docker Compose
Requires=docker.service
After=docker.service
Wants=fail2ban.service
After=fail2ban.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable myapp-docker.service

    log "Docker Compose запущен и добавлен в автозагрузку"
else
    error "Файл docker-compose.yml не найден в репозитории"
    exit 1
fi

# Финальная информация
log "Установка завершена!"

# Вывод информации о fail2ban если установлен
if [[ $setup_fail2ban =~ ^[Yy]$ ]]; then
    echo ""
    info "=== FAIL2BAN ИНФОРМАЦИЯ ==="
    info "Проверка статуса: fail2ban-client status"
    info "Просмотр заблокированных IP: fail2ban-client status sshd"
    info "Разблокировать IP: fail2ban-client set sshd unbanip <IP>"
    info "Логи fail2ban: tail -f /var/log/fail2ban.log"
    echo ""
fi

info "=== ПРИЛОЖЕНИЕ ==="
info "Приложение доступно по адресу: http://$CADDY_DOMAIN"
info "Для просмотра логов: cd $INSTALL_DIR && docker-compose logs -f"
info "Для остановки: cd $INSTALL_DIR && docker-compose down"
info "Для перезапуска: cd $INSTALL_DIR && docker-compose restart"

# Самоуничтожение скрипта
log "Удаляем скрипт установки..."
rm -- "$0"

log "Готово!"