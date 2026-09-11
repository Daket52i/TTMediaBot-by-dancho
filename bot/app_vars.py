from __future__ import annotations
import os
from typing import Callable, TYPE_CHECKING

if TYPE_CHECKING:
    from bot.translator import Translator

app_name = "TTMediaBot"
app_version = "4.0"
client_name = app_name + "-V" + app_version
about_text: Callable[[Translator], str] = lambda translator: translator.translate(
    """\
Hello! This is TTMediaBot — Russian Edition, a fork for TeamTalk 5.
Music: Muzofond and Hitmo (mp3). Video: Rutube. YouTube is not supported: it does not work from Russia.
Repository: https://github.com/Daket52i/TTMediaBot-by-dancho
Original Authors: Amir Gumerov, Vladislav Kopylov, Beqa Gozalishvili, Kirill Belousov.
"""
)
# Запасной сервис, если основной не поднялся. YouTube (yt/ytm) в боте
# отключён — из РФ он не работает, поэтому запасной путь ведёт на Rutube.
fallback_service = "rt"
loop_timeout = 0.01
max_message_length = 256
recents_max_lenth = 32
tt_event_timeout = 2

directory = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
