from __future__ import annotations
import html as _html
import logging
import threading
import time
import re
from typing import Any, Dict, List, Optional, TYPE_CHECKING
from urllib.parse import quote

if TYPE_CHECKING:
    from bot import Bot

from bot.config.models import MfModel
from bot.player.enums import TrackType
from bot.player.track import Track
from bot.services import Service as _Service
from bot import errors

import httpx
from bs4 import BeautifulSoup


# muzofond.fm больше не отвечает (403), рабочий сайт — muzofond.su. Пробуем
# зеркала по порядку и запоминаем то, которое ответило.
_BASES = ("https://muzofond.su", "https://muzofond.fm")

# Разметка выдачи: <div class="item-track ..." data-file="//muzofond.su/stream/<base64>"
# data-track-title="..." data-artist="...">. Прямая ссылка на mp3 приходит в
# data-file без схемы (//host/...). Расширения .mp3 в ней нет — файл отдаётся
# через /stream/, поэтому проверять ссылку по "dl3s", как раньше, бесполезно:
# на живом сайте таких ссылок нет вообще.
_FILE_ATTR = "data-file"
_ARTIST_ATTR = "data-artist"
_TITLE_ATTR = "data-track-title"

# Старая разметка (до переезда): ссылка лежала в data-url и опознавалась по
# подстроке dl3s, название — текстом внутри элемента.
_LEGACY_URL_ATTR = "data-url"
_TIME_RE = re.compile(r"\s*\d{1,2}:\d{2}\s*$")
# Разделитель «исполнитель - название» только с пробелами вокруг тире: иначе
# «Jay-Z» разрезается пополам и превращается в двух исполнителей.
_DASH_SPLIT_RE = re.compile(r"\s+[—–-]\s+")

_AUDIO_PATTERNS = (
    r'(?:src|url|file)\s*[:=]\s*["\']?(https?://[^"\'>\s]+\.mp3[^"\'>\s]*)',
    r'(?:src|url|file)\s*[:=]\s*["\']?(https?://[^"\'>\s]+\.m4a[^"\'>\s]*)',
    r'audio[^>]*src\s*=\s*["\']?(https?://[^"\'>\s]+)',
)


def _clean(text: Optional[str]) -> str:
    return _html.unescape(text or "").strip()


def _absolute(url: Optional[str]) -> str:
    """Ссылка из разметки → абсолютная (там она приходит как //host/...)."""
    url = _clean(url)
    if url.startswith("//"):
        return "https:" + url
    return url


def _looks_like_audio(url: str) -> bool:
    """Ссылка ведёт на сам файл, а не на страницу трека.

    У muzofond.su прямой файл — это /stream/<base64> без расширения, поэтому
    проверки на .mp3 мало; dl3s оставлен для старой разметки.
    """
    if not url:
        return False
    low = url.lower()
    return (
        "dl3s" in low
        or "/stream/" in low
        or low.endswith((".mp3", ".m4a", ".aac", ".ogg"))
    )


def _split_artist_title(text: str) -> tuple[str, str]:
    """«Исполнитель - Название» → (исполнитель, название)."""
    text = _clean(_TIME_RE.sub("", text))
    parts = _DASH_SPLIT_RE.split(text, maxsplit=1)
    if len(parts) == 2:
        return parts[0].strip(), parts[1].strip()
    return "", text


def parse_items(body: str, limit: int) -> List[Dict[str, Any]]:
    """Разобрать страницу выдачи в список {url, title, artist}."""
    soup = BeautifulSoup(body, "html.parser")
    tracks: List[Dict[str, Any]] = []
    seen: set = set()

    # Новая разметка: всё нужное лежит в атрибутах элемента трека.
    for tag in soup.select(f"[{_FILE_ATTR}]"):
        if len(tracks) >= limit:
            break
        url = _absolute(tag.get(_FILE_ATTR))
        if not _looks_like_audio(url) or url in seen:
            continue
        seen.add(url)
        artist = _clean(tag.get(_ARTIST_ATTR))
        title = _clean(tag.get(_TITLE_ATTR))
        if not title and not artist:
            artist, title = _split_artist_title(tag.get_text(" ", strip=True))
        tracks.append({"url": url, "title": title or "Unknown", "artist": artist})
    if tracks:
        return tracks

    # Старая разметка (на случай, если зеркало отдаст прежний дизайн).
    for tag in soup.select(f"[{_LEGACY_URL_ATTR}]"):
        if len(tracks) >= limit:
            break
        url = _absolute(tag.get(_LEGACY_URL_ATTR))
        if not _looks_like_audio(url) or url in seen:
            continue
        seen.add(url)
        artist, title = _split_artist_title(tag.get_text(" ", strip=True))
        tracks.append({"url": url, "title": title or "Unknown", "artist": artist})

    return tracks


def _join_name(artist: str, title: str) -> str:
    if artist and artist not in title:
        return f"{artist} - {title}"
    return title


class MfService(_Service):
    def __init__(self, bot: Bot, config: MfModel):
        self.bot = bot
        self.config = config
        self.name = "mf"
        self.hostnames = ["muzofond.su", "www.muzofond.su", "muzofond.fm", "www.muzofond.fm"]
        self.is_enabled = self.config.enabled
        self.error_message = ""
        self.warning_message = ""
        self.help = ""
        self.hidden = False
        self._headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
            "Referer": _BASES[0] + "/",
        }
        self._client: Optional[httpx.Client] = None
        self._base = _BASES[0]

    def initialize(self):
        self._client = httpx.Client(
            headers=self._headers,
            follow_redirects=True,
            timeout=15.0,
        )
        logging.info("Muzofond Service initialized")

    def _get_client(self) -> httpx.Client:
        if self._client is None or self._client.is_closed:
            self._client = httpx.Client(
                headers=self._headers,
                follow_redirects=True,
                timeout=15.0,
            )
        return self._client

    def _request(self, path: str) -> httpx.Response:
        """GET по пути с перебором зеркал. Возвращает первый успешный ответ.

        Живое зеркало запоминается в self._base и пробуется первым — иначе
        каждый запрос снова упирался бы в мёртвый muzofond.fm.
        """
        last_error: Optional[Exception] = None
        for base in (self._base,) + tuple(b for b in _BASES if b != self._base):
            try:
                resp = self._get_client().get(
                    base + path, headers={"Referer": base + "/"}
                )
                if resp.status_code == 200:
                    self._base = base
                    return resp
                last_error = errors.ServiceError(
                    f"Muzofond: HTTP {resp.status_code} ({base})"
                )
            except Exception as e:
                last_error = e
        raise last_error or errors.ServiceError("Muzofond: сервис недоступен")

    def _parse_search_page(self, html: str, limit: int) -> List[Dict[str, Any]]:
        return parse_items(html, limit)

    def _extract_audio_url(self, page_url: str) -> Optional[str]:
        page_url = _absolute(page_url)
        client = self._get_client()
        try:
            resp = client.get(page_url)
            resp.raise_for_status()
            html = resp.text
        except Exception as e:
            logging.error(f"Muzofond page fetch failed: {e}")
            return None

        items = parse_items(html, 1)
        if items:
            return items[0]["url"]

        for pattern in _AUDIO_PATTERNS:
            match = re.search(pattern, html, re.IGNORECASE)
            if match:
                return match.group(1).rstrip("'\"")

        soup = BeautifulSoup(html, "html.parser")
        audio = soup.select_one("audio")
        if audio:
            src = audio.get("src", "")
            if not src:
                source = audio.select_one("source")
                if source:
                    src = source.get("src", "")
            if src:
                return _absolute(src)

        return None

    def search(self, query: str, limit: Optional[int] = None) -> List[Track]:
        if limit is None:
            limit = self.config.search_results
        start_time = time.perf_counter()

        q = quote((query or "").strip())
        if not q:
            raise errors.NothingFoundError("")

        # Запрос уходит в путь URL: без экранирования пробелы и «&» ломают
        # адрес, а кириллица уходит в сеть в неверной кодировке.
        try:
            resp = self._request(f"/search/{q}")
        except Exception as e:
            logging.error(f"Muzofond search failed: {e}")
            raise errors.NothingFoundError(str(e))

        raw_tracks = self._parse_search_page(resp.text, limit)
        if not raw_tracks:
            raise errors.NothingFoundError("")

        tracks: List[Track] = []
        for item in raw_tracks:
            url = item.get("url", "")
            title = item.get("title", "")
            artist = item.get("artist", "")
            full_title = _join_name(artist, title)

            track = Track(
                service=self.name,
                url=url,
                name=full_title,
                format="mp3",
                type=TrackType.Default,
                extra_info={"stream_url": url, "title": title, "artist": artist},
                extracted_at=time.perf_counter(),
            )
            track._is_fetched = True
            tracks.append(track)

        elapsed = (time.perf_counter() - start_time) * 1000
        logging.info(f"Muzofond Search finished in {elapsed:.2f}ms for query: {query}")
        return tracks

    def get(
        self,
        url: str,
        extra_info: Optional[Dict[str, Any]] = None,
        process: bool = False,
    ) -> List[Track]:
        start_time = time.perf_counter()

        info = dict(extra_info or {})
        page_url = info.get("page_url") or url

        stream_url = _absolute(info.get("stream_url", ""))
        if _looks_like_audio(stream_url):
            audio_url = stream_url
        elif _looks_like_audio(url):
            audio_url = _absolute(url)
        else:
            audio_url = ""

        title = info.get("title", "")
        artist = info.get("artist", "")
        full_title = _join_name(artist, title)

        if process:
            if not audio_url:
                audio_url = self._extract_audio_url(page_url)
            if not audio_url:
                raise errors.ServiceError("Muzofond: Could not extract audio URL")

            elapsed = (time.perf_counter() - start_time) * 1000
            logging.info(f"Muzofond Get (Process) finished in {elapsed:.2f}ms for {full_title}")

            return [
                Track(
                    service=self.name,
                    url=audio_url,
                    name=full_title or "Muzofond Track",
                    format="mp3",
                    type=TrackType.Default,
                    extra_info=info,
                    extracted_at=time.perf_counter(),
                )
            ]

        if audio_url:
            return [Track(
                service=self.name,
                url=audio_url,
                name=title,
                format="mp3",
                type=TrackType.Default,
                extra_info=info,
                extracted_at=time.perf_counter(),
            )]

        track = Track(
            service=self.name,
            url=page_url,
            name=title,
            type=TrackType.Dynamic,
            extra_info=info or {"page_url": page_url},
        )

        elapsed = (time.perf_counter() - start_time) * 1000
        logging.info(f"Muzofond Get (Dynamic) finished in {elapsed:.2f}ms for {page_url}")
        return [track]

    def _fetch_autoplay_async(self, track_id: str) -> None:
        threading.Thread(
            target=self._fetch_autoplay_sync,
            args=(track_id,),
            daemon=True,
            name=f"MF_Autoplay_{track_id}",
        ).start()

    def _fetch_autoplay_sync(self, track_id: str) -> bool:
        try:
            info = {}
            for t in reversed(self.bot.player.track_list):
                ei = getattr(t, "extra_info", None) or {}
                if ei.get("stream_url", "") == track_id or ei.get("page_url", "") == track_id:
                    info = ei
                    break

            artist = info.get("artist", "")
            title = info.get("title", "")
            if not artist and not title:
                return False

            query = quote(f"{artist} {title}".strip())
            try:
                resp = self._request(f"/search/{query}")
            except Exception as e:
                logging.debug(f"[MF] Autoplay search error: {e}")
                return False

            existing_urls = set()
            for t in self.bot.player.track_list:
                ei = getattr(t, "extra_info", None) or {}
                u = ei.get("stream_url", "")
                if u:
                    existing_urls.add(u)

            new_tracks = []
            for item in parse_items(resp.text, self.config.search_results):
                url = item.get("url", "")
                if not url or url in existing_urls:
                    continue
                t_artist = item.get("artist", "")
                t_title = item.get("title", "")
                full_title = _join_name(t_artist, t_title)

                new_track = Track(
                    service=self.name,
                    url=url,
                    name=full_title,
                    format="mp3",
                    type=TrackType.Default,
                    extra_info={"stream_url": url, "title": t_title, "artist": t_artist},
                    extracted_at=time.perf_counter(),
                )
                new_track._is_fetched = True
                new_tracks.append(new_track)
                existing_urls.add(url)

            if new_tracks:
                self.bot.player.track_list.extend(new_tracks)
                logging.info(f"[MF] Added {len(new_tracks)} autoplay tracks (total: {len(self.bot.player.track_list)})")
                return True

        except Exception as e:
            logging.debug(f"[MF] Autoplay error: {e}")
        return False

    def download(self, track: Track, file_path: str, video: bool = False) -> None:
        import downloader

        info = track.extra_info or {}
        audio_url = _absolute(info.get("stream_url", ""))

        if not _looks_like_audio(audio_url):
            page_url = info.get("page_url") or track.url
            audio_url = self._extract_audio_url(page_url)

        if not _looks_like_audio(audio_url):
            audio_url = _absolute(track.url)

        if not audio_url:
            raise errors.ServiceError("Muzofond: нечего скачивать — пустая ссылка")

        downloader.download_file(audio_url, file_path)
