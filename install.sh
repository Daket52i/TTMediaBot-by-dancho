#!/bin/bash
# ================================================================= #
# Local installation script (without Docker) — TTMediaBot Russian Edition
# Run from the repository root:  sudo ./install.sh
#
# Раньше скрипт уходил на каталог выше и искал подпапку TTMediaBot — при
# клонировании репозитория в TTMediaBot-by-dancho он всегда падал с
# «TTMediaBot directory not found». Теперь работаем прямо в каталоге скрипта.
# ================================================================= #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Установка идёт в системные пакеты, поэтому нужен root.
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    echo "Error: root privileges required. Run as root or install sudo."
    exit 1
fi

echo "--- Detecting package manager and installing dependencies ---"
ARCH=$(uname -m)
EXTRA_PACKAGES=""

# ffmpeg обязателен: без него не скачивается видео с Rutube (сервис включён
# по умолчанию, поэтому раньше он молча не работал).
if command -v apt-get &> /dev/null; then
    if [[ "$ARCH" == "aarch64" || "$ARCH" =~ ^arm ]]; then
        EXTRA_PACKAGES="libportaudio2"
    fi
    $SUDO apt-get update -qq
    $SUDO apt-get install -qq -y libmpv-dev pulseaudio p7zip-full ffmpeg python3-venv python3-dev python3-pip git ca-certificates curl gnupg $EXTRA_PACKAGES

elif command -v dnf &> /dev/null; then
    if [[ "$ARCH" == "aarch64" || "$ARCH" =~ ^arm ]]; then
        EXTRA_PACKAGES="portaudio"
    fi
    $SUDO dnf install -y mpv-devel pulseaudio p7zip ffmpeg python3 python3-pip p7zip-plugins git ca-certificates curl gnupg2 $EXTRA_PACKAGES

elif command -v yum &> /dev/null; then
    if [[ "$ARCH" == "aarch64" || "$ARCH" =~ ^arm ]]; then
        EXTRA_PACKAGES="portaudio"
    fi
    $SUDO yum install -y epel-release || true
    $SUDO yum install -y mpv-devel pulseaudio p7zip ffmpeg python3 python3-pip p7zip-plugins git ca-certificates curl gnupg2 $EXTRA_PACKAGES

elif command -v pacman &> /dev/null; then
    if [[ "$ARCH" == "aarch64" || "$ARCH" =~ ^arm ]]; then
        EXTRA_PACKAGES="portaudio"
    fi
    $SUDO pacman -Sy --noconfirm mpv pulseaudio p7zip ffmpeg python python-pip git ca-certificates curl gnupg $EXTRA_PACKAGES

elif command -v zypper &> /dev/null; then
    if [[ "$ARCH" == "aarch64" || "$ARCH" =~ ^arm ]]; then
        EXTRA_PACKAGES="portaudio"
    fi
    $SUDO zypper install -y mpv-devel pulseaudio p7zip ffmpeg python3 python3-pip git ca-certificates curl gpg2 $EXTRA_PACKAGES

elif command -v apk &> /dev/null; then
    if [[ "$ARCH" == "aarch64" || "$ARCH" =~ ^arm ]]; then
        EXTRA_PACKAGES="portaudio"
    fi
    $SUDO apk add --no-cache mpv-dev pulseaudio p7zip ffmpeg python3 py3-pip git ca-certificates curl gnupg $EXTRA_PACKAGES

else
    echo "Error: Unsupported package manager. Please install dependencies manually."
    exit 1
fi

# p7zip в некоторых репозиториях даёт только 7za/7zr — проверяем распаковщик.
if ! command -v 7z &> /dev/null && ! command -v 7za &> /dev/null; then
    echo "Error: 7z not found (install p7zip-full). Cannot unpack TeamTalk SDK."
    exit 1
fi
SEVEN_ZIP="$(command -v 7z || command -v 7za)"

echo "--- Creating and activating virtual environment (venv) ---"
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate

echo "--- Installing requirements within venv ---"
python3 -m pip install --upgrade pip >/dev/null
if ! python3 -m pip install --no-warn-script-location -r requirements.txt > /tmp/ttbot_pip.log 2>&1; then
    echo "Error: failed to install Python requirements. Last log lines:"
    tail -n 25 /tmp/ttbot_pip.log
    exit 1
fi

echo "--- Downloading TeamTalk SDK 5.22a ---"
# TeamTalk_DLL в репозиторий не входит (.gitignore), поэтому библиотеку
# обязательно скачиваем: без libTeamTalk5.so бот не подключится к серверу.
if [ "$ARCH" = "x86_64" ]; then
    SDK_URL="https://bearware.dk/teamtalksdk/v5.22a/tt5sdk_v5.22a_ubuntu22_x86_64.7z"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    SDK_URL="https://bearware.dk/teamtalksdk/v5.22a/tt5sdk_v5.22a_raspbian_arm64.7z"
else
    echo "Unknown architecture: $ARCH. Using x86_64."
    SDK_URL="https://bearware.dk/teamtalksdk/v5.22a/tt5sdk_v5.22a_ubuntu22_x86_64.7z"
fi

rm -f ttsdk.7z
if command -v wget &> /dev/null; then
    wget -q --show-progress "$SDK_URL" -O ttsdk.7z || true
else
    curl -L --progress-bar "$SDK_URL" -o ttsdk.7z || true
fi

if [ ! -s ttsdk.7z ]; then
    echo "Error: failed to download TeamTalk SDK. Installation stopped."
    rm -f ttsdk.7z
    exit 1
fi

rm -rf ttsdk
mkdir -p ttsdk
if ! "$SEVEN_ZIP" x ttsdk.7z -ottsdk > /tmp/ttbot_7z.log 2>&1; then
    echo "Error: failed to extract the SDK archive. Last log lines:"
    tail -n 15 /tmp/ttbot_7z.log
    rm -f ttsdk.7z
    exit 1
fi

EXTRACTED_DIR="$(find ttsdk -maxdepth 1 -mindepth 1 -type d -name "tt5sdk_*" -print -quit)"
if [ -z "$EXTRACTED_DIR" ]; then
    echo "Error: no tt5sdk_* directory inside the archive."
    rm -f ttsdk.7z
    rm -rf ttsdk
    exit 1
fi

# Через if, а не `[ ... ] && cp`: под set -e ложное условие в такой
# конструкции завершает весь скрипт с кодом 1.
if [ -d "$EXTRACTED_DIR/Library/TeamTalk_DLL" ]; then
    rm -rf "$SCRIPT_DIR/TeamTalk_DLL"
    cp -r "$EXTRACTED_DIR/Library/TeamTalk_DLL" "$SCRIPT_DIR/"
fi
if [ -d "$EXTRACTED_DIR/Library/TeamTalkPy" ]; then
    rm -rf "$SCRIPT_DIR/TeamTalkPy"
    cp -r "$EXTRACTED_DIR/Library/TeamTalkPy" "$SCRIPT_DIR/"
fi
if [ -f "$EXTRACTED_DIR/License.txt" ]; then
    cp "$EXTRACTED_DIR/License.txt" "$SCRIPT_DIR/TTSDK_license.txt"
fi

rm -f ttsdk.7z
rm -rf ttsdk

if [ ! -f "$SCRIPT_DIR/TeamTalk_DLL/libTeamTalk5.so" ] || [ ! -f "$SCRIPT_DIR/TeamTalkPy/TeamTalk5.py" ]; then
    echo "Error: SDK extracted incompletely (libTeamTalk5.so or TeamTalkPy missing)."
    echo "Without it the bot cannot connect to a TeamTalk server. Installation stopped."
    exit 1
fi

chmod +x "$SCRIPT_DIR/TTMediaBot.sh" 2>/dev/null || true

echo "---------------------------------------------------------------------"
echo "INSTALLATION COMPLETED SUCCESSFULLY"
echo "---------------------------------------------------------------------"
echo "1. Configure 'config.json' with your TeamTalk server details:"
echo "   cp config_default.json config.json && nano config.json"
echo ""
echo "2. Start the bot:"
echo "   ./TTMediaBot.sh"
echo ""
echo "3. The virtual environment (venv) is currently ACTIVE in this session."
echo "   If you close this terminal, reactivate it from $SCRIPT_DIR with:"
echo "   source venv/bin/activate"
echo ""
echo "   Автозапуск (systemd) настраивает установщик bot.sh."
echo "---------------------------------------------------------------------"
