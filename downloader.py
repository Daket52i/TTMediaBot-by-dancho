import logging
import os

import requests
import shutil

_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Accept": "*/*",
}

# (таймаут подключения, таймаут чтения) в секундах. Без таймаута зависший
# сервер вешает поток загрузки навсегда — эфир встаёт и не переключается.
_TIMEOUT = (10, 60)

# Читаем файл кусками: shutil.copyfileobj(r.raw) не отдаёт управление между
# чанками, поэтому ни таймаут чтения, ни обрыв соединения не срабатывают.
_CHUNK_SIZE = 64 * 1024


def _cleanup(file_path: str) -> None:
    try:
        os.remove(file_path)
    except OSError:
        pass


def _check_downloaded_file(file_path: str, content_type: str) -> None:
    """Убедиться, что скачался непустой файл, а не пустышка или HTML-страница.

    Статус 200 ничего не гарантирует: muzofond.su на несуществующий трек
    отвечает «200 OK, Content-Type: audio/mpeg» с пустым телом. Такой файл
    плеер получает как трек и молча не играет.
    """
    try:
        size = os.path.getsize(file_path)
    except OSError:
        raise IOError(f"файл не создан: {file_path}")

    if size == 0:
        raise IOError("скачался пустой файл (0 байт)")

    if "text/html" in (content_type or "").lower():
        raise IOError(f"вместо аудио пришла страница ({content_type})")

    with open(file_path, "rb") as f:
        head = f.read(64)
    if head.lstrip()[:1] == b"<":
        raise IOError("вместо аудио пришёл HTML")


def download_file(url: str, file_path: str) -> None:
    """Скачать url в file_path. При ошибке — удалить недокачанный файл и
    пробросить исключение наверх.

    Молчаливое проглатывание ошибки здесь опаснее падения: вызывающий код
    (track.download) считает наличие файла на диске успешной загрузкой и
    отдаёт битый или HTML-ответ в плеер как трек.
    """
    try:
        with requests.get(
            url, headers=_HEADERS, stream=True, timeout=_TIMEOUT
        ) as r:
            r.raise_for_status()
            content_type = r.headers.get("Content-Type", "")
            with open(file_path, "wb") as f:
                for chunk in r.iter_content(chunk_size=_CHUNK_SIZE):
                    if chunk:
                        f.write(chunk)
        _check_downloaded_file(file_path, content_type)
    except Exception as e:
        logging.error(f"Download failed ({url}): {e}")
        _cleanup(file_path)
        raise
