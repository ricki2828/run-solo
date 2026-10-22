"""Channel adapters behind one interface. Buttons are defined by the server, never by the LLM."""
from __future__ import annotations

import hashlib
import html
import hmac
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse

import httpx

import json
import re

from .config import Settings
from .media import PHOTO_MAX_BYTES, VIDEO_MAX_BYTES, Media

CAPTION_MAX = 1024        # Telegram caption limit
QUESTION_LEAD = "Quick question"  # follow-up text for question buttons; the card text already went with the media
MAX_TEXT = 4096           # inbound text kept: above the 500-character note limit so the service can refuse a long note
MAX_FEEL_BUTTONS = 3      # per card (the 10-Oct review); questions never ride a media card


_MEDIA_WORDS = re.compile(r"photo|video|file|image|media|dimension|too big|too large", re.I)


def _media_rejected(status: int, description: Any) -> bool:
    """True only when Telegram refused the upload itself (413, or a 400 whose description is about the file).
    Any other 400 (chat not found, bad markup) is not a media problem and must not trigger a text fallback."""
    if status == 413:
        return True
    return status == 400 and isinstance(description, str) and bool(_MEDIA_WORDS.search(description))


def utf16_len(text: str) -> int:
    """Telegram counts caption length in UTF-16 code units."""
    return len(text.encode("utf-16-le")) // 2


class ChannelError(Exception):
    def __init__(self, msg: str, *, permanent: bool = False, status: int | None = None, description: str = "",
                 retry_after: float | None = None, ambiguous: bool = False):
        super().__init__(msg)
        self.permanent = permanent  # the content was refused (bad media): retrying the same bytes will not help
        self.status = status
        self.description = description.lower()
        self.retry_after = retry_after  # Telegram 429: seconds to wait before the next call
        # The request may have been delivered although we did not see the answer (timeout, dropped connection, a 5xx).
        # A caller that must not send twice (check-in slots) leaves its claim in place instead of retrying.
        self.ambiguous = ambiguous

    @property
    def rate_limited(self) -> bool:
        return self.status == 429

    @property
    def not_modified(self) -> bool:
        """The edit asked for what the message already shows. That is success."""
        return self.status == 400 and "not modified" in self.description

    @property
    def cant_edit(self) -> bool:
        """The message to edit is gone (deleted by the runner), too old, or not that kind of message."""
        return self.status == 400 and any(w in self.description for w in (
            "not found", "can't be edited", "no text in the message", "no caption in the message",
            "message_id_invalid", "message identifier"))


@dataclass(frozen=True)
class OutCard:
    card_id: str
    headline: str
    body: str
    buttons: list[dict]  # [{"label": str, "action": str, "row": int}] ; callback = f"{card_id}:{index}"
    media: Media | None = None
    links: tuple[tuple[str, str], ...] = ()  # (label, https url): deep-link buttons
    neutral_caption: str = ""  # with a spoilered photo: the caption that gives nothing away (the coach line follows as its own message)
    short_caption: bool = False  # a picture carries the numbers: the caption is the headline and one line of judgement


_COMPARISON = re.compile(r"\b(faster|slower|level with|than (?:your )?last|no real change)\b", re.I)
_SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")
_NOTED = re.compile(r"^Noted[.:]")   # a late note's acknowledgement (service._late_edit) rides the caption too


_NEXT = re.compile(r"^Next: ")


def caption_text(card: OutCard) -> str:
    """The text a picture rides with. A short-caption card (a run card) keeps its headline, the judgement (the last
    ordinary sentence of the first paragraph: the coaching), the Next line and a late note's "Noted" line, plus any
    comparison sentence and any later paragraph (a personal touch or a quoted note). Within the caption limit the
    comparisons go first, then the later paragraph; the headline, judgement and Next line are never dropped."""
    if not card.short_caption:
        return f"{card.headline}\n{card.body}"
    first, _, rest = card.body.partition("\n\n")
    sentences = [x for x in _SENTENCE_SPLIT.split(first.strip()) if x]
    plain = [i for i, x in enumerate(sentences) if not (_NEXT.match(x) or _NOTED.match(x))]
    judgement = plain[-1] if plain else None
    # the sentences before the judgement mostly restate the numbers the picture shows: only a comparison stays, and goes
    # first when the caption is too long, then the later paragraph; the judgement and the Next line never go
    others = [i for i in plain if i != judgement and _COMPARISON.search(sentences[i])]
    droppable = [("sent", i) for i in others][::-1] + ([("rest", None)] if rest.strip() else [])
    keep = {i for i in range(len(sentences)) if i not in plain or i == judgement or i in others}
    use_rest = bool(rest.strip())

    def render() -> str:
        lines = [card.headline.strip(), " ".join(sentences[i] for i in sorted(keep))]
        if use_rest:
            lines.append(rest.strip())
        return "\n".join(x for x in lines if x)

    for kind, i in droppable:
        if utf16_len(render()) <= CAPTION_MAX:
            break
        if kind == "rest":
            use_rest = False
        else:
            keep.discard(i)
    return render()


def photo_caption(card: OutCard) -> str:
    """What a photo rides with. A spoilered photo carries only the neutral line: the verdict must stay behind the tap."""
    if card.media and card.media.spoiler and card.neutral_caption:
        return card.neutral_caption
    return caption_text(card)


@dataclass(frozen=True)
class Inbound:
    channel: str
    ref: str  # chat id / wa number; used only to look the user up, never logged
    msg_id: str  # dedupe key
    text: str = ""
    card_id: str | None = None
    button_idx: int | None = None
    callback_id: str | None = None
    callback_message_id: str | None = None
    name: str = ""  # display name or @username of the sender, never the id
    code: str | None = None  # a check-in button: its code (checkins.CODES), with card_id; no button_idx


CHECKIN_PREFIX = "ci1:"   # `ci1:<card id>:<code>`; the code names its stage, so a stale tap cannot be misread


def checkin_data(card_id: str, code: str) -> str:
    return f"{CHECKIN_PREFIX}{card_id}:{code}"


def parse_checkin_callback(data: str) -> tuple[str, str] | None:
    if not data.startswith(CHECKIN_PREFIX):
        return None
    card_id, sep, code = data[len(CHECKIN_PREFIX):].partition(":")
    if not sep or not card_id.isalnum() or len(card_id) > 64 or not code.replace(".", "").isalnum() or len(code) > 12:
        return None
    return card_id, code


def parse_callback(data: str) -> tuple[str, int] | None:
    card_id, sep, idx = data.partition(":")
    if not sep or not card_id.isalnum() or not idx.isdigit() or len(card_id) > 64:
        return None
    return card_id, int(idx)


# --- Telegram -------------------------------------------------------------------------------

class TelegramChannel:
    name = "telegram"

    def __init__(self, s: Settings, http: httpx.Client):
        self.s, self.http = s, http

    def _call(self, method: str, payload: dict, files: dict | None = None) -> dict:
        """JSON call, or multipart when `files` is given (uploads send the rendered bytes, never a public URL)."""
        url = f"{self.s.telegram_api}/bot{self.s.telegram_token}/{method}"
        try:
            if files:
                r = self.http.post(url, data={k: str(v) for k, v in payload.items()}, files=files, timeout=60)
            else:
                r = self.http.post(url, json=payload, timeout=10)
        except httpx.HTTPError as e:
            raise ChannelError(f"telegram transport: {type(e).__name__}", ambiguous=True) from None
        try:
            data = r.json()
        except ValueError:
            data = {}
        if not isinstance(data, dict):
            data = {}
        if r.status_code != 200 or not data.get("ok"):
            desc = data.get("description") if isinstance(data.get("description"), str) else ""
            params = data.get("parameters") if isinstance(data.get("parameters"), dict) else {}
            ra = params.get("retry_after")
            raise ChannelError(f"telegram {method}: http {r.status_code}",
                               permanent=_media_rejected(r.status_code, desc), status=r.status_code, description=desc,
                               retry_after=float(ra) if isinstance(ra, (int, float)) and not isinstance(ra, bool) else None,
                               ambiguous=r.status_code >= 500 or r.status_code == 200)
        return data

    def send_text(self, ref: str, text: str) -> str:
        d = self._call("sendMessage", {"chat_id": int(ref), "text": text})
        return str(d["result"]["message_id"])

    def send_typing(self, ref: str) -> None:
        """"typing..." in the chat for about 5 seconds, while the coach works on a reply."""
        self._call("sendChatAction", {"chat_id": int(ref), "action": "typing"})

    @staticmethod
    def _keyboard(card: OutCard, media: bool) -> list[list[dict]]:
        """Callback buttons by row, then one row of deep-link buttons. Callback index = position in card.buttons.

        A media card carries at most 3 feel buttons and never a question: questions go as their own message."""
        rows: dict[int, list[dict]] = {}
        feel = 0
        for i, b in enumerate(card.buttons):
            if b.get("hidden"):   # off screen, but its index (the callback data) stays
                continue
            if media:
                if b["action"].startswith("ans:"):
                    continue
                if b["action"].startswith("feel:"):
                    feel += 1
                    if feel > MAX_FEEL_BUTTONS:
                        continue
            rows.setdefault(b.get("row", 0), []).append({"text": b["label"][:40], "callback_data": f"{card.card_id}:{i}"})
        out = [rows[k] for k in sorted(rows)]
        links = [{"text": label[:40], **({"web_app": {"url": url}} if urlparse(url).path.startswith("/miniapp") else {"url": url})}
                 for label, url in card.links if url.startswith("https://")]
        if links:
            out.append(links[:2])
        return out

    def send_card(self, ref: str, card: OutCard, **_: Any) -> str:
        text = "\n".join(x for x in (card.headline, card.body) if x)
        if card.media and card.media.has_content:
            return self._send_media(ref, card, photo_caption(card))
        payload: dict[str, Any] = {"chat_id": int(ref), "text": text}
        kb = self._keyboard(card, media=False)
        if kb:
            payload["reply_markup"] = {"inline_keyboard": kb}
        return str(self._call("sendMessage", payload)["result"]["message_id"])

    @staticmethod
    def followups(card: OutCard) -> list[str]:
        """Messages a media card needs after the media itself: "caption" when the text does not fit a caption (the
        buttons ride that text), "question" when question buttons were kept off the media."""
        if not (card.media and card.media.has_content):
            return []
        if card.media.spoiler and card.neutral_caption:
            # the coach line (the verdict) goes as its own message after the photo; question buttons follow as before
            return ["coach_line"] + (["question"] if any(b["action"].startswith("ans:") for b in card.buttons) else [])
        if utf16_len(caption_text(card)) > CAPTION_MAX:
            return ["caption"]  # the text goes once, with every button, questions included
        if any(b["action"].startswith("ans:") for b in card.buttons):
            return ["question"]  # the body already rode the caption, so this carries only the question buttons
        return []

    def send_followup(self, ref: str, card: OutCard, mode: str) -> str:
        """The text message a media card could not carry. Sent from its own outbox item, so a failure here retries
        only this message and never re-uploads the media."""
        if mode == "touch_card":
            # The second picture a milestone or countdown earned: media only, no buttons. A replay's context line is the
            # only text it may carry.
            text = "\n".join(x for x in (card.headline.strip(), card.body.strip()) if x)
            if not (card.media and card.media.photo):
                raise ChannelError("touch card without a photo", permanent=True)
            return self._send_media(ref, OutCard(card.card_id, card.headline, card.body, [], card.media, ()), text)
        if mode == "coach_line":
            # the verdict sits behind a spoiler, so neither the chat nor the notification preview shows it
            payload = {"chat_id": int(ref), "parse_mode": "HTML",
                       "text": "<tg-spoiler>" + html.escape(f"{card.headline}\n{card.body}", quote=False) + "</tg-spoiler>"}
            try:
                return str(self._call("sendMessage", payload)["result"]["message_id"])
            except ChannelError as e:
                if e.status != 400 or "parse" not in e.description:
                    raise
                # Telegram refused the markup (a 400 parse error): the line still goes, as plain text
                return str(self._call("sendMessage", {"chat_id": int(ref), "text": f"{card.headline}\n{card.body}"})["result"]["message_id"])
        elif mode == "caption":
            text, kb = f"{card.headline}\n{card.body}", self._keyboard(card, media=False)
        elif mode == "question":
            text = QUESTION_LEAD
            kb = [[{"text": b["label"][:40], "callback_data": f"{card.card_id}:{i}"}]
                  for i, b in enumerate(card.buttons) if b["action"].startswith("ans:")]
        else:
            raise ValueError("unknown follow-up")
        payload: dict[str, Any] = {"chat_id": int(ref), "text": text}
        if kb:
            payload["reply_markup"] = {"inline_keyboard": kb}
        return str(self._call("sendMessage", payload)["result"]["message_id"])

    def _send_media(self, ref: str, card: OutCard, text: str) -> str:
        """sendVideo for a moment (falls back to its still), else sendPhoto, and nothing else: one call that delivers.
        A caption over 1024 chars goes without caption or buttons, and `followups` says what must follow. Raises
        ChannelError(permanent=True) when every upload is refused as media."""
        m = card.media
        assert m is not None
        kb = self._keyboard(card, media=True)
        fits = utf16_len(text) <= CAPTION_MAX
        fields: dict[str, Any] = {"chat_id": int(ref)}
        if fits and text:
            fields["caption"] = text
            if kb:
                fields["reply_markup"] = json.dumps({"inline_keyboard": kb})
        attempts: list[tuple[str, dict, dict | None]] = []
        if m.animation and (m.animation_file_id or (m.video and len(m.video) <= VIDEO_MAX_BYTES)):
            # sendAnimation autoplays and loops in the chat (and a forward keeps it); the spoiler is tried first and dropped on refusal
            anim = {"width": m.width, "height": m.height, "duration": m.duration_s}
            for spoiler in ((True, False) if m.spoiler else (False,)):
                extra = {"has_spoiler": "true"} if spoiler else {}
                if m.animation_file_id:   # an id Telegram already holds: a JSON call, no upload
                    body = {"chat_id": int(ref), "animation": m.animation_file_id, **anim, **({"has_spoiler": True} if spoiler else {})}
                    if "caption" in fields:
                        body["caption"] = fields["caption"]
                        if kb:
                            body["reply_markup"] = {"inline_keyboard": kb}
                    attempts.append(("sendAnimation", body, None))
                else:
                    up = {"animation": ("moment.mp4", m.video, "video/mp4")}
                    if m.thumbnail:   # the still card, shown before the loop plays
                        up["thumbnail"] = ("thumb.jpg", m.thumbnail, "image/jpeg")
                    attempts.append(("sendAnimation", {**fields, **anim, **extra}, up))
        elif m.video and len(m.video) <= VIDEO_MAX_BYTES:
            attempts.append(("sendVideo", {**fields, "supports_streaming": "true", "width": m.width, "height": m.height,
                                           "duration": m.duration_s, **({"has_spoiler": "true"} if m.spoiler else {})},
                             {"video": ("run.mp4", m.video, "video/mp4")}))
        if m.photo and len(m.photo) <= PHOTO_MAX_BYTES:
            if m.spoiler:   # a tap to reveal; a refusal falls back to the plain photo below
                attempts.append(("sendPhoto", {**fields, "has_spoiler": "true"}, {"photo": ("card.png", m.photo, "image/png")}))
            attempts.append(("sendPhoto", fields, {"photo": ("card.png", m.photo, "image/png")}))
        if not attempts:
            raise ChannelError("telegram media over the size limit", permanent=True)
        last: ChannelError | None = None
        for method, payload, files in attempts:
            try:
                result = self._call(method, payload, files)["result"]
                if method == "sendAnimation":   # kept by the service so a repeat send is one id, not another upload
                    fid = (result.get("animation") or {}).get("file_id")
                    if isinstance(fid, str) and fid:
                        m.sent["file_id"] = fid
                return str(result["message_id"])
            except ChannelError as e:
                if not e.permanent:
                    raise
                last = e
        assert last is not None
        raise last

    def ack_callback(self, inb: Inbound, text: str, clear: bool = True, keep: list[tuple[str, int]] | None = None) -> None:
        """Toast the tap. `clear` removes the card's buttons; `keep` (label, index) leaves just those behind."""
        try:
            self._call("answerCallbackQuery", {"callback_query_id": inb.callback_id, "text": text})
            if clear and inb.callback_message_id:
                kb = [[{"text": label[:40], "callback_data": f"{inb.card_id}:{i}"} for label, i in keep]] if keep else []
                self._call("editMessageReplyMarkup", {
                    "chat_id": int(inb.ref), "message_id": int(inb.callback_message_id),
                    "reply_markup": {"inline_keyboard": kb}})
        except ChannelError:
            pass  # cosmetic only

    # ---- check-ins: plain messages the coach starts and then edits in place (service.checkins) ----
    @staticmethod
    def checkin_markup(card_id: str, keyboard: list[list[tuple[str, str]]]) -> dict:
        return {"inline_keyboard": [[{"text": label[:40], "callback_data": checkin_data(card_id, code)}
                                     for label, code in row] for row in keyboard]}

    def send_checkin(self, ref: str, card_id: str, text: str, keyboard: list[list[tuple[str, str]]],
                     media: Media | None = None) -> tuple[str, bool]:
        """-> (message id, is a photo). A photo when the renderer supplied one and the text fits a caption."""
        markup = self.checkin_markup(card_id, keyboard) if keyboard else None
        if media and media.photo and len(media.photo) <= PHOTO_MAX_BYTES and utf16_len(text) <= CAPTION_MAX:
            fields: dict[str, Any] = {"chat_id": int(ref), "caption": text}
            if markup:
                fields["reply_markup"] = json.dumps(markup)
            try:
                return str(self._call("sendPhoto", fields, {"photo": ("card.png", media.photo, "image/png")})
                           ["result"]["message_id"]), True
            except ChannelError as e:
                if not e.permanent:
                    raise
        payload: dict[str, Any] = {"chat_id": int(ref), "text": text}
        if markup:
            payload["reply_markup"] = markup
        return str(self._call("sendMessage", payload)["result"]["message_id"]), False

    def edit_checkin(self, ref: str, message_id: str, card_id: str, text: str, keyboard: list[list[tuple[str, str]]],
                     is_photo: bool, media: Media | None = None) -> None:
        """Edit the message to this text and keyboard (and, on a photo message given `media`, the picture). "Not
        modified" is success; every other failure raises ChannelError (`cant_edit` when the message is gone,
        `rate_limited` with `retry_after` on a 429)."""
        markup = self.checkin_markup(card_id, keyboard)
        try:
            if media and media.photo and is_photo and utf16_len(text) <= CAPTION_MAX:
                fields = {"chat_id": int(ref), "message_id": int(message_id), "reply_markup": json.dumps(markup),
                          "media": json.dumps({"type": "photo", "media": "attach://photo", "caption": text})}
                self._call("editMessageMedia", fields, {"photo": ("card.png", media.photo, "image/png")})
                return
            payload: dict[str, Any] = {"chat_id": int(ref), "message_id": int(message_id), "reply_markup": markup}
            payload["caption" if is_photo else "text"] = text
            self._call("editMessageCaption" if is_photo else "editMessageText", payload)
        except ChannelError as e:
            if not e.not_modified:
                raise

    def edit_card_text(self, ref: str, message_id: str, card_id: str, text: str, buttons: list[dict]) -> None:
        """Edit a plain card's text and its buttons in place (the quest offer: Another swaps the text, a choice removes the
        buttons). Callback data is `card_id:index`, the same as when the card was sent. "Not modified" is success."""
        row = [{"text": b["label"][:40], "callback_data": f"{card_id}:{i}"} for i, b in enumerate(buttons)]
        try:
            self._call("editMessageText", {"chat_id": int(ref), "message_id": int(message_id), "text": text,
                                           "reply_markup": {"inline_keyboard": [row] if row else []}})
        except ChannelError as e:
            if not e.not_modified:
                raise

    def send_photo(self, ref: str, photo: bytes, caption: str = "", silent: bool = True) -> str:
        """A picture with no buttons (the week card). Silent by default: no notification."""
        fields: dict[str, Any] = {"chat_id": int(ref), "disable_notification": "true" if silent else "false"}
        if caption:
            fields["caption"] = caption
        return str(self._call("sendPhoto", fields, {"photo": ("card.png", photo, "image/png")})["result"]["message_id"])

    def edit_photo(self, ref: str, message_id: str, photo: bytes, caption: str = "") -> None:
        """Replace a picture message's picture. "Not modified" is success."""
        fields = {"chat_id": int(ref), "message_id": int(message_id),
                  "media": json.dumps({"type": "photo", "media": "attach://photo", **({"caption": caption} if caption else {})})}
        try:
            self._call("editMessageMedia", fields, {"photo": ("card.png", photo, "image/png")})
        except ChannelError as e:
            if not e.not_modified:
                raise

    def pin(self, ref: str, message_id: str) -> None:
        """Pin silently. Cosmetic: a refusal (no right to pin, message gone) never fails the caller."""
        try:
            self._call("pinChatMessage", {"chat_id": int(ref), "message_id": int(message_id), "disable_notification": True})
        except ChannelError:
            pass

    def unpin(self, ref: str, message_id: str) -> None:
        try:
            self._call("unpinChatMessage", {"chat_id": int(ref), "message_id": int(message_id)})
        except ChannelError:
            pass

    def edit_into_card(self, ref: str, message_id: str, card: OutCard, is_photo: bool) -> None:
        """Turn an earlier message (the morning today card) into this run card, in place (C3). A photo replaces the
        picture; text edits the caption or the text. "Not modified" is success; anything else raises ChannelError, and
        the caller sends the card as a new message instead."""
        text = f"{card.headline}\n{card.body}"
        has_photo = bool(card.media and card.media.photo)
        kb = self._keyboard(card, media=has_photo)
        markup = {"inline_keyboard": kb}
        try:
            if has_photo:
                if not is_photo or utf16_len(text) > CAPTION_MAX:
                    raise ChannelError("telegram editMessageMedia: not applicable", status=400, description="can't be edited")
                fields = {"chat_id": int(ref), "message_id": int(message_id), "reply_markup": json.dumps(markup),
                          "media": json.dumps({"type": "photo", "media": "attach://photo", "caption": text})}
                self._call("editMessageMedia", fields, {"photo": ("card.png", card.media.photo, "image/png")})
            else:
                payload: dict[str, Any] = {"chat_id": int(ref), "message_id": int(message_id), "reply_markup": markup}
                payload["caption" if is_photo else "text"] = text
                self._call("editMessageCaption" if is_photo else "editMessageText", payload)
        except ChannelError as e:
            if not e.not_modified:
                raise

    def edit_card_body(self, ref: str, message_id: str, card: OutCard, is_photo: bool) -> None:
        """Rewrite a sent card's text (the caption on a media message), keeping its buttons as `card` lists them and its
        picture as it is. "Not modified" is success; anything else raises ChannelError."""
        text = caption_text(card) if is_photo else f"{card.headline}\n{card.body}"
        if is_photo and utf16_len(text) > CAPTION_MAX:
            raise ChannelError("telegram editMessageCaption: too long", status=400, description="caption too long")
        payload: dict[str, Any] = {"chat_id": int(ref), "message_id": int(message_id),
                                   "reply_markup": {"inline_keyboard": self._keyboard(card, media=is_photo)}}
        payload["caption" if is_photo else "text"] = text
        try:
            self._call("editMessageCaption" if is_photo else "editMessageText", payload)
        except ChannelError as e:
            if not e.not_modified:
                raise

    def clear_keyboard(self, ref: str, message_id: str) -> None:
        try:
            self._call("editMessageReplyMarkup", {"chat_id": int(ref), "message_id": int(message_id),
                                                  "reply_markup": {"inline_keyboard": []}})
        except ChannelError:
            pass  # cosmetic

    def answer_callback(self, callback_id: str | None, text: str = "") -> None:
        """Answer the tap first, so the button stops spinning whatever happens next."""
        if not callback_id:
            return
        try:
            self._call("answerCallbackQuery", {"callback_query_id": callback_id, **({"text": text} if text else {})})
        except ChannelError:
            pass  # cosmetic

    @staticmethod
    def parse(update: dict) -> Inbound | None:
        uid = update.get("update_id")
        if uid is None:
            return None
        msg_id = f"tg:{uid}"
        cb = update.get("callback_query")
        if cb:
            m = cb.get("message") or {}
            chat = m.get("chat") or {}
            if chat.get("type") != "private" or "id" not in (cb.get("from") or {}):
                return None
            ci = parse_checkin_callback(str(cb.get("data", "")))
            if ci:
                return Inbound("telegram", str(cb["from"]["id"]), msg_id, card_id=ci[0], code=ci[1],
                               callback_id=str(cb.get("id")), callback_message_id=str(m.get("message_id", "")) or None)
            parsed = parse_callback(str(cb.get("data", "")))
            if not parsed:
                return None
            return Inbound("telegram", str(cb["from"]["id"]), msg_id, card_id=parsed[0], button_idx=parsed[1],
                           callback_id=str(cb.get("id")), callback_message_id=str(m.get("message_id", "")) or None)
        m = update.get("message")
        if not m or (m.get("chat") or {}).get("type") != "private" or "text" not in m:
            return None
        f = m.get("from") or {}
        name = " ".join(x for x in (f.get("first_name"), f.get("last_name")) if isinstance(x, str)).strip()
        if not name and isinstance(f.get("username"), str):
            name = "@" + f["username"]
        elif name and isinstance(f.get("username"), str):
            name += " (@" + f["username"] + ")"
        return Inbound("telegram", str(m["chat"]["id"]), msg_id, text=str(m["text"])[:MAX_TEXT], name=name[:64])


# --- WhatsApp Cloud API (disabled until Meta config exists) ----------------------------------

def verify_wa_signature(app_secret: str, raw_body: bytes, header: str | None) -> bool:
    """X-Hub-Signature-256 is 'sha256=' + HMAC-SHA256(app secret, raw body)."""
    if not header or not header.startswith("sha256="):
        return False
    want = hmac.new(app_secret.encode(), raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(want.encode(), header[len("sha256="):].encode())


FEEL_ACTIONS = ("feel:easy", "feel:right", "feel:hard")
WA_QUICK_REPLIES = 3
WA_MEDIA_MAX = {"image": 5 * 1024 * 1024, "video": 16 * 1024 * 1024}
WA_MEDIA_MIME = {"image": ("image/png", "image/jpeg"), "video": ("video/mp4",)}


def feel_template_eligible(card: OutCard) -> bool:
    """The approved template's quick-reply labels are fixed (Easy, Right, Hard). Payloads may only ride it when the
    card's first three buttons are exactly those; any other card goes in the 24 h window instead."""
    return tuple(b["action"] for b in card.buttons[:WA_QUICK_REPLIES]) == FEEL_ACTIONS


def wa_template_payload(to: str, name: str, lang: str, card: OutCard, *, media_id: str | None = None,
                        media_kind: str = "image", url_suffix: str | None = None, url_index: int = 3) -> dict:
    """Media-header template message: header (image or video by id), two body variables, quick replies, an optional
    dynamic-URL button for the deep link. Pure: builds the payload, sends nothing."""
    if media_kind not in WA_MEDIA_MIME:
        raise ValueError("media_kind must be image or video")
    components: list[dict] = []
    if media_id:
        components.append({"type": "header", "parameters": [{"type": media_kind, media_kind: {"id": media_id}}]})
    components.append({"type": "body", "parameters": [
        {"type": "text", "text": card.headline[:60]}, {"type": "text", "text": " ".join(card.body.split())[:1000]}]})
    if feel_template_eligible(card):
        for i in range(WA_QUICK_REPLIES):
            components.append({"type": "button", "sub_type": "quick_reply", "index": str(i),
                               "parameters": [{"type": "payload", "payload": f"{card.card_id}:{i}"}]})
    if url_suffix:
        components.append({"type": "button", "sub_type": "url", "index": str(url_index),
                           "parameters": [{"type": "text", "text": url_suffix[:200]}]})
    return {"messaging_product": "whatsapp", "to": to, "type": "template", "template": {
        "name": name, "language": {"code": lang}, "components": components}}


def wa_media_upload_spec(api: str, phone_id: str, data: bytes, mime: str) -> dict:
    """What a Meta media upload (POST /<phone id>/media, multipart) would send. Returned, never executed."""
    kind = "video" if mime.startswith("video/") else "image"
    if mime not in WA_MEDIA_MIME[kind]:
        raise ValueError("unsupported media type")
    if len(data) > WA_MEDIA_MAX[kind]:
        raise ValueError(f"{kind} over the WhatsApp {WA_MEDIA_MAX[kind] >> 20} MB limit")
    ext = {"image/png": "png", "image/jpeg": "jpg", "video/mp4": "mp4"}[mime]
    return {"url": f"{api}/{phone_id}/media", "data": {"messaging_product": "whatsapp", "type": mime},
            "files": {"file": (f"card.{ext}", data, mime)}}


class WhatsAppChannel:
    name = "whatsapp"

    def __init__(self, s: Settings, http: httpx.Client):
        self.s, self.http = s, http

    def _post(self, payload: dict) -> str:
        try:
            r = self.http.post(
                f"{self.s.wa_api}/{self.s.wa_phone_id}/messages",
                headers={"Authorization": f"Bearer {self.s.wa_token}"}, json=payload, timeout=10)
            data = r.json()
        except (httpx.HTTPError, ValueError) as e:
            raise ChannelError(f"whatsapp transport: {type(e).__name__}") from None
        if r.status_code != 200:
            raise ChannelError(f"whatsapp: http {r.status_code}")
        return str(data["messages"][0]["id"])

    def send_text(self, ref: str, text: str) -> str:
        return self._post({"messaging_product": "whatsapp", "to": ref, "type": "text", "text": {"body": text[:1000]}})

    def send_card(self, ref: str, card: OutCard, *, in_window: bool = False, media_id: str | None = None,
                  media_kind: str = "image", url_suffix: str | None = None, **_: Any) -> str:
        """Inside the 24 h service window: free-form interactive. Outside: the approved template.

        `media_id` is an already-uploaded Meta media id for the template header. Nothing here uploads: the media
        upload is built by wa_media_upload_spec and stays unwired until a Meta account exists."""
        text = "\n".join(x for x in (card.headline, card.body) if x)
        base = {"messaging_product": "whatsapp", "to": ref}
        if in_window:
            # "Add a note" is not offered on WhatsApp (it would turn the three feel buttons into a list). The index of
            # each kept button is its position in card.buttons, which the callback resolves.
            offered = [(i, b) for i, b in enumerate(card.buttons) if b["action"] != "note:add"]
            if not offered:
                return self._post({**base, "type": "text", "text": {"body": text[:1000]}})
            if len(offered) <= 3:
                interactive = {"type": "button", "body": {"text": text[:1024]}, "action": {"buttons": [
                    {"type": "reply", "reply": {"id": f"{card.card_id}:{i}", "title": b["label"][:20]}}
                    for i, b in offered]}}
            else:
                interactive = {"type": "list", "body": {"text": text[:1024]}, "action": {
                    "button": "Choose", "sections": [{"title": "Options", "rows": [
                        {"id": f"{card.card_id}:{i}", "title": b["label"][:24]}
                        for i, b in offered[:10]]}]}}
            return self._post({**base, "type": "interactive", "interactive": interactive})
        return self._post(wa_template_payload(
            ref, self.s.wa_template, self.s.wa_template_lang, card, media_id=media_id, media_kind=media_kind,
            url_suffix=url_suffix, url_index=self.s.wa_url_index))

    def ack_callback(self, inb: Inbound, text: str, clear: bool = True, keep: list[tuple[str, int]] | None = None) -> None:
        return None  # WhatsApp has no callback ack

    @staticmethod
    def parse(payload: dict) -> list[Inbound]:
        out: list[Inbound] = []
        def items(x):
            return [i for i in x if isinstance(i, dict)] if isinstance(x, list) else []

        for entry in items(payload.get("entry")):
            for ch in items(entry.get("changes")):
                val = ch.get("value")
                names = {str(c.get("wa_id")): str((c.get("profile") or {}).get("name", ""))[:64]
                         for c in items(val.get("contacts") if isinstance(val, dict) else None)}
                for m in items(val.get("messages") if isinstance(val, dict) else None):
                    wa_id, mid = str(m.get("from", "")), str(m.get("id", ""))
                    if not wa_id or not mid:
                        continue
                    t = m.get("type")
                    if t == "text":
                        out.append(Inbound("whatsapp", wa_id, mid, text=str(m["text"].get("body", ""))[:MAX_TEXT], name=names.get(wa_id, "")))
                    elif t == "interactive":
                        it = m["interactive"]
                        rid = (it.get("button_reply") or it.get("list_reply") or {}).get("id", "")
                        p = parse_callback(str(rid))
                        if p:
                            out.append(Inbound("whatsapp", wa_id, mid, card_id=p[0], button_idx=p[1]))
                    elif t == "button":  # template quick-reply
                        p = parse_callback(str((m.get("button") or {}).get("payload", "")))
                        if p:
                            out.append(Inbound("whatsapp", wa_id, mid, card_id=p[0], button_idx=p[1]))
        return out
