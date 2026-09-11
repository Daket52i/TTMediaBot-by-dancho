from __future__ import annotations

import logging
from typing import Any, Dict, List, Optional, TYPE_CHECKING
from urllib.parse import urlparse

if TYPE_CHECKING:
    from bot import Bot

from bot.config.models import YamModel
from bot.player.enums import TrackType
from bot.player.track import Track
from bot.services import Service
from bot import errors

# yandex_music ставится из requirements.txt (пакет yandex_music). Ловим
# ImportError здесь, чтобы отсутствие пакета на уже установленном сервере не
# роняло весь бот — сервис просто остаётся выключенным.
try:
    from yandex_music import Client
    from yandex_music.exceptions import UnauthorizedError, NetworkError
except ImportError:  # pragma: no cover - зависит от окружения
    Client = None
    UnauthorizedError = NetworkError = Exception


class YamService(Service):
    def __init__(self, bot: Bot, config: YamModel):
        self.bot = bot
        self.config = config
        self.name = "yam"
        self.hostnames = ["music.yandex.ru"]
        # Без пакета или без токена сервис не поднимается: Яндекс отдаёт музыку
        # только по токену аккаунта (и только с подпиской Плюс).
        self.is_enabled = bool(config.enabled and config.token and Client)
        if config.enabled and not config.token:
            self.error_message = "Не указан токен Яндекса (services.yam.token)"
        elif config.enabled and not Client:
            self.error_message = "Пакет yandex_music не установлен (pip install yandex_music)"
        else:
            self.error_message = ""
        self.warning_message = ""
        self.help = ""
        self.hidden = False
        # В апстриме тут ".mp3", из-за чего Track.download склеивал имя вида
        # «Исполнитель - Трек..mp3». Формат без точки, как у остальных сервисов.
        self.format = "mp3"

    def initialize(self):
        if not Client:
            raise errors.ServiceError(
                "Пакет yandex_music не установлен (pip install yandex_music)"
            )
        self.api = Client(token=self.config.token)
        try:
            self.api.init()
        except (UnauthorizedError, NetworkError) as e:
            logging.error(e)
            raise errors.ServiceError(e)
        if not self.api.account_status().account.uid:
            self.warning_message = self.bot.translator.translate(
                "Token is not provided"
            )
        elif not self.api.account_status().plus["has_plus"]:
            self.warning_message = self.bot.translator.translate(
                "You don't have Yandex Plus"
            )

    def get(
        self,
        url: str,
        extra_info: Optional[Dict[str, Any]] = None,
        process: bool = False,
    ) -> List[Track]:
        if not process:
            parsed_data = urlparse(url)
            path = parsed_data.path
            if "/album/" in path and "/track/" in path:
                split_path = path.split("/")
                real_id = split_path[4] + ":" + split_path[2]
                return self.get(None, extra_info={"track_id": real_id}, process=True)
            elif "/album/" in path:
                tracks = []
                album = self.api.albums_with_tracks(path.split("/")[2])
                if len(album.volumes) == 0 or len(album.volumes[0]) == 0:
                    raise errors.ServiceError()
                for volume in album.volumes:
                    for track in volume:
                        tracks.append(
                            Track(
                                service=self.name,
                                extra_info={"track_id": track.track_id},
                                type=TrackType.Dynamic,
                            )
                        )
                return tracks
            if "/artist/" in path:
                tracks = []
                artist_tracks = self.api.artists_tracks(path.split("/")[2]).tracks
                if len(artist_tracks) == 0:
                    raise errors.ServiceError()
                for track in artist_tracks:
                    tracks.append(
                        Track(
                            service=self.name,
                            extra_info={"track_id": track.track_id},
                            type=TrackType.Dynamic,
                        )
                    )
                return tracks
            elif "users" in path and "playlist" in path:
                tracks = []
                split_path = path.split("/")
                user_id = split_path[2]
                kind = split_path[4]
                playlist = self.api.users_playlists(kind=kind, user_id=user_id)
                if playlist.track_count == 0:
                    raise errors.ServiceError()
                for track in playlist.tracks:
                    tracks.append(
                        Track(
                            service=self.name,
                            extra_info={"track_id": track.track_id},
                            type=TrackType.Dynamic,
                        )
                    )
                return tracks
        else:
            track = self.api.tracks(extra_info["track_id"])[0]
            return [
                Track(
                    service=self.name,
                    name="{} - {}".format(
                        " & ".join(track.artists_name()), track.title
                    ),
                    url=track.get_download_info(get_direct_links=True)[0].direct_link,
                    type=TrackType.Default,
                    format=self.format,
                )
            ]

    def search(self, query: str, limit: Optional[int] = None) -> List[Track]:
        tracks: List[Track] = []
        found_tracks = self.api.search(text=query, nocorrect=True, type_="all").tracks
        if found_tracks:
            for track in found_tracks.results:
                tracks.append(
                    Track(
                        service=self.name,
                        type=TrackType.Dynamic,
                        extra_info={"track_id": track.track_id},
                    )
                )
                if limit and len(tracks) >= limit:
                    break
        found_podcast_episodes = self.api.search(
            text=query, nocorrect=True, type_="podcast_episode"
        ).podcast_episodes
        if found_podcast_episodes and not (limit and len(tracks) >= limit):
            for podcast_episode in found_podcast_episodes.results:
                tracks.append(
                    Track(
                        service=self.name,
                        type=TrackType.Dynamic,
                        extra_info={"track_id": podcast_episode.track_id},
                    )
                )
                if limit and len(tracks) >= limit:
                    break
        if tracks:
            return tracks
        else:
            raise errors.NothingFoundError("")
