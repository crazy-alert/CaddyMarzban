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

# Функция для проверки и преобразования URL
check_repo_url() {
    if [[ "$REPO_URL" == git@* ]]; then
        warn "Обнаружен SSH URL. Рекомендуется использовать HTTPS для простоты установки."
        read -p "Хотите преобразовать в HTTPS? (y/n): " convert_url
        if [[ $convert_url =~ ^[Yy]$ ]]; then
            # Преобразуем git@github.com:username/repo.git -> https://github.com/username/repo.git
            REPO_URL=$(echo "$REPO_URL" | sed 's/^git@\(.*\):\(.*\)/https:\/\/\1\/\2/')
            log "URL преобразован в: $REPO_URL"
        else
            warn "Продолжаем с SSH URL. Убедитесь, что SSH ключи настроены!"
        fi
    fi
}

log "Начинаем установку..."

# Проверка URL репозитория
check_repo_url

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
    ufw

# Настройка UFW (фаервол)
log "Настройка базового фаервола..."
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

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

    # Создание фильтра для Docker
    cat > /etc/fail2ban/filter.d/docker-auth.conf << EOF
[Definition]
failregex = ^.*Failed password for .* from <HOST> port .* ssh2$
            ^.*Invalid user .* from <HOST> port .*$
ignoreregex =
EOF

    # Включение и запуск fail2ban
    systemctl enable fail2ban
    systemctl restart fail2ban

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

    # Пробуем клонировать с обработкой ошибок
    if git clone "$REPO_URL" "$INSTALL_DIR"; then
        log "Репозиторий успешно склонирован"
        cd "$INSTALL_DIR"
    else
        error "Не удалось клонировать репозиторий."
        error "Проверьте URL: $REPO_URL"
        error ""
        error "Возможные решения:"
        error "1. Используйте HTTPS URL (https://github.com/username/repo.git)"
        error "2. Если используете SSH, настройте ключи: ssh-keygen -t ed25519 -C \"your_email@example.com\""
        error "3. Для публичных репозиториев можно использовать: git clone https://github.com/username/repo.git"
        exit 1
    fi
fi

# Проверяем наличие .env.example
if [ ! -f ".env.example" ]; then
    error "Файл .env.example не найден в репозитории!"
    ls -la
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

# Запрос данных у пользователя
log "Настройка конфигурации..."

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

# Проверка наличия docker-compose.yml
if [ ! -f "docker-compose.yml" ]; then
    error "Файл docker-compose.yml не найден в репозитории!"
    ls -la
    exit 1
fi

# Запуск docker-compose
log "Запуск docker-compose..."
docker-compose up -d

# Проверка успешности запуска
if [ $? -eq 0 ]; then
    log "Docker Compose успешно запущен"
else
    error "Ошибка при запуске Docker Compose"
    exit 1
fi

# Добавление в автозапуск
log "Настройка автозапуска..."

# Создание systemd сервиса для автозапуска
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

echo ""
info "=== УПРАВЛЕНИЕ ПРИЛОЖЕНИЕМ ==="
info "Просмотр логов: cd $INSTALL_DIR && docker-compose logs -f"
info "Остановка: cd $INSTALL_DIR && docker-compose down"
info "Запуск: cd $INSTALL_DIR && docker-compose up -d"
info "Перезапуск: cd $INSTALL_DIR && docker-compose restart"

echo ""
info "=== ССЫЛКИ ==="
info "Сайт: https://$CADDY_DOMAIN"

# Самоуничтожение скрипта
log "Удаляем скрипт установки..."
rm -- "$0"

log "Готово!"