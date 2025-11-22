#!/bin/bash
set -e

# Функция ожидания MySQL
wait_for_db() {
    echo ">>> Ожидание готовности MariaDB..."
    for i in {1..30}; do
        if mysqladmin ping -u root --silent; then
            echo ">>> MariaDB готова!"
            return 0
        fi
        sleep 1
    done
    echo ">>> ОШИБКА: MariaDB не запустилась за 30 секунд"
    exit 1
}

# --- FIX: Machine ID (КРИТИЧЕСКИ ВАЖНО) ---
# Проверяем, существует ли файл И имеет ли он размер > 0.
# Пустой файл machine-id вызывает сбои dbus/pulseaudio.
if [ ! -s /etc/machine-id ]; then
    echo ">>> Generating /etc/machine-id..."
    if command -v dbus-uuidgen >/dev/null 2>&1; then
        dbus-uuidgen --ensure=/etc/machine-id
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen > /etc/machine-id
    else
        cat /proc/sys/kernel/random/uuid > /etc/machine-id
    fi
fi

echo "=== FreePBX + Asterisk container start ==="

# ----- 1. Подготовка директорий -----
mkdir -p /var/run/asterisk /var/log/asterisk /var/spool/asterisk /var/lib/asterisk /var/www/html /var/lib/mysql

# Исправляем права на критические папки
chown asterisk:asterisk /var/run/asterisk /etc/asterisk /var/www/html

# --- ВОССТАНОВЛЕНИЕ ДОКУМЕНТАЦИИ (КРИТИЧНО) ---
# Проверяем наличие XML. Если их нет (пустой том или глюк) - копируем из бэкапа
if [ ! -f /var/lib/asterisk/documentation/core-en_US.xml ]; then
    echo ">>> WARNING: XML документация не найдена. Восстанавливаем..."
    mkdir -p /var/lib/asterisk/documentation
    if [ -d "/usr/share/asterisk/documentation_backup" ]; then
        cp -f /usr/share/asterisk/documentation_backup/* /var/lib/asterisk/documentation/
        chown -R asterisk:asterisk /var/lib/asterisk/documentation
        echo ">>> Документация восстановлена."
    else
        echo ">>> FATAL: Бэкап документации отсутствует!"
    fi
fi

# ----- 2. Базовые конфиги (если пусто) -----
if [ -z "$(ls -A /etc/asterisk)" ]; then
    echo ">>> /etc/asterisk пуст — генерируем базовые конфиги"
    echo "[directories]" > /etc/asterisk/asterisk.conf
    echo "astetcdir => /etc/asterisk" >> /etc/asterisk/asterisk.conf
    echo "astmoddir => /usr/lib/asterisk/modules" >> /etc/asterisk/asterisk.conf
    echo "astvarlibdir => /var/lib/asterisk" >> /etc/asterisk/asterisk.conf
    echo "astagidir => /var/lib/asterisk/agi-bin" >> /etc/asterisk/asterisk.conf
    echo "astspooldir => /var/spool/asterisk" >> /etc/asterisk/asterisk.conf
    echo "astrundir => /var/run/asterisk" >> /etc/asterisk/asterisk.conf
    echo "astlogdir => /var/log/asterisk" >> /etc/asterisk/asterisk.conf
    chown -R asterisk:asterisk /etc/asterisk
fi

if [ ! -f /etc/asterisk/fax.conf ]; then
    echo -e "[general]\nforce_detection=no" > /etc/asterisk/fax.conf
    chown asterisk:asterisk /etc/asterisk/fax.conf
fi

# ----- 3. MariaDB -----
echo "=== MariaDB init ==="
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo ">>> Инициализация MariaDB Data Directory"
    mysql_install_db --user=mysql --datadir=/var/lib/mysql > /dev/null
fi

mkdir -p /var/run/mysqld
chown -R mysql:mysql /var/run/mysqld /var/lib/mysql

mysqld_safe --user=mysql --datadir=/var/lib/mysql &
wait_for_db

mysql <<EOF
CREATE DATABASE IF NOT EXISTS asterisk CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS asteriskcdrdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'asteriskuser'@'localhost' IDENTIFIED BY 'asteriskpass';
GRANT ALL PRIVILEGES ON asterisk.* TO 'asteriskuser'@'localhost';
GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asteriskuser'@'localhost';
FLUSH PRIVILEGES;
EOF

# ----- 4. ODBC (Связь Asterisk <-> MySQL) -----
echo "=== Configuring ODBC ==="
cat > /etc/odbc.ini <<EOF
[MySQL-asteriskcdrdb]
Description=MySQL connection to 'asteriskcdrdb' database
Driver=MariaDB
Server=localhost
User=asteriskuser
Password=asteriskpass
Database=asteriskcdrdb
Port=3306
Socket=/var/run/mysqld/mysqld.sock
Option=3
EOF

# ----- 5. Cron & Services -----
service cron start || true
rm -f /var/run/asterisk/*.ctl /var/run/asterisk/*.pid /var/run/apache2/apache2.pid || true

# ----- 6. Установка / Запуск FreePBX -----

if [ ! -f /var/www/html/admin/config.php ]; then
    echo "=== FreePBX не установлен. Начинаем установку... ==="
    
    # 1. ЗАПУСКАЕМ ВРЕМЕННЫЙ ASTERISK
    echo ">>> Запуск временного Asterisk для инсталляции..."
    /usr/sbin/asterisk -U asterisk -G asterisk -f &
    AST_PID=$!
    sleep 5 

    # 2. Установка
    chown -R asterisk:asterisk /var/www/html
    cd /usr/src/freepbx
    ./install -n \
      --dbengine=mysql \
      --dbname=asterisk \
      --dbuser=asteriskuser \
      --dbpass=asteriskpass \
      --webroot=/var/www/html \
      --asterisk-user=asterisk \
      --dev-links \
      --force

    # 3. УБИВАЕМ ВРЕМЕННЫЙ ASTERISK
    echo ">>> Остановка временного Asterisk..."
    kill $AST_PID || true
    wait $AST_PID || true
    
    # 4. Пост-настройка
    echo ">>> Настройка прав и окружения..."
    fwconsole chown
    fwconsole setting START_ASTERISK_COMMAND "/usr/sbin/asterisk"
    fwconsole ma installall || true
    fwconsole reload
else
    echo "=== FreePBX найден. Запуск служб... ==="
    
    # Фикс сессий PHP
    mkdir -p /var/lib/php/sessions
    chmod 1733 /var/lib/php/sessions
    chown root:root /var/lib/php/sessions 

    echo ">>> Запуск Asterisk через fwconsole..."
    fwconsole start
fi

# ----- 7. Apache держит контейнер -----
echo "=== Starting Apache (Foreground) ==="
exec /usr/sbin/apache2ctl -D FOREGROUND