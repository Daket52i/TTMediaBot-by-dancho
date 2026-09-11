from __future__ import annotations
import html as _html
import json
import logging
import re
import time
from typing import Any, Dict, List, Optional, TYPE_CHECKING
from urllib.parse import quote

if TYPE_CHECKING:
    from bot import Bot

from bot.config.models import HitmoModel
from bot.player.enums import TrackType
from bot.player.track import Track
from bot.services import Service as _Service
from bot import errors

import httpx


# Старый hitster.fm закрылся, живое зеркало — rus.hitmos.fm. Выдача — Next.js:
# треки лежат в payload-чанках self.__next_f.push([1,"..."]) как JSON с
# экранированными кавычками. Внутри каждого трека есть "play" — прямой mp3
# вида https://pl1.hitmos.fm/<base64>.mp3, без токенов и региональных условий.
BASE_URL = "https://rus.hitmos.fm"
_SEARCH_URL = BASE_URL + "/search?q={query}"

# Один чанк Next.js: push([1,"<JS-строка с экранированием>"]). Внутренние
# кавычки/слеши распаковываются одним json.loads.
_CHUNK_RE = re.compile(r'self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)')
# Трек внутри распакованного payload: {"artist":"...","title":"...","play":"..."}
_TRACK_RE = re.compile(
    r'"artist":"((?:[^"\\]|\\.)*)","title":"((?:[^"\\]|\\.)*)"[^}]*?"play":"([^"]+)"'
)

_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
)


def _clean(text: Optional[str]) -> str:
    return _html.unescape(text or "").strip()


def _join_name(artist: str, title: str) -> str:
    if artist and artist not in title:
        return f"{artist} - {title}"
    return title or artist


def _payload(body: str) -> str:
    """Склеить все Next.js-чанки страницы в один распакованный payload."""
    parts = []
    for match in _CHUNK_RE.finditer(body):
        try:
            parts.append(json.loads('"' + match.group(1) + '"'))
        except Exception:
            continue
    return "".join(parts)


def parse_tracks(body: str, limit: int) -> List[Dict[str, Any]]:
    """Выдача Hitmo → список {url, title, artist}."""
    payload = _payload(body)
    tracks: List[Dict[str, Any]] = []
    seen: set = set()
    for artist, title, url in _TRACK_RE.findall(payload):
        if len(tracks) >= limit:
            break
        url = _clean(url)
        if not url or url in seen:
            continue
        seen.add(url)
        tracks.append({
            "url": url,
            "title": _clean(title),
            "artist": _clean(artist),
        })
    return tracks


class HitmoService(_Service):
    def __init__(self, bot: Bot, config: HitmoModel):
        self.bot = bot
        self.config = config
        self.name = "hitmo"
        # Домены сервиса: и сам сайт, и хосты, с которых отдаются файлы, —
        # по этому списку streamer решает, чей это URL.
        self.hostnames = [
            "rus.hitmos.fm",
            "hitmos.fm",
            "hitster.fm",
            "pl1.hitmos.fm",
            "pl2.hitmos.fm",
        ]
        self.is_enabled = self.config.enabled
        self.error_message = ""
        self.warning_message = ""
        self.help = ""
        self.hidden = False
        self._headers = {
            "User-Agent": _USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
            "Referer": BASE_URL + "/",
        }
        self._client: Optional[httpx.Client] = None

    def initialize(self):
        self._client = httpx.Client(
            headers=self._headers,
            follow_redirects=True,
            timeout=15.0,
        )
        logging.info("Hitmo Service initialized")

    def _get_client(self) -> httpx.Client:
        if self._client is None or self._client.is_closed:
            self._client = httpx.Client(
                headers=self._headers,
                follow_redirects=True,
                timeout=15.0,
            )
        return self._client

    def _fetch(self, url: str) -> str:
        resp = self._get_client().get(url)
        resp.raise_for_status()
        return resp.text

    def _search(self, query: str, limit: int) -> List[Dict[str, Any]]:
        q = quote((query or "").strip())
        if not q:
            return []
        return parse_tracks(self._fetch(_SEARCH_URL.format(query=q)), limit)

    def search(self, query: str, limit: Optional[int] = None) -> List[Track]:
        if limit is None:
            limit = self.config.search_results
        start_time = time.perf_counter()

        try:
            items = self._search(query, limit)
        except Exception as e:
            logging.error(f"Hitmo search failed: {e}")
            raise errors.NothingFoundError(str(e))

        if not items:
            raise errors.NothingFoundError("")

        tracks: List[Track] = []
        for item in items:
            url = item["url"]
            title = item["title"]
            artist = item["artist"]
            track = Track(
                service=self.name,
                url=url,
                name=_join_name(artist, title),
                format="mp3",
                type=TrackType.Default,
                extra_info={"stream_url": url, "title": title, "artist": artist},
                extracted_at=time.perf_counter(),
            )
            track._is_fetched = True
            tracks.append(track)

        elapsed = (time.perf_counter() - start_time) * 1000
        logging.info(f"Hitmo Search finished in {elapsed:.2f}ms for query: {query}")
        return tracks

    def get(
        self,
        url: str,
        extra_info: Optional[Dict[str, Any]] = None,
        process: bool = False,
    ) -> List[Track]:
        info = dict(extra_info or {})
        audio_url = info.get("stream_url") or url
        title = info.get("title", "")
        artist = info.get("artist", "")

        # Прямая ссылка на файл (её и отдаёт поиск) — забираем как есть.
        if audio_url.lower().split("?")[0].endswith(".mp3"):
            return [Track(
                service=self.name,
                url=audio_url,
                name=_join_name(artist, title) or audio_url.rsplit("/", 1)[-1],
                format="mp3",
                type=TrackType.Default,
                extra_info=info or {"stream_url": audio_url},
                extracted_at=time.perf_counter(),
            )]

        # Ссылка на страницу сайта — вытаскиваем первый трек со страницы.
        try:
            items = parse_tracks(self._fetch(url), 1)
        except Exception as e:
            raise errors.ServiceError(f"Hitmo: {e}")

        if not items:
            raise errors.ServiceError("Hitmo: на странице не найдено ни одного трека")

        item = items[0]
        return [Track(
            service=self.name,
            url=item["url"],
            name=_join_name(item["artist"], item["title"]),
            format="mp3",
            type=TrackType.Default,
            extra_info={
                "stream_url": item["url"],
                "title": item["title"],
                "artist": item["artist"],
            },
            extracted_at=time.perf_counter(),
        )]
