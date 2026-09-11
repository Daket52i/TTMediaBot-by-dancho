from __future__ import annotations
import logging
import time
import re
from typing import Any, Dict, List, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from bot import Bot

from bot.config.models import MfModel
from bot.player.enums import TrackType
from bot.player.track import Track
from bot.services import Service as _Service
from bot import errors

import httpx
from bs4 import BeautifulSoup


class MfService(_Service):
    def __init__(self, bot: Bot, config: MfModel):
        self.bot = bot
        self.config = config
        self.name = "mf"
        self.hostnames = ["muzofond.fm", "www.muzofond.fm"]
        self.is_enabled = self.config.enabled
        self.error_message = ""
        self.warning_message = ""
        self.help = ""
        self.hidden = False
        self._headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
            "Referer": "https://muzofond.fm/",
        }
        self._client: Optional[httpx.Client] = None

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

    def _parse_search_page(self, html: str, limit: int) -> List[Dict[str, Any]]:
        soup = BeautifulSoup(html, "html.parser")
        tracks: List[Dict[str, Any]] = []

        items_by_id = {}
        for item in soup.select("li[data-id]"):
            did = item.get("data-id", "")
            if did not in items_by_id:
                items_by_id[did] = []
            items_by_id[did].append(item)

        for did, elems in items_by_id.items():
            if len(tracks) >= limit:
                break
            url = ""
            title_text = ""
            for el in elems:
                u = el.get("data-url", "")
                if u and "dl3s" in u:
                    url = u
                t = el.get_text(strip=True)
                if t:
                    title_text = t
            if not url:
                continue

            parts = re.split(r"\u2014|\u2013|-", title_text, maxsplit=1)
            artist = parts[0].strip() if len(parts) > 1 else ""
            title = parts[1].strip() if len(parts) > 1 else title_text.strip()

            time_match = re.search(r"(\d{1,2}:\d{2})$", title)
            if time_match:
                title = title[:time_match.start()].strip()

            full_title = f"{artist} - {title}" if artist and artist not in title else title

            tracks.append({
                "title": full_title or "Unknown",
                "url": url,
                "artist": artist,
            })

        if not tracks:
            for tag in soup.select("[data-url]"):
                url = tag.get("data-url", "")
                if url and "dl3s" in url:
                    title = tag.get_text(strip=True)
                    tracks.append({
                        "title": title or "Unknown",
                        "url": url,
                        "artist": "",
                    })

        return tracks[:limit]

    def _extract_audio_url(self, page_url: str) -> Optional[str]:
        client = self._get_client()
        try:
            resp = client.get(page_url)
            resp.raise_for_status()
            html = resp.text
        except Exception as e:
            logging.error(f"Muzofond page fetch failed: {e}")
            return None

        patterns = [
            r'(?:src|url|file)\s*[:=]\s*["\']?(https?://[^"\'>\s]+\.mp3[^"\'>\s]*)',
            r'(?:src|url|file)\s*[:=]\s*["\']?(https?://[^"\'>\s]+\.m4a[^"\'>\s]*)',
            r'(?:src|url|file)\s*[:=]\s*["\']?(https?://[^"\'>\s]+audio[^"\'>\s]*)',
            r'audio[^>]*src\s*=\s*["\']?(https?://[^"\'>\s]+)',
        ]
        for pattern in patterns:
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
                return src

        return None

    def search(self, query: str, limit: Optional[int] = None) -> List[Track]:
        if limit is None:
            limit = self.config.search_results
        start_time = time.perf_counter()

        client = self._get_client()
        try:
            resp = client.get(f"https://muzofond.fm/search/{query}")
            resp.raise_for_status()
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
            full_title = f"{artist} - {title}" if artist and artist not in title else title

            if item.get("is_page"):
                track = Track(
                    service=self.name,
                    url=url,
                    name=full_title,
                    type=TrackType.Dynamic,
                    extra_info={"page_url": url, "title": title, "artist": artist},
                )
            else:
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

        stream_url = info.get("stream_url", "")
        if stream_url and "dl3s" in stream_url:
            audio_url = stream_url
        elif url and "dl3s" in url:
            audio_url = url
        else:
            audio_url = ""

        if process:
            if not audio_url:
                audio_url = self._extract_audio_url(page_url)
            if not audio_url:
                raise errors.ServiceError("Muzofond: Could not extract audio URL")

            title = info.get("title", "")
            artist = info.get("artist", "")
            full_title = f"{artist} - {title}" if artist and artist not in title else title

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
                name=info.get("title", ""),
                format="mp3",
                type=TrackType.Default,
                extra_info=info,
                extracted_at=time.perf_counter(),
            )]

        track = Track(
            service=self.name,
            url=page_url,
            name=info.get("title", ""),
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

            query = f"{artist} {title}" if artist else title
            client = self._get_client()
            resp = client.get(f"https://muzofond.fm/search/{query}")
            resp.raise_for_status()

            from bs4 import BeautifulSoup
            soup = BeautifulSoup(resp.text, "html.parser")

            items_by_id = {}
            for item in soup.select("li[data-id]"):
                did = item.get("data-id", "")
                if did not in items_by_id:
                    items_by_id[did] = []
                items_by_id[did].append(item)

            existing_urls = set()
            for t in self.bot.player.track_list:
                ei = getattr(t, "extra_info", None) or {}
                u = ei.get("stream_url", "")
                if u:
                    existing_urls.add(u)

            new_tracks = []
            for did, elems in items_by_id.items():
                url = ""
                title_text = ""
                for el in elems:
                    u = el.get("data-url", "")
                    if u and "dl3s" in u:
                        url = u
                    t = el.get_text(strip=True)
                    if t:
                        title_text = t
                if not url or url in existing_urls:
                    continue

                parts = re.split(r"\u2014|\u2013|-", title_text, maxsplit=1)
                t_artist = parts[0].strip() if len(parts) > 1 else ""
                t_title = parts[1].strip() if len(parts) > 1 else title_text.strip()

                time_match = re.search(r"(\d{1,2}:\d{2})$", t_title)
                if time_match:
                    t_title = t_title[:time_match.start()].strip()

                full_title = f"{t_artist} - {t_title}" if t_artist and t_artist not in t_title else t_title

                new_tracks.append(Track(
                    service=self.name,
                    url=url,
                    name=full_title,
                    format="mp3",
                    type=TrackType.Default,
                    extra_info={"stream_url": url, "title": t_title, "artist": t_artist},
                    extracted_at=time.perf_counter(),
                ))
                new_tracks[-1]._is_fetched = True
                existing_urls.add(url)

            if new_tracks:
                self.bot.player.track_list.extend(new_tracks)
                logging.info(f"[MF] Added {len(new_tracks)} autoplay tracks (total: {len(self.bot.player.track_list)})")
                return True

        except Exception as e:
            logging.debug(f"[MF] Autoplay error: {e}")
        return False

    def download(self, track: Track, file_path: str, video: bool = False) -> None:
        info = track.extra_info or {}
        audio_url = info.get("stream_url", "")

        if not audio_url:
            page_url = info.get("page_url") or track.url
            audio_url = self._extract_audio_url(page_url)

        if audio_url:
            downloader = __import__("downloader")
            downloader.download_file(audio_url, file_path)
        else:
            downloader = __import__("downloader")
            downloader.download_file(track.url, file_path)
