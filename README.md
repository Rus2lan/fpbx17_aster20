FreePBX 17 + Asterisk 20 (Debian 12 Bookworm)

Docker-контейнер для FreePBX 17 на базе Debian 12 с Asterisk 20.
Сборка типа "Fat Container" (Apache + MariaDB + Asterisk в одном контейнере) для максимальной стабильности и совместимости с FreePBX.

Особенности сборки

OS: Debian 12 Slim

Asterisk: 20 (Current) с поддержкой MP3 и PJSIP

FreePBX: 17

Database: MariaDB (встроена)

ODBC: Преднастроен для работы CDR

Network: Режим host (нет проблем с NAT/RTP)

Структура проекта

Dockerfile - сборка образа.

start.sh - скрипт инициализации. Умеет:

Генерировать machine-id (важно для D-Bus).

Восстанавливать XML документацию Asterisk (важно для CLI).

Устанавливать FreePBX при первом запуске.

Запускать Asterisk через fwconsole.

docker-compose.yml - запуск.

Установка и запуск

Склонируйте репозиторий.

Сделайте скрипт исполняемым (на всякий случай):

chmod +x start.sh


Запустите контейнер:

docker-compose up -d


Важно: Первый запуск займет 5-10 минут, так как скрипт будет устанавливать FreePBX с нуля, создавать базу данных и генерировать ключи.

Следите за логами установки:

docker-compose logs -f


После завершения установки зайдите в браузер:

http://IP-ВАШЕГО-СЕРВЕРА

Хранение данных (Volumes)

Все данные сохраняются в локальную папку ./data, которая создается автоматически при первом запуске. Эта папка добавлена в .gitignore.

./data/etc — Конфиги Asterisk (sip_nat.conf и т.д.)

./data/mysql — База данных

./data/www — Веб-интерфейс

./data/spool — Записи разговоров, факсы