FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV ASTERISK_VERSION=20-current

# 1. Установка пакетов + ODBC драйверы для MariaDB
# Добавлен: dbus, uuid-runtime (для генерации machine-id)
RUN set -xe && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates wget curl nano git subversion iproute2 dnsutils net-tools procps \
        apache2 mariadb-server mariadb-client \
        unixodbc unixodbc-dev odbc-mariadb \
        php php-cli php-mysql php-curl php-xml php-mbstring php-zip php-soap \
        php-gd php-bcmath php-json php-intl php-pdo php-mysqli php-pear \
        build-essential uuid-dev \
        libxml2-dev libsqlite3-dev libjansson-dev libxml2-utils \
        libcurl4-openssl-dev libssl-dev \
        libedit-dev libncurses5-dev libncursesw5-dev libnewt-dev \
        libsrtp2-dev libopus-dev pkg-config \
        libogg-dev libvorbis-dev \
        libspeex-dev libspeexdsp-dev \
        libsndfile1-dev \
        libavcodec-dev libavformat-dev libswscale-dev \
        libpam0g-dev liblzma-dev \
        doxygen graphviz \
        xmlstarlet xsltproc libxslt1-dev docbook-xsl docbook-xml \
        sox lame ffmpeg ghostscript libtiff-tools \
        unzip sudo cron \
        nodejs npm \
        gnupg \
        logrotate less tzdata \
        dbus uuid-runtime \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    # Генерация machine-id на этапе сборки для корректной работы пакетов
    && dbus-uuidgen --ensure=/etc/machine-id

# 2. Настройка пользователя Asterisk
RUN useradd -m -d /var/lib/asterisk -s /bin/bash asterisk && \
    usermod -a -G audio,daemon,www-data asterisk && \
    usermod -a -G asterisk www-data

# 3. Apache и PHP настройки
RUN sed -i 's/^\(export APACHE_RUN_USER=\).*/\1asterisk/' /etc/apache2/envvars && \
    sed -i 's/^\(export APACHE_RUN_GROUP=\).*/\1asterisk/' /etc/apache2/envvars && \
    sed -i "s/AllowOverride None/AllowOverride All/g" /etc/apache2/apache2.conf && \
    echo "ServerName localhost" >> /etc/apache2/apache2.conf && \
    sed -i 's/memory_limit = .*/memory_limit = 512M/' /etc/php/*/apache2/php.ini && \
    sed -i 's/upload_max_filesize = .*/upload_max_filesize = 120M/' /etc/php/*/apache2/php.ini && \
    sed -i 's/max_execution_time = .*/max_execution_time = 360/' /etc/php/*/apache2/php.ini && \
    sed -i 's/;date.timezone =/date.timezone = UTC/' /etc/php/*/apache2/php.ini && \
    a2enmod rewrite ssl headers

RUN echo "asterisk ALL=(asterisk) NOPASSWD: /usr/bin/crontab" > /etc/sudoers.d/asterisk-cron

# 4. Сборка Asterisk
WORKDIR /usr/src
RUN wget --no-check-certificate -O asterisk-${ASTERISK_VERSION}.tar.gz \
        https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}.tar.gz && \
    tar xvf asterisk-${ASTERISK_VERSION}.tar.gz && \
    rm asterisk-${ASTERISK_VERSION}.tar.gz

RUN cd asterisk-20.* && \
    contrib/scripts/get_mp3_source.sh && \
    ./configure --libdir=/usr/lib --with-pjproject-bundled --with-jansson-bundled && \
    make menuselect/menuselect && \
    menuselect/menuselect --enable format_mp3 --enable res_config_mysql --enable app_macro \
                          --enable CORE-SOUNDS-EN-WAV --enable CORE-SOUNDS-EN-ULAW \
                          --enable MOH-OPSOUND-WAV --enable MOH-OPSOUND-ULAW \
                          --enable EXTRA-SOUNDS-EN-WAV --enable EXTRA-SOUNDS-EN-ULAW \
                          menuselect.makeopts && \
    make -j"$(nproc)" && \
    make install && \
    make config && \
    ldconfig && \
    # --- FIX XML DOCS (КРИТИЧЕСКИ ВАЖНО) ---
    # Принудительно создаем папку и копируем файлы, так как make install часто лажает с путями в Debian
    echo ">>> FORCE COPYING XML DOCUMENTATION" && \
    mkdir -p /var/lib/asterisk/documentation && \
    mkdir -p /var/lib/asterisk/static-http && \
    cp doc/core-en_US.xml /var/lib/asterisk/documentation/ && \
    cp doc/appdocsxml.xslt /var/lib/asterisk/documentation/ && \
    cp doc/core-en_US.xml /var/lib/asterisk/static-http/ && \
    cp doc/appdocsxml.xslt /var/lib/asterisk/static-http/ && \
    # Делаем бэкап для start.sh на случай монтирования томов
    mkdir -p /usr/share/asterisk/documentation_backup && \
    cp doc/core-en_US.xml /usr/share/asterisk/documentation_backup/ && \
    cp doc/appdocsxml.xslt /usr/share/asterisk/documentation_backup/ && \
    # Права
    chown -R asterisk:asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk

# 5. Подготовка FreePBX
WORKDIR /usr/src
RUN wget --no-check-certificate https://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz && \
    tar xvf freepbx-17.0-latest.tgz && \
    rm freepbx-17.0-latest.tgz && \
    sed -i 's/ulimit -s 240/## ulimit -s 240/' /usr/src/freepbx/start_asterisk && \
    sed -i 's/if($fax_settings\[[^]]*force_detection[^]]*\] == '\''yes'\'')/if(isset($fax_settings["force_detection"]) \&\& $fax_settings["force_detection"] == "yes")/' \
       /usr/src/freepbx/amp_conf/htdocs/admin/modules/fax/functions.inc.php || true

# 6. SSL Dummy Certificate
RUN mkdir -p /etc/apache2/ssl && \
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout /etc/apache2/ssl/freepbx.key \
        -out /etc/apache2/ssl/freepbx.crt \
        -days 3650 \
        -subj "/CN=freepbx-docker"

# Настройка VirtualHost
RUN { \
    echo '<VirtualHost *:80>'; \
    echo '    DocumentRoot /var/www/html'; \
    echo '    <Directory "/var/www/html">'; \
    echo '        AllowOverride All'; \
    echo '        Require all granted'; \
    echo '    </Directory>'; \
    echo '</VirtualHost>'; \
    echo '<VirtualHost *:443>'; \
    echo '    SSLEngine on'; \
    echo '    SSLCertificateFile /etc/apache2/ssl/freepbx.crt'; \
    echo '    SSLCertificateKeyFile /etc/apache2/ssl/freepbx.key'; \
    echo '    DocumentRoot /var/www/html'; \
    echo '    <Directory "/var/www/html">'; \
    echo '        AllowOverride All'; \
    echo '        Require all granted'; \
    echo '    </Directory>'; \
    echo '</VirtualHost>'; \
    } > /etc/apache2/sites-available/000-default.conf

# 7. Настройка ODBC
RUN echo "[MariaDB]" > /etc/odbcinst.ini && \
    echo "Description = MariaDB ODBC Driver" >> /etc/odbcinst.ini && \
    echo "Driver = /usr/lib/x86_64-linux-gnu/odbc/libmaodbc.so" >> /etc/odbcinst.ini && \
    echo "Setup = /usr/lib/x86_64-linux-gnu/odbc/libmaodbc.so" >> /etc/odbcinst.ini && \
    echo "UsageCount = 1" >> /etc/odbcinst.ini

RUN chown -R asterisk:asterisk /var/www /var/www/html /usr/src/freepbx

VOLUME ["/var/lib/mysql", "/var/spool/asterisk", "/var/www/html", "/etc/asterisk", "/var/lib/asterisk"]

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 80 443 5060/udp 5060/tcp 5160/udp 5160/tcp 10000-20000/udp

CMD ["/start.sh"]