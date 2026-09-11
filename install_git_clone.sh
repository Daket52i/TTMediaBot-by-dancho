#!/bin/bash

# ================================================================= #
# Auto Installer & Cloner - TTMediaBot
# ================================================================= #

# Auto-elevate to root via sudo if needed
if [ "$EUID" -ne 0 ]; then
    echo "Not running as root. Re-launching with sudo..."
    exec sudo bash "$0" "$@"
fi


REPO_URL="https://github.com/Daket52i/TTMediaBot-by-dancho.git"

# Function to detect package manager and install packages
install_packages() {
    local PKGS=("$@")
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y "${PKGS[@]}"
    elif command -v dnf &> /dev/null; then
        dnf install -y "${PKGS[@]}"
    elif command -v yum &> /dev/null; then
        yum install -y "${PKGS[@]}"
    elif command -v pacman &> /dev/null; then
        pacman -S --noconfirm "${PKGS[@]}"
    elif command -v zypper &> /dev/null; then
        zypper install -y "${PKGS[@]}"
    elif command -v apk &> /dev/null; then
        apk add --no-cache "${PKGS[@]}"
    else
        echo "Error: Package manager not found. Please install manually: ${PKGS[*]}"
        exit 1
    fi
}

echo "--- Checking for Git ---"
if ! command -v git &> /dev/null; then
    echo "Git not found. Installing..."
    install_packages git
else
    echo "Git is already installed."
fi

echo "--- Checking for unzip (ZIP extractor) ---"
if ! command -v unzip &> /dev/null; then
    echo "unzip not found. Installing..."
    install_packages unzip
else
    echo "unzip is already installed."
fi

# Detect if we are already inside the repository
if [ -d ".git" ] && git remote get-url origin 2>/dev/null | grep -q "TTMediaBot"; then
    echo "--- Already inside TTMediaBot repository. Skipping clone. ---"
    CURRENT_IS_REPO=true
else
    CURRENT_IS_REPO=false
fi

DIR_NAME="TTMediaBot"

if [ "$CURRENT_IS_REPO" = false ]; then
    if [ -d "$DIR_NAME" ]; then
        echo "Directory '$DIR_NAME' already exists. Updating..."
        cd "$DIR_NAME" || exit
        git pull
    else
        echo "--- Cloning Repository ---"
        # Каталог задаём явно: без этого git берёт имя из URL
        # (TTMediaBot-by-dancho), а дальше скрипт идёт в TTMediaBot и падает.
        git clone "$REPO_URL" "$DIR_NAME"
        if [ $? -ne 0 ]; then
            echo "Error cloning repository. Check your internet connection."
            exit 1
        fi
        cd "$DIR_NAME" || exit
    fi
fi

# Enter directory and set permissions
# Set permissions and ownership
echo "--- Setting Permissions and Ownership ---"
git config core.fileMode false 2>/dev/null

REAL_USER=${SUDO_USER:-$USER}

# Ensure permissions are correct for the current folder and everything inside
chown -R "$REAL_USER":"$REAL_USER" .
chmod -R 777 .
chmod +x *.sh

echo "Ownership and permissions set for user: $REAL_USER"

echo "--- Checking TeamTalk_DLL ---"

# DLL качаем с официального сайта bearware (та же версия 5.22a, что и в bot.sh),
# а не из релизов чужого репозитория: там лежала старая сборка.
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" || "$ARCH" =~ ^arm ]]; then
    echo "ARM architecture detected ($ARCH). Using ARM SDK..."
    SDK_URL="https://bearware.dk/teamtalksdk/v5.22a/tt5sdk_v5.22a_raspbian_arm64.7z"
else
    echo "x86_64/AMD64 architecture detected ($ARCH). Using x86 SDK..."
    SDK_URL="https://bearware.dk/teamtalksdk/v5.22a/tt5sdk_v5.22a_ubuntu22_x86_64.7z"
fi
SDK_FILE="ttsdk.7z"

if [ -d "TeamTalk_DLL" ] && [ -f "TeamTalk_DLL/libTeamTalk5.so" ] && [ -d "TeamTalkPy" ]; then
    echo "TeamTalk_DLL and TeamTalkPy already exist. Skipping download and extraction."
else
    if ! command -v 7z &> /dev/null; then
        echo "7z not found. Installing p7zip..."
        # Имя пакета зависит от дистрибутива: в Debian/Ubuntu — p7zip-full,
        # в RHEL/Fedora — p7zip.
        install_packages p7zip-full || install_packages p7zip || true
    fi
    if ! command -v 7z &> /dev/null; then
        echo "ERROR: 7z not found (package p7zip-full). Cannot extract SDK."
        exit 1
    fi

    echo "Downloading TeamTalk SDK..."
    rm -f "$SDK_FILE"
    wget -q --show-progress "$SDK_URL" -O "$SDK_FILE" || true
    if [ ! -s "$SDK_FILE" ]; then
        echo "ERROR: failed to download TeamTalk SDK from $SDK_URL."
        rm -f "$SDK_FILE"
        exit 1
    fi
    echo "Download complete."

    echo "--- Extracting TeamTalk SDK ---"
    rm -rf ttsdk
    mkdir -p ttsdk
    if ! 7z x "$SDK_FILE" -ottsdk > /tmp/ttbot_7z.log 2>&1; then
        echo "ERROR: failed to extract the SDK archive. Last log lines:"
        tail -n 15 /tmp/ttbot_7z.log
        rm -f "$SDK_FILE"
        exit 1
    fi
    echo "Extraction complete."

    EXTRACTED_DIR=$(find ttsdk -maxdepth 1 -mindepth 1 -type d -name "tt5sdk_*" -print -quit)
    if [ -z "$EXTRACTED_DIR" ]; then
        echo "ERROR: no tt5sdk_* directory inside the archive."
        rm -f "$SDK_FILE"
        rm -rf ttsdk
        exit 1
    fi

    if [ -d "$EXTRACTED_DIR/Library/TeamTalk_DLL" ]; then
        rm -rf TeamTalk_DLL
        cp -r "$EXTRACTED_DIR/Library/TeamTalk_DLL" .
    fi
    if [ -d "$EXTRACTED_DIR/Library/TeamTalkPy" ]; then
        rm -rf TeamTalkPy
        cp -r "$EXTRACTED_DIR/Library/TeamTalkPy" .
    fi
    if [ -f "$EXTRACTED_DIR/License.txt" ]; then
        cp "$EXTRACTED_DIR/License.txt" ./TTSDK_license.txt
    fi

    rm -f "$SDK_FILE"
    rm -rf ttsdk
    echo "SDK zip removed."
fi

# Без библиотеки бот уходит в бесконечный рестарт уже после «успешной»
# установки, поэтому проверяем оба каталога сразу.
if [ ! -f "TeamTalk_DLL/libTeamTalk5.so" ] || [ ! -f "TeamTalkPy/TeamTalk5.py" ]; then
    echo "ERROR: TeamTalk_DLL/libTeamTalk5.so or TeamTalkPy/TeamTalk5.py is missing!"
    echo "Without it the bot cannot connect to a TeamTalk server. Installation stopped."
    exit 1
fi
echo "TeamTalk_DLL folder is ready!"

echo "--- Setting permissions for TeamTalk_DLL ---"
chown -R "$REAL_USER":"$REAL_USER" TeamTalk_DLL TeamTalkPy || true
chmod -R 777 TeamTalk_DLL TeamTalkPy
echo "Permissions set for SDK folders."

echo "Setup Complete! Starting Docker Manager..."
sleep 2

if [ -f "./ttbotdocker.sh" ]; then
    chmod +x ./ttbotdocker.sh
    exec ./ttbotdocker.sh
else
    echo "ERROR: ttbotdocker.sh not found!"
    exit 1
fi