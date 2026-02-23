#!/bin/bash

# Конфигурация
REPO_URL="https://github.com/crazy-alert/CaddyMarzban.git"
INSTALL_DIR="/opt/CaddyMarzban"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Функция для цветного вывода
colorized_echo() {
    local color=$1
    local text=$2

    case $color in
        "red")     echo -e "\e[91m${text}\e[0m" ;;
        "green")   echo -e "\e[92m${text}\e[0m" ;;
        "yellow")  echo -e "\e[93m${text}\e[0m" ;;
        "blue")    echo -e "\e[94m${text}\e[0m" ;;
        "magenta") echo -e "\e[95m${text}\e[0m" ;;
        "cyan")    echo -e "\e[96m${text}\e[0m" ;;
        *)         echo "${text}" ;;
    esac
}

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
log "Установка необходимых пакетов..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    git \
    mc \
    nano \
    software-properties-common \
    ufw \
    logrotate

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

# Настройка UFW
log "Настройка фаервола..."
# Изменяем политику форвардинга для Docker
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

# Открываем порты
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 1080/tcp comment 'Shadowsocks'
ufw allow 1080/udp comment 'Shadowsocks UDP'
ufw allow 8443/tcp comment 'Trojan'
ufw allow 2096/tcp comment 'Alternative'
ufw allow 10000:10100/tcp comment 'VMess/VLESS range'
ufw allow 10000:10100/udp comment 'VMess/VLESS range UDP'

# Включаем UFW
ufw --force enable

# Создание директории установки
log "Создание директории $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Клонирование репозитория
if [ -d "$INSTALL_DIR/.git" ]; then
    log "Репозиторий уже существует, обновляем..."
    if ! git diff --quiet; then
        warn "Обнаружены локальные изменения. Они будут сохранены."
        git stash push -m "auto-stash before update" > /dev/null
    fi

    if git pull; then
        log "Репозиторий успешно обновлён"
    else
        error "Ошибка при обновлении репозитория"
        exit 1
    fi
else
    log "Клонирование репозитория..."
    if git clone "$REPO_URL" "$INSTALL_DIR"; then
        log "Репозиторий успешно склонирован"
    else
        error "Не удалось клонировать репозиторий"
        exit 1
    fi
fi

# Создание .env файла
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        log "Создание .env файла из примера..."
        cp .env.example .env
    else
        log "Создание нового .env файла..."
        touch .env
    fi
fi

# Функция обновления переменных в .env
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
update_env_var "XRAY_SUBSCRIPTION_URL_PREFIX" "https://$CADDY_DOMAIN" "Префикс адреса подписки"

# CADDY_EMAIL
read -p "Введите email для Caddy (для SSL сертификатов): " CADDY_EMAIL
update_env_var "CADDY_EMAIL" "$CADDY_EMAIL" "Caddy email"



if ! grep -q "^MYSQL_PASSWORD=" ".env"; then
    # Генерация паролей и запись в .env

    MYSQL_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    MYSQL_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

    update_env_var "MYSQL_ROOT_PASSWORD" "$MYSQL_ROOT_PASSWORD" "MySQL root password"
    update_env_var "MYSQL_DATABASE" "marzban" "MySQL database name"
    update_env_var "MYSQL_USER" "marzban" "MySQL username"
    update_env_var "MYSQL_PASSWORD" "$MYSQL_PASSWORD" "MySQL user password"
    # Формируем строку подключения
    SQLALCHEMY_URL="mysql+pymysql://marzban:${MYSQL_PASSWORD}@127.0.0.1:3306/marzban"
    update_env_var "SQLALCHEMY_DATABASE_URL" "$SQLALCHEMY_URL" "SQLAlchemy Database URL"
    log "Сгенерирован новый пароль MySQL"
else
    log "Используем существующий пароль MySQL"
fi

# Telegram бот
read -p "Настроить Telegram бота для управления? (y/n): " setup_telegram
if [[ $setup_telegram =~ ^[Yy]$ ]]; then
    read -p "Введите Telegram Bot Token (получить у @BotFather): " TELEGRAM_TOKEN
    read -p "Введите ваш Telegram ID (узнать у @userinfobot): " TELEGRAM_ID

    update_env_var "TELEGRAM_API_TOKEN" "$TELEGRAM_TOKEN" "Telegram bot token"
    update_env_var "TELEGRAM_ADMIN_ID" "$TELEGRAM_ID" "Telegram admin ID"

    log "Telegram бот настроен"
fi

# Создание структуры для данных
log "Создание структуры директорий..."
mkdir -p /var/lib/marzban/mysql
mkdir -p /var/log/marzban
mkdir -p /var/log/caddy
mkdir -p marzban/code

# Права на директории
chmod 755 /var/log/marzban /var/log/caddy
chown -R 1000:1000 /var/lib/marzban 2>/dev/null || chmod 777 /var/lib/marzban

# Настройка logrotate
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

# Запуск docker-compose
log "Запуск контейнеров..."
docker-compose up -d

# Ожидание готовности MySQL
log "Ожидание готовности MySQL..."
sleep 2
until docker exec mysql mysqladmin ping -h localhost --silent; do
    echo "Ожидание MySQL..."
    sleep 2
done


# Создание systemd сервиса
log "Настройка автозапуска..."
cat > /etc/systemd/system/caddy-marzban.service << EOF
[Unit]
Description=Caddy Marzban Docker Compose
Requires=docker.service
After=docker.service network-online.target

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


# Проверка запущенных контейнеров
log "Проверка статуса контейнеров..."
sleep 5
if [ $(docker-compose ps -q | wc -l) -eq 3 ]; then
    log "Все контейнеры успешно запущены"
else
    warn "Не все контейнеры запущены. Проверьте логи: docker-compose logs"
fi



# Финальная информация
log "Установка завершена!"

echo ""
info "=== ИНФОРМАЦИЯ О СИСТЕМЕ ==="
info "Директория установки: $INSTALL_DIR"
info "Домен: $CADDY_DOMAIN"
info "Email: $CADDY_EMAIL"
info ""
info "MySQL настроен с:"
info "  Пользователь: marzban"
info "  База данных: marzban"
info "  Пароль: $MYSQL_PASSWORD"
info ""
info "Просмотр логов:"
info "  cd $INSTALL_DIR && docker-compose logs -f"
info ""
info "Управление:"
info "  Остановка: cd $INSTALL_DIR && docker-compose down"
info "  Запуск: cd $INSTALL_DIR && docker-compose up -d"
info "  Перезапуск: cd $INSTALL_DIR && docker-compose restart"

# Самоуничтожение
log "Удаляем скрипт установки..."
rm -- "$0"

log "Готово!"