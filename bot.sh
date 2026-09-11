#!/usr/bin/env bash
set -euo pipefail

# ————————————————————————————
# Языковые настройки
# ————————————————————————————
LANG="ru"

REPO_URL="https://github.com/Daket52i/TTMediaBot-by-dancho.git"
REPO_SSH="git@github.com:Daket52i/TTMediaBot-by-dancho.git"

# Установка идёт в системные пакеты и в user-systemd, поэтому нужен root.
# Раньше скрипт всегда звал sudo и на сервере без sudo падал молча.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  echo "Ошибка: нужны права root. Запустите скрипт от root или установите sudo."
  echo "Error: root privileges required. Run as root or install sudo."
  exit 1
fi

# Флаги pip выставляются в install_dependencies, когда pip уже установлен.
PIP_FLAGS=""

# $USER в неинтерактивном сеансе (su, cron, часть SSH-оболочек) пустой —
# loginctl тогда падал с пустым аргументом. Берём фактического пользователя.
BOT_USER="${USER:-$(id -un)}"

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

# systemctl --user из обычного SSH-сеанса root часто не работает: нет шины
# пользовательской сессии. Под set -e каждая такая команда молча убивала
# установку. Обёртка выставляет окружение и возвращает код ошибки.
userctl() {
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  fi
  systemctl --user "$@"
}

# Проверка, живёт ли пользовательский systemd — чтобы предупредить один раз.
user_systemd_works() {
  userctl is-system-running >/dev/null 2>&1 || userctl status >/dev/null 2>&1
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
  
  # Node.js здесь больше не ставится: он был нужен только YouTube-бриджу,
  # а YouTube из бота убран.
  $SUDO apt-get update -qq

  # Обязательные пакеты. Если хоть один не поставится — установку прекращаем
  # с внятной ошибкой, а не молчаливым выходом в середине скрипта.
  #   ffmpeg        — скачивание видео с Rutube
  #   libmpv-dev    — даёт libmpv.so, который ищет плеер бота
  #   p7zip-full    — распаковка архива TeamTalk SDK
  #   ca-certificates/gnupg/wget/curl — https, ключи, скачивание
  if ! $SUDO apt-get install -qq -y \
      git python3-dev python-is-python3 python3-pip python3-venv \
      p7zip-full libmpv-dev cron wget curl ca-certificates gnupg ffmpeg; then
    msg \
      "Не удалось установить обязательные пакеты (см. вывод apt выше). Установка остановлена." \
      "Failed to install required packages (see apt output above). Installation stopped." \
      "Nie udało się zainstalować wymaganych pakietów. Instalacja zatrzymana." \
      "No se pudieron instalar los paquetes necesarios. Instalación detenida."
    exit 1
  fi

  # Необязательные пакеты звука: без них бот работает через системный звук.
  # Их отсутствие установку не срывает.
  $SUDO apt-get install -qq -y pipewire pipewire-pulse wireplumber libspa-0.2-bluetooth || \
    msg \
      "Предупреждение: пакеты звука (pipewire) не установились — продолжаем без них." \
      "Warning: audio packages (pipewire) failed to install — continuing without them." \
      "Uwaga: pakiety dźwięku nie zainstalowały się — kontynuujemy bez nich." \
      "Aviso: los paquetes de audio no se instalaron — continuamos sin ellos."

  # pip в Debian 12 / Ubuntu 24 требует --break-system-packages (PEP 668),
  # а на Ubuntu 22.04 (pip 22) такого флага ещё нет — иначе установка падала.
  python3 -m pip install --upgrade pip >/dev/null 2>&1 || true
  if python3 -m pip install --help 2>/dev/null | grep -q -- "--break-system-packages"; then
    PIP_FLAGS="--break-system-packages"
  fi
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
  
  if ! userctl --now enable pipewire pipewire-pulse >/dev/null 2>&1; then
    msg \
      "Предупреждение: не удалось включить PipeWire — звук будет браться из системных настроек." \
      "Warning: could not start PipeWire — using system audio settings." \
      "Uwaga: nie udało się uruchomić PipeWire — używane będą ustawienia systemowe." \
      "Aviso: no se pudo iniciar PipeWire — se usarán los ajustes de audio del sistema."
    return 0
  fi

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

  userctl daemon-reload >/dev/null 2>&1 || true
  if ! userctl enable --now bot-restart.timer >/dev/null 2>&1; then
    msg \
      "Предупреждение: таймер ежедневной перезагрузки не включился." \
      "Warning: daily restart timer could not be enabled." \
      "Uwaga: nie udało się włączyć timera restartu." \
      "Aviso: no se pudo activar el temporizador de reinicio diario."
  fi

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
  
  userctl stop bot.service bot-restart.timer bot-restart.service >/dev/null 2>&1 || true
  userctl disable bot.service bot-restart.timer bot-restart.service >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/bot.service" \
        "$HOME/.config/systemd/user/bot-restart.timer" \
        "$HOME/.config/systemd/user/bot-restart.service"
  rm -rf "$BOT_DIR"

  userctl daemon-reload >/dev/null 2>&1 || true
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
  # Тишина при успехе, полный лог pip — при ошибке.
  if ! python3 -m pip install $PIP_FLAGS --no-warn-script-location -r requirements.txt > /tmp/ttbot_pip.log 2>&1; then
    msg \
      "Ошибка установки Python-зависимостей. Последние строки лога:" \
      "Failed to install Python requirements. Last log lines:" \
      "Błąd instalacji zależności Pythona. Ostatnie linie logu:" \
      "Error al instalar dependencias de Python. Últimas líneas del log:"
    tail -n 25 /tmp/ttbot_pip.log
    exit 1
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
    "Загрузка TT SDK..." \
    "Downloading TT SDK..." \
    "Pobieranie TT SDK..." \
    "Descargando TT SDK..."

  ARCH=$(uname -m)
  if [ "$ARCH" = "x86_64" ]; then
    SDK_URL="https://bearware.dk/teamtalksdk/v5.22a/tt5sdk_v5.22a_ubuntu22_x86_64.7z"
  elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    # Именно raspbian_arm64: сборки armhf в 5.22a нет, старая ссылка
    # ..._raspbian_armhf.7z отдаёт 404 и установка падала.
    SDK_URL="https://bearware.dk/teamtalksdk/v5.22a/tt5sdk_v5.22a_raspbian_arm64.7z"
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

  rm -f ttsdk.7z
  if command -v wget &> /dev/null; then
    wget -q --show-progress "$SDK_URL" -O ttsdk.7z || true
  else
    curl -L --progress-bar "$SDK_URL" -o ttsdk.7z || true
  fi

  # Обрыв связи раньше оставлял пустой файл, и установка «успешно» завершалась.
  if [ ! -s "ttsdk.7z" ]; then
    msg \
      "Не удалось скачать TeamTalk SDK. Без него бот не подключится к серверу. Установка остановлена." \
      "Failed to download TeamTalk SDK. Without it the bot cannot connect. Installation stopped." \
      "Nie udało się pobrać TeamTalk SDK. Bez niego bot się nie połączy. Instalacja zatrzymana." \
      "No se pudo descargar el SDK de TeamTalk. Sin él el bot no se conectará. Instalación detenida."
    rm -f ttsdk.7z
    exit 1
  fi

  msg \
    "Распаковка SDK..." \
    "Extracting SDK..." \
    "Rozpakowywanie SDK..." \
    "Extrayendo SDK..."

  rm -rf ttsdk
  mkdir -p ttsdk

  if ! command -v 7z &> /dev/null; then
    $SUDO apt-get install -qq -y p7zip-full >/dev/null 2>&1 || true
  fi
  if ! command -v 7z &> /dev/null; then
    msg \
      "Не найден 7z (пакет p7zip-full). Распаковать SDK нечем, установка остановлена." \
      "7z not found (package p7zip-full). Cannot extract SDK, installation stopped." \
      "Nie znaleziono 7z (pakiet p7zip-full). Nie można rozpakować SDK, instalacja zatrzymana." \
      "No se encontró 7z (paquete p7zip-full). No se puede extraer el SDK, instalación detenida."
    rm -f ttsdk.7z
    exit 1
  fi
  if ! 7z x ttsdk.7z -ottsdk > /tmp/ttbot_7z.log 2>&1; then
    msg \
      "Не удалось распаковать архив SDK. Последние строки лога:" \
      "Failed to extract the SDK archive. Last log lines:" \
      "Nie udało się rozpakować archiwum SDK. Ostatnie linie logu:" \
      "No se pudo extraer el archivo del SDK. Últimas líneas del log:"
    tail -n 15 /tmp/ttbot_7z.log
    rm -f ttsdk.7z
    exit 1
  fi

  # -print -quit вместо head: без SIGPIPE, который под pipefail убивал скрипт.
  EXTRACTED_DIR=$(find ttsdk -maxdepth 1 -mindepth 1 -type d -name "tt5sdk_*" -print -quit)

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
  fi

  rm -f ttsdk.7z
  rm -rf ttsdk

  # Раньше отсутствие библиотеки замечалось только на старте бота — сервис
  # уходил в бесконечный рестарт уже после «успешной» установки.
  if [ ! -f "$BOT_DIR/TeamTalk_DLL/libTeamTalk5.so" ] || [ ! -f "$BOT_DIR/TeamTalkPy/TeamTalk5.py" ]; then
    msg \
      "SDK распакован не полностью: нет TeamTalk_DLL/libTeamTalk5.so или TeamTalkPy. Установка остановлена." \
      "SDK extracted incompletely: TeamTalk_DLL/libTeamTalk5.so or TeamTalkPy missing. Installation stopped." \
      "SDK rozpakowany niekompletnie: brak TeamTalk_DLL/libTeamTalk5.so lub TeamTalkPy. Instalacja zatrzymana." \
      "SDK extraído de forma incompleta: falta TeamTalk_DLL/libTeamTalk5.so o TeamTalkPy. Instalación detenida."
    exit 1
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
  
  # Порт спрашиваем в цикле: раньше нечисловой ввод молча ломал конфиг,
  # и бот падал уже после установки.
  while :; do
    read -p "$(msg \
      "Введите TCP порт (по умолчанию 10333): " \
      "Enter TCP port (default 10333): " \
      "Wprowadź port TCP (domyślnie 10333): " \
      "Ingrese puerto TCP (por defecto 10333): ")" tcp_port
    tcp_port=${tcp_port:-10333}
    if [[ "$tcp_port" =~ ^[0-9]+$ ]] && [ "$tcp_port" -ge 1 ] && [ "$tcp_port" -le 65535 ]; then
      break
    fi
    msg \
      "Порт должен быть числом от 1 до 65535." \
      "The port must be a number between 1 and 65535." \
      "Port musi być liczbą od 1 do 65535." \
      "El puerto debe ser un número entre 1 y 65535."
  done
  
  while :; do
    read -p "$(msg \
      "Введите UDP порт (по умолчанию 10333): " \
      "Enter UDP port (default 10333): " \
      "Wprowadź port UDP (domyślnie 10333): " \
      "Ingrese puerto UDP (por defecto 10333): ")" udp_port
    udp_port=${udp_port:-10333}
    if [[ "$udp_port" =~ ^[0-9]+$ ]] && [ "$udp_port" -ge 1 ] && [ "$udp_port" -le 65535 ]; then
      break
    fi
    msg \
      "Порт должен быть числом от 1 до 65535." \
      "The port must be a number between 1 and 65535." \
      "Port musi być liczbą od 1 do 65535." \
      "El puerto debe ser un número entre 1 y 65535."
  done
  
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
  
  # Бот понимает только m/f/n (иначе KeyError на старте), поэтому проверяем.
  while :; do
    read -p "$(msg \
      "Введите пол бота (m/f/n, по умолчанию n): " \
      "Enter bot gender (m/f/n, default n): " \
      "Wprowadź płeć bota (m/f/n, domyślnie n): " \
      "Ingrese género del bot (m/f/n, por defecto n): ")" gender
    gender=$(echo "${gender:-n}" | tr '[:upper:]' '[:lower:]')
    case "$gender" in
      m|f|n) break ;;
    esac
    msg \
      "Пол может быть только m, f или n." \
      "Gender can only be m, f or n." \
      "Płeć może być tylko m, f lub n." \
      "El género solo puede ser m, f o n."
  done
  
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

  # Правим JSON через python, а не sed: sed ломал конфиг, если в пароле или
  # названии канала встречались кавычки, слэш или обратный слэш.
  # Значения передаём через окружение — так они не интерпретируются шеллом.
  TT_CFG_HOSTNAME="$hostname" \
  TT_CFG_TCP="$tcp_port" \
  TT_CFG_UDP="$udp_port" \
  TT_CFG_ENCRYPTED="$encrypted_value" \
  TT_CFG_NICKNAME="$nickname" \
  TT_CFG_GENDER="$gender" \
  TT_CFG_USERNAME="$username" \
  TT_CFG_PASSWORD="$password" \
  TT_CFG_CHANNEL="$channel_name" \
  TT_CFG_CHANNEL_PASSWORD="$channel_password" \
  python3 - <<'PYEOF' || exit 1
import json
import os

with open("config.json", encoding="utf-8") as f:
    cfg = json.load(f)

tt = cfg.setdefault("teamtalk", {})
tt["hostname"] = os.environ["TT_CFG_HOSTNAME"]
tt["tcp_port"] = int(os.environ["TT_CFG_TCP"])
tt["udp_port"] = int(os.environ["TT_CFG_UDP"])
tt["encrypted"] = os.environ["TT_CFG_ENCRYPTED"] == "true"
tt["nickname"] = os.environ["TT_CFG_NICKNAME"]
tt["gender"] = os.environ["TT_CFG_GENDER"]
tt["username"] = os.environ["TT_CFG_USERNAME"]
tt["password"] = os.environ["TT_CFG_PASSWORD"]
tt["channel"] = os.environ["TT_CFG_CHANNEL"]
tt["channel_password"] = os.environ["TT_CFG_CHANNEL_PASSWORD"]

# Основной сервис — музофонд. YouTube из бота убран, спрашивать про
# cookies.txt больше нечего.
cfg.setdefault("services", {})["default_service"] = "mf"

# output_device намеренно не трогаем: на сервере без второго устройства
# вывода бот падал с IndexError и уходил в рестарт. Остаётся 0 из шаблона.

tmp = "config.json.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=4)
os.replace(tmp, "config.json")
PYEOF

  if [ ! -s "config.json" ]; then
    msg \
      "Не удалось записать config.json. Установка остановлена." \
      "Failed to write config.json. Installation stopped." \
      "Nie udało się zapisać config.json. Instalacja zatrzymana." \
      "No se pudo escribir config.json. Instalación detenida."
    exit 1
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

  chmod +x "$BOT_DIR/TTMediaBot.sh" 2>/dev/null || true

  userctl daemon-reload >/dev/null 2>&1 || true
  if ! userctl enable --now bot >/dev/null 2>&1; then
    msg \
      "Внимание: сервис создан, но не запустился. Проверьте: systemctl --user status bot" \
      "Attention: service created but not started. Check: systemctl --user status bot" \
      "Uwaga: usługa utworzona, ale nie uruchomiona. Sprawdź: systemctl --user status bot" \
      "Atención: el servicio se creó pero no se inició. Verifique: systemctl --user status bot"
    return 0
  fi

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
  
  if ! $SUDO loginctl enable-linger "$BOT_USER" >/dev/null 2>&1; then
    msg \
      "Предупреждение: не удалось включить linger — сервис может останавливаться при выходе из SSH." \
      "Warning: could not enable linger — the service may stop when the SSH session ends." \
      "Uwaga: nie udało się włączyć linger — usługa może zatrzymać się po wyjściu z SSH." \
      "Aviso: no se pudo habilitar linger — el servicio puede detenerse al cerrar SSH."
  fi
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
  download_tools
  setup_pipewire
  create_config
  # linger включаем до старта сервиса: иначе бот стартует в сессии SSH и
  # гаснет, как только установщик закрывает соединение.
  enable_linger
  if ! user_systemd_works; then
    msg \
      "Предупреждение: пользовательский systemd в этом сеансе не отвечает. Сервис будет создан, но автозапуск может не включиться — проверьте после установки: systemctl --user status bot" \
      "Warning: user systemd is not responding in this session. The service will be created, but autostart may not enable — check after install: systemctl --user status bot" \
      "Uwaga: systemd użytkownika nie odpowiada w tej sesji. Usługa zostanie utworzona, ale autostart może się nie włączyć — sprawdź po instalacji: systemctl --user status bot" \
      "Aviso: el systemd de usuario no responde en esta sesión. El servicio se creará, pero el inicio automático puede no activarse — verifique: systemctl --user status bot"
  fi
  install_service
  create_daily_timer
  
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
