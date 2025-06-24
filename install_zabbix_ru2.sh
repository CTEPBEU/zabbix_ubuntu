#!/usr/bin/env bash
set -euo pipefail

# Проверка: выполнение от root
if [[ $EUID -ne 0 ]]; then
  echo "Запускайте скрипт от root или через sudo."
  exit 1
fi

# Переменные
DB_USER="zabbix"
DB_NAME="zabbix"
DB_PASS="$(openssl rand -hex 16)"
TZ="$(grep -E '^[A-Za-z]' /etc/timezone || echo 'UTC')"
IP="$(hostname -I | awk '{print $1}')"
PG_CONF_DIR="/etc/postgresql/17/main"
PHP_INI="/etc/php/8.3/fpm/php.ini"
WEB_CONF_DIR="/etc/zabbix/web"

echo "### 1) Обновляем систему и устанавливаем зависимости"
apt update
apt install -y wget gnupg2 lsb-release curl

echo "### 2) Добавляем репозиторий PostgreSQL 17"
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -sc)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

echo "### 3) Добавляем репозиторий Zabbix 7.2"
wget -q https://repo.zabbix.com/zabbix/7.2/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.2+ubuntu24.04_all.deb
dpkg -i zabbix-release_latest_7.2+ubuntu24.04_all.deb || true

echo "### 4) Обновляем индексы пакетов"
apt update

echo "### 5) Устанавливаем PostgreSQL, Zabbix, Nginx и PHP"
apt install -y \
    postgresql-17 postgresql-client-17 \
    zabbix-server-pgsql zabbix-sql-scripts zabbix-frontend-php \
    zabbix-agent2 zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql \
    nginx php8.3-fpm php8.3-pgsql php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-gd

echo "### 6) Настраиваем PostgreSQL"
sed -i "s/^#listen_addresses =.*/listen_addresses = 'localhost'/" "$PG_CONF_DIR/postgresql.conf"
echo "host    $DB_NAME    $DB_USER    127.0.0.1/32    md5" >> "$PG_CONF_DIR/pg_hba.conf"
systemctl restart postgresql

echo "### 7) Создаём пользователя и базу Zabbix"
sudo -u postgres psql <<EOF
CREATE USER $DB_USER WITH ENCRYPTED PASSWORD '$DB_PASS';
CREATE DATABASE $DB_NAME OWNER $DB_USER;
EOF

echo "### 8) Импортируем схему Zabbix"
SQL_GZ=$(find /usr/share -type f -iname server.sql.gz | grep -i postgresql | head -n1 || true)
if [[ -z "$SQL_GZ" ]]; then
  echo "ERROR: Файл server.sql.gz не найден"
  exit 1
fi
zcat "$SQL_GZ" | sudo -u postgres psql "$DB_NAME"

echo "### 8.1) Настраиваем права в базе"
sudo -u postgres psql "$DB_NAME" <<EOF
ALTER SCHEMA public OWNER TO $DB_USER;
GRANT ALL ON SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;
EOF

echo "### 9) Конфигурируем Zabbix Server"
ZBX_SERVER_CONF="/etc/zabbix/zabbix_server.conf"
sed -i "s/^# DBName=.*/DBName=$DB_NAME/" "$ZBX_SERVER_CONF"
sed -i "s/^# DBUser=.*/DBUser=$DB_USER/" "$ZBX_SERVER_CONF"
sed -i "s/^# DBPassword=.*/DBPassword=$DB_PASS/" "$ZBX_SERVER_CONF"
if ! grep -q '^DBHost=' "$ZBX_SERVER_CONF"; then
  echo "DBHost=127.0.0.1" >> "$ZBX_SERVER_CONF"
fi

echo "### 10) Настраиваем PHP-FPM и параметры"
sed -i "s~;date.timezone =.*~date.timezone = $TZ~" "$PHP_INI"
sed -i "s~memory_limit =.*~memory_limit = 512M~" "$PHP_INI"
sed -i "s~post_max_size =.*~post_max_size = 128M~" "$PHP_INI"
sed -i "s~upload_max_filesize =.*~upload_max_filesize = 512M~" "$PHP_INI"
sed -i "s~max_execution_time =.*~max_execution_time = 300~" "$PHP_INI"
sed -i "s~max_input_time =.*~max_input_time = 600~" "$PHP_INI"
systemctl restart php8.3-fpm

echo "### 11) Готовим /run/zabbix"
mkdir -p /run/zabbix
chown zabbix:zabbix /run/zabbix

echo "### 12) Права на фронтенд"
chown -R root:www-data /usr/share/zabbix
find /usr/share/zabbix -type d -exec chmod 755 {} \;
find /usr/share/zabbix -type f -exec chmod 644 {} \;

echo "### 13) Конфигурируем Nginx"
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
cat > /etc/nginx/conf.d/zabbix.conf <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /usr/share/zabbix/ui;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    location ~* \.(?:css|js|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires max;
        log_not_found off;
    }

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff"      always;
}
EOF
nginx -t && systemctl reload nginx

echo "### 14) Перезапускаем и включаем сервисы"
for svc in postgresql zabbix-server zabbix-agent2 nginx; do
  systemctl restart "$svc"
  systemctl enable "$svc"
done

echo "### 15) Устанавливаем русскую локаль ОС"
apt install -y locales
sed -i "s/^# *ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/" /etc/locale.gen
locale-gen
update-locale LANG=ru_RU.UTF-8

echo "### 16) Генерируем Zabbix UI конфиг"
mkdir -p "$WEB_CONF_DIR"
cat > "$WEB_CONF_DIR/zabbix.conf.php" <<EOF
<?php
// Zabbix GUI configuration file.
global \$DB;

\$DB['TYPE']     = 'POSTGRESQL';
\$DB['SERVER']   = '127.0.0.1';
\$DB['PORT']     = '5432';
\$DB['DATABASE'] = '$DB_NAME';
\$DB['USER']     = '$DB_USER';
\$DB['PASSWORD'] = '$DB_PASS';

\$ZBX_SERVER      = '127.0.0.1';
\$ZBX_SERVER_PORT = '10051';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;

// Set default UI language
\$ZBX_DEFAULT_LANGUAGE = 'ru_RU';
EOF
chown root:www-data "$WEB_CONF_DIR/zabbix.conf.php"
chmod 640 "$WEB_CONF_DIR/zabbix.conf.php"
systemctl restart php8.3-fpm nginx

echo
cat <<EOF

=========================================
Zabbix 7.2 успешно установлен и локализован!

Database user:     $DB_USER
Database name:     $DB_NAME
Database password: $DB_PASS
UI URL:            http://$IP/

Default login:     Admin
Default password:  zabbix
Default UI language: Russian (ru_RU)
=========================================
EOF
