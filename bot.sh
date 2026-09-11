#!/usr/bin/env bash
set -euo pipefail

# ————————————————————————————
# Языковые настройки
# ————————————————————————————
LANG="ru"

REPO_URL="https://github.com/Daket52i/TTMediaBot-by-dancho.git"
REPO_SSH="git@github.com:Daket52i/TTMediaBot-by-dancho.git"

select_language() {
  echo "Выберите язык / Select language / Wybierz język / Seleccione idioma:"
  echo "1. Русский"
  echo "2. English"
  echo "3. Polski"
  echo "4. Español"
  read -p "Введите номер (1-4): " lang_choice

  case $lang_choice in
    1) LANG="ru";;
    2) LANG="en";;
    3) LANG="pl";;
    4) LANG="es";;
    *) LANG="ru";;
  esac
}

msg() {
  case $LANG in
    "ru") echo "$1";;
    "en") echo "$2";;
    "pl") echo "$3";;
    "es") echo "$4";;
    *) echo "$1";;
  esac
}

# ————————————————————————————
# Основные функции
# ————————————————————————————
install_dependencies() {
  msg \
    "Установка необходимых пакетов..." \
    "Installing required packages..." \
    "Instalowanie wymaganych pakietów..." \
    "Instalando paquetes necesarios..."
  
  sudo apt-get update -qq >/dev/null 2>&1
  sudo apt-get install -qq -y git gnulib python3-dev python-is-python3 python3-pip \
    p7zip-full libmpv-dev cron pipewire pipewire-pulse wireplumber libspa-0.2-bluetooth \
    wget curl nodejs npm >/dev/null 2>&1

  msg \
    "Установка Python библиотек..." \
    "Installing Python libraries..." \
    "Instalowanie bibliotek Pythona..." \
    "Instalando bibliotecas Python..."
  
  pip install --break-system-packages httpx==0.27.0 beautifulsoup4 --no-warn-script-location >/dev/null 2>&1
}

setup_github_ssh() {
  msg \
    "Настройка SSH доступа к GitHub..." \
    "Configuring SSH access to GitHub..." \
    "Konfigurowanie dostępu SSH do GitHub..." \
    "Configurando acceso SSH a GitHub..."
  
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh

  if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -C "ttmediabot@server" -f ~/.ssh/id_ed25519 -N "" >/dev/null 2>&1
  fi

  chmod 600 ~/.ssh/id_ed25519

  ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null

  msg \
    "SSH ключ установлен. Добавьте публичный ключ на GitHub:" \
    "SSH key installed. Add the public key to GitHub:" \
    "Klucz SSH zainstalowany. Dodaj klucz publiczny do GitHub:" \
    "Clave SSH instalada. Agregue la clave pública a GitHub:"
  
  echo ""
  cat ~/.ssh/id_ed25519.pub
  echo ""
  
  msg \
    "Перейдите: https://github.com/settings/keys → New SSH key → вставьте ключ above" \
    "Go to: https://github.com/settings/keys → New SSH key → paste the key above" \
    "Przejdź do: https://github.com/settings/keys → New SSH key → wklej klucz powyżej" \
    "Vaya a: https://github.com/settings/keys → New SSH key → pegue la clave arriba"
  
  read -p "$(msg \
    "Нажмите Enter когда добавили ключ..." \
    "Press Enter after adding the key..." \
    "Naciśnij Enter po dodaniu klucza..." \
    "Presione Enter después de agregar la clave...")"
}

setup_pipewire() {
  msg \
    "Настройка PipeWire..." \
    "Configuring PipeWire..." \
    "Konfigurowanie PipeWire..." \
    "Configurando PipeWire..."
  
  systemctl --user --now enable pipewire pipewire-pulse >/dev/null 2>&1

  msg \
    "PipeWire успешно настроен" \
    "PipeWire configured successfully" \
    "PipeWire pomyślnie skonfigurowany" \
    "PipeWire configurado correctamente"
}

create_daily_timer() {
  msg \
    "Создание ежедневного таймера перезагрузки..." \
    "Creating daily restart timer..." \
    "Tworzenie codziennego timera restartu..." \
    "Creando temporizador de reinicio diario..."
  
  mkdir -p ~/.config/systemd/user/

  cat > ~/.config/systemd/user/bot-restart.timer <<EOF
[Unit]
Description=Daily restart of TTMediaBot at 3 AM

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat > ~/.config/systemd/user/bot-restart.service <<EOF
[Unit]
Description=Restart TTMediaBot

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl --user restart bot.service
EOF

  systemctl --user daemon-reload >/dev/null 2>&1
  systemctl --user enable --now bot-restart.timer >/dev/null 2>&1

  msg \
    "Таймер перезагрузки установлен на 03:00 ежедневно" \
    "Restart timer set for 03:00 daily" \
    "Timer restartu ustawiony na 03:00 codziennie" \
    "Temporizador de reinicio establecido a las 03:00 diariamente"
}

cleanup_previous_installation() {
  msg \
    "Удаление предыдущей установки..." \
    "Removing previous installation..." \
    "Usuwanie poprzedniej instalacji..." \
    "Eliminando instalación anterior..."
  
  systemctl --user stop bot.service bot-restart.timer bot-restart.service >/dev/null 2>&1 || true
  systemctl --user disable bot.service bot-restart.timer bot-restart.service >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/bot.service" \
        "$HOME/.config/systemd/user/bot-restart.timer" \
        "$HOME/.config/systemd/user/bot-restart.service"
  rm -rf "$BOT_DIR"
  
  systemctl --user daemon-reload >/dev/null 2>&1
}

cleanup_git_credentials() {
  msg \
    "Очистка старых git авторизационных данных..." \
    "Cleaning old git credentials..." \
    "Czyszczenie starych danych uwierzytelniających git..." \
    "Limpiando credenciales git antiguas..."
  
  git config --global --unset-all credential.helper 2>/dev/null || true
  git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
  rm -f ~/.git-credentials
  
  msg \
    "Git авторизационные данные очищены" \
    "Git credentials cleaned" \
    "Dane uwierzytelniające git wyczyszczone" \
    "Credenciales git limpiadas"
}

clone_repository() {
  msg \
    "Клонирование репозитория TTMediaBot..." \
    "Cloning TTMediaBot repository..." \
    "Klonowanie repozytorium TTMediaBot..." \
    "Clonando repositorio TTMediaBot..."
  
  cleanup_git_credentials
  
  if ! git clone "$REPO_SSH" "$BOT_DIR" -q 2>/dev/null; then
    msg \
      "SSH не сработал, пробуем через HTTPS..." \
      "SSH failed, trying HTTPS..." \
      "SSH nie zadziałało, próbujemy przez HTTPS..." \
      "SSH falló, intentando por HTTPS..."
    git clone "$REPO_URL" "$BOT_DIR" -q
  fi
}

install_requirements() {
  msg \
    "Установка зависимостей Python..." \
    "Installing Python requirements..." \
    "Instalowanie wymagań Pythona..." \
    "Instalando requisitos de Python..."
  
  cd "$BOT_DIR" || exit 1
  pip install --break-system-packages --no-warn-script-location -r requirements.txt >/dev/null 2>&1
}

install_npm_bridge() {
  msg \
    "Установка npm зависимостей для YouTube бриджа..." \
    "Installing npm dependencies for YouTube bridge..." \
    "Instalowanie zależności npm dla YouTube bridge..." \
    "Instalando dependencias npm para YouTube bridge..."
  
  cd "$BOT_DIR/youtube_bridge" || exit 1
  
  if [ -f "package.json" ]; then
    GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_ed25519 -o StrictHostKeyChecking=no" npm install 2>&1 | tail -5
    
    if [ $? -eq 0 ]; then
      msg \
        "npm зависимости установлены" \
        "npm dependencies installed" \
        "Zależności npm zainstalowane" \
        "Dependencias npm instaladas"
    else
      msg \
        "Ошибка установки npm依赖. YouTube бридж может не работать." \
        "Error installing npm deps. YouTube bridge may not work." \
        "Błąd instalacji zależności npm. YouTube bridge może nie działać." \
        "Error instalando dependencias npm. YouTube bridge puede no funcionar."
    fi
  fi
}

download_tools() {
  msg \
    "Установка дополнительных инструментов..." \
    "Installing additional tools..." \
    "Instalowanie dodatkowych narzędzi..." \
    "Instalando herramientas adicionales..."
  
  cd "$BOT_DIR/tools" || exit 1

  msg \
    "Обновление версии TT SDK до 5.22..." \
    "Updating TT SDK version to 5.22..." \
    "Aktualizowanie wersji TT SDK do 5.22..." \
    "Actualizando versión de TT SDK a 5.22..."
  
  if [ -f "ttsdk_downloader.py" ]; then
    sed 's/version = \[i for i in versions if "5\.19" in i\.text\]\[-1\]\.a\.get("href")\[0:-1\]/version = [i for i in versions if "5.22" in i.text][-1].a.get("href")[0:-1]/' ttsdk_downloader.py > ttsdk_downloader_temp.py
    
    if cmp -s ttsdk_downloader.py ttsdk_downloader_temp.py; then
      msg \
        "Версия уже обновлена до 5.22" \
        "Version already updated to 5.22" \
        "Wersja już zaktualizowana do 5.22" \
        "Versión ya actualizada a 5.22"
    else
      mv ttsdk_downloader_temp.py ttsdk_downloader.py
      msg \
        "Версия успешно обновлена до 5.22" \
        "Version successfully updated to 5.22" \
        "Wersja pomyślnie zaktualizowana do 5.22" \
        "Versión actualizada correctamente a 5.22"
    fi
    rm -f ttsdk_downloader_temp.py
  else
    msg \
      "Файл ttsdk_downloader.py не найден" \
      "File ttsdk_downloader.py not found" \
      "Nie znaleziono pliku ttsdk_downloader.py" \
      "Archivo ttsdk_downloader.py no encontrado"
  fi
  
  msg \
    "Загрузка TT SDK..." \
    "Downloading TT SDK..." \
    "Pobieranie TT SDK..." \
    "Descargando TT SDK..."
  
  if ! python ttsdk_downloader.py >/dev/null 2>&1; then
    msg \
      "Ошибка при загрузке через ttsdk_downloader.py. Выполняем ручную загрузку..." \
      "Error downloading via ttsdk_downloader.py. Performing manual download..." \
      "Błąd pobierania przez ttsdk_downloader.py. Wykonujemy ręczne pobieranie..." \
      "Error al descargar mediante ttsdk_downloader.py. Realizando descarga manual..."
    
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
      SDK_URL="https://bearware.dk/teamtalksdk/v5.22a/tt5sdk_v5.22a_ubuntu22_x86_64.7z"
    elif [[ "$ARCH" == arm* ]] || [ "$ARCH" = "aarch64" ]; then
      SDK_URL="https://bearware.dk/teamtalksdk/v5.22a/tt5sdk_v5.22a_raspbian_armhf.7z"
    else
      msg \
        "Неизвестная архитектура: $ARCH. Использую x86_64..." \
        "Unknown architecture: $ARCH. Using x86_64..." \
        "Nieznana architektura: $ARCH. Używam x86_64..." \
        "Arquitectura desconocida: Usando x86_64..."
      SDK_URL="https://bearware.dk/teamtalksdk/v5.22a/tt5sdk_v5.22a_ubuntu22_x86_64.7z"
    fi
    
    msg \
      "Скачивание SDK с $SDK_URL" \
      "Downloading SDK from $SDK_URL" \
      "Pobieranie SDK z $SDK_URL" \
      "Descargando SDK de $SDK_URL"
    
    if command -v wget &> /dev/null; then
      wget -q --show-progress "$SDK_URL" -O ttsdk.7z
    elif command -v curl &> /dev/null; then
      curl -L --progress-bar "$SDK_URL" -o ttsdk.7z
    else
      sudo apt-get install -y wget >/dev/null 2>&1
      wget -q --show-progress "$SDK_URL" -O ttsdk.7z
    fi
    
    if [ -f "ttsdk.7z" ]; then
      msg \
        "Распаковка SDK..." \
        "Extracting SDK..." \
        "Rozpakowywanie SDK..." \
        "Extrayendo SDK..."
      
      rm -rf ttsdk
      mkdir -p ttsdk
      
      if command -v 7z &> /dev/null; then
        7z x ttsdk.7z -ottsdk >/dev/null 2>&1
      else
        sudo apt-get install -y p7zip-full >/dev/null 2>&1
        7z x ttsdk.7z -ottsdk >/dev/null 2>&1
      fi
      
      EXTRACTED_DIR=$(find ttsdk -maxdepth 1 -type d -name "tt5sdk_*" | head -n 1)
      
      if [ -n "$EXTRACTED_DIR" ]; then
        msg \
          "Перемещение файлов SDK..." \
          "Moving SDK files..." \
          "Przenoszenie plików SDK..." \
          "Moviendo archivos SDK..."
        
        DEST_DIR="$BOT_DIR"
        
        if [ -d "$EXTRACTED_DIR/Library/TeamTalk_DLL" ]; then
          rm -rf "$DEST_DIR/TeamTalk_DLL"
          cp -r "$EXTRACTED_DIR/Library/TeamTalk_DLL" "$DEST_DIR/"
          msg \
            "TeamTalk_DLL установлен" \
            "TeamTalk_DLL installed" \
            "TeamTalk_DLL zainstalowany" \
            "TeamTalk_DLL instalado"
        fi
        
        if [ -d "$EXTRACTED_DIR/Library/TeamTalkPy" ]; then
          rm -rf "$DEST_DIR/TeamTalkPy"
          cp -r "$EXTRACTED_DIR/Library/TeamTalkPy" "$DEST_DIR/"
          msg \
            "TeamTalkPy установлен" \
            "TeamTalkPy installed" \
            "TeamTalkPy zainstalowany" \
            "TeamTalkPy instalado"
        fi
        
        if [ -f "$EXTRACTED_DIR/License.txt" ]; then
          cp "$EXTRACTED_DIR/License.txt" "$DEST_DIR/TTSDK_license.txt"
          msg \
            "Лицензия установлена" \
            "License installed" \
            "Licencja zainstalowana" \
            "Licencia instalada"
        fi
        
        msg \
          "SDK успешно установлен вручную" \
          "SDK successfully installed manually" \
          "SDK pomyślnie zainstalowany ręcznie" \
          "SDK instalado correctamente manualmente"
      else
        msg \
          "Не удалось найти распакованные файлы SDK" \
          "Failed to find extracted SDK files" \
          "Nie znaleziono rozpakowanych plików SDK" \
          "No se encontraron archivos SDK extraídos"
      fi
      
      rm -f ttsdk.7z
      rm -rf ttsdk
    else
      msg \
        "Не удалось скачать SDK. Пожалуйста, скачайте вручную." \
        "Failed to download SDK. Please download manually." \
        "Nie udało się pobrać SDK. Proszę pobrać ręcznie." \
        "Error al descargar SDK. Por favor descargue manualmente."
    fi
  fi
  
  msg \
    "Компиляция языков..." \
    "Compiling languages..." \
    "Kompilowanie języków..." \
    "Compilando idiomas..."
  
  if [ -f "compile_locales.py" ]; then
    python compile_locales.py >/dev/null 2>&1
  else
    msg \
      "Файл compile_locales.py не найден, пропускаем..." \
      "File compile_locales.py not found, skipping..." \
      "Nie znaleziono pliku compile_locales.py, pomijanie..." \
      "Archivo compile_locales.py no encontrado, omitiendo..."
  fi
}

create_config() {
  msg \
    "Создание конфигурационного файла..." \
    "Creating configuration file..." \
    "Tworzenie pliku konfiguracyjnego..." \
    "Creando archivo de configuración..."
  
  cd "$BOT_DIR" || exit 1
  cp config_default.json config.json

  read -p "$(msg \
    "Введите hostname сервера: " \
    "Enter server hostname: " \
    "Wprowadź hostname serwera: " \
    "Ingrese el hostname del servidor: ")" hostname
  
  read -p "$(msg \
    "Введите TCP порт: " \
    "Enter TCP port: " \
    "Wprowadź port TCP: " \
    "Ingrese puerto TCP: ")" tcp_port
  
  read -p "$(msg \
    "Введите UDP порт: " \
    "Enter UDP port: " \
    "Wprowadź port UDP: " \
    "Ingrese puerto UDP: ")" udp_port
  
  read -p "$(msg \
    "Используется ли шифрование на сервере? (y/n): " \
    "Is encryption used on the server? (y/n): " \
    "Czy na serwerze jest używane szyfrowanie? (y/n): " \
    "¿Se usa cifrado en el servidor? (s/n): ")" enc
  
  if [[ "$enc" == "y" || "$enc" == "s" ]]; then 
    encrypted_value="true"
  else 
    encrypted_value="false"
  fi
  
  read -p "$(msg \
    "Введите никнейм бота: " \
    "Enter bot nickname: " \
    "Wprowadź nick bota: " \
    "Ingrese apodo del bot: ")" nickname
  
  read -p "$(msg \
    "Введите пол бота (m/f/n): " \
    "Enter bot gender (m/f/n): " \
    "Wprowadź płeć bota (m/f/n): " \
    "Ingrese género del bot (m/f/n): ")" gender
  
  read -p "$(msg \
    "Введите имя пользователя: " \
    "Enter username: " \
    "Wprowadź nazwę użytkownika: " \
    "Ingrese nombre de usuario: ")" username
  
  read -s -p "$(msg \
    "Введите пароль: " \
    "Enter password: " \
    "Wprowadź hasło: " \
    "Ingrese contraseña: ")"; echo
  password="$REPLY"
  
  read -p "$(msg \
    "Введите название канала (по умолчанию '/'): " \
    "Enter channel name (default '/'): " \
    "Wprowadź nazwę kanału (domyślnie '/'): " \
    "Ingrese nombre del canal (por defecto '/'): ")" channel_name
  channel_name=${channel_name:-/}
  
  read -s -p "$(msg \
    "Введите пароль канала (если есть): " \
    "Enter channel password (if any): " \
    "Wprowadź hasło kanału (jeśli istnieje): " \
    "Ingrese contraseña del canal (si tiene): ")"; echo
  channel_password="$REPLY"

  sed -i "s/\"hostname\": \".*\"/\"hostname\": \"$hostname\"/" config.json
  sed -i "s/\"tcp_port\": [0-9]\+/\"tcp_port\": $tcp_port/" config.json
  sed -i "s/\"udp_port\": [0-9]\+/\"udp_port\": $udp_port/" config.json
  sed -i "s/\"encrypted\": [^,]*/\"encrypted\": $encrypted_value/" config.json
  sed -i "s/\"nickname\": \".*\"/\"nickname\": \"$nickname\"/" config.json
  sed -i "s/\"gender\": \".\"/\"gender\": \"$gender\"/" config.json
  sed -i "s/\"username\": \".*\"/\"username\": \"$username\"/" config.json
  sed -i "s/\"password\": \".*\"/\"password\": \"$password\"/" config.json
  sed -i "s|\"channel\": \".*\"|\"channel\": \"$channel_name\"|" config.json
  sed -i "s|\"channel_password\": \".*\"|\"channel_password\": \"$channel_password\"|" config.json

  sed -i "s/\"output_device\": [0-9]\+/\"output_device\": 1/" config.json
  sed -i "s/\"default_service\": \".*\"/\"default_service\": \"yt\"/" config.json

  read -p "$(msg \
    "Введите полный путь к файлу cookies.txt (Enter пропустить): " \
    "Enter full path to cookies.txt file (Enter to skip): " \
    "Wprowadź pełną ścieżkę do pliku cookies.txt (Enter aby pominąć): " \
    "Ingrese la ruta completa al archivo cookies.txt (Enter para omitir): ")" cookiefile
  if [ -n "$cookiefile" ]; then
    sed -i "s|\"cookiefile_path\": \".*\"|\"cookiefile_path\": \"$cookiefile\"|" config.json
  fi

  msg \
    "Конфигурационный файл успешно создан" \
    "Configuration file created successfully" \
    "Plik konfiguracyjny został pomyślnie utworzony" \
    "Archivo de configuración creado correctamente"
}

install_service() {
  msg \
    "Установка systemd сервиса..." \
    "Installing systemd service..." \
    "Instalowanie usługi systemd..." \
    "Instalando servicio systemd..."
  
  mkdir -p ~/.config/systemd/user/

  cat > ~/.config/systemd/user/bot.service <<EOF
[Unit]
Description=TTMediaBot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BOT_DIR
ExecStartPre=/bin/sleep 10
ExecStart=$BOT_DIR/TTMediaBot.sh -c $BOT_DIR/config.json
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload >/dev/null 2>&1
  systemctl --user enable --now bot >/dev/null 2>&1

  msg \
    "Сервис успешно установлен и запущен" \
    "Service successfully installed and started" \
    "Usługa została pomyślnie zainstalowana i uruchomiona" \
    "Servicio instalado e iniciado correctamente"
}

enable_linger() {
  msg \
    "Включение linger для пользователя..." \
    "Enabling linger for user..." \
    "Włączanie linger dla użytkownika..." \
    "Habilitando linger para el usuario..."
  
  sudo loginctl enable-linger "$USER" >/dev/null 2>&1
}

# ————————————————————————————
# Главная функция
# ————————————————————————————
main() {
  select_language

  msg \
    "Добро пожаловать в скрипт установки TTMediaBot — Russian Edition" \
    "Welcome to TTMediaBot installation script — Russian Edition" \
    "Witaj w skrypcie instalacyjnym TTMediaBot — Russian Edition" \
    "Bienvenido al script de instalación de TTMediaBot — Russian Edition"
  
  msg \
    "Автор: DJ Dancho" \
    "Author: DJ Dancho" \
    "Autor: DJ Dancho" \
    "Autor: DJ Dancho"
  
  msg \
    "Репозиторий: https://github.com/Daket52i/TTMediaBot-by-dancho" \
    "Repository: https://github.com/Daket52i/TTMediaBot-by-dancho" \
    "Repozytorium: https://github.com/Daket52i/TTMediaBot-by-dancho" \
    "Repositorio: https://github.com/Daket52i/TTMediaBot-by-dancho"
  
  read -p "$(msg \
    "Нажмите Enter для начала установки..." \
    "Press Enter to start installation..." \
    "Naciśnij Enter aby rozpocząć instalację..." \
    "Presione Enter para comenzar la instalación...")"

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  BOT_DIR="$SCRIPT_DIR/TTMediaBot"

  install_dependencies
  setup_github_ssh
  cleanup_previous_installation
  clone_repository
  install_requirements
  install_npm_bridge
  download_tools
  setup_pipewire
  create_config
  install_service
  create_daily_timer
  enable_linger
  
  msg \
    "Установка TTMediaBot успешно завершена!" \
    "TTMediaBot installation completed successfully!" \
    "Instalacja TTMediaBot zakończona pomyślnie!" \
    "¡Instalación de TTMediaBot completada con éxito!"
  
  msg \
    "Для проверки статуса бота: systemctl --user status bot" \
    "To check bot status: systemctl --user status bot" \
    "Aby sprawdzić status bota: systemctl --user status bot" \
    "Para verificar el estado del bot: systemctl --user status bot"
  
  msg \
    "Для просмотра запланированных перезагрузок: systemctl --user list-timers" \
    "To view scheduled restarts: systemctl --user list-timers" \
    "Aby zobaczyć zaplanowane restart: systemctl --user list-timers" \
    "Para ver reinicios programados: systemctl --user list-timers"
}

main
