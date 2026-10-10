"""Channel adapters behind one interface. Buttons are defined by the server, never by the LLM."""
from __future__ import annotations

import hashlib
import hmac
from dataclasses import dataclass
from typing import Any

import httpx

import json
import re

from .config import Settings
from .media import PHOTO_MAX_BYTES, VIDEO_MAX_BYTES, Media

CAPTION_MAX = 1024        # Telegram caption limit
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
    def __init__(self, msg: str, *, permanent: bool = False):
        super().__init__(msg)
        self.permanent = permanent  # the content was refused (bad media): retrying the same bytes will not help


@dataclass(frozen=True)
class OutCard:
    card_id: str
    headline: str
    body: str
    buttons: list[dict]  # [{"label": str, "action": str, "row": int}] ; callback = f"{card_id}:{index}"
    media: Media | None = None
    links: tuple[tuple[str, str], ...] = ()  # (label, https url): deep-link buttons


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
            data = r.json()
        except (httpx.HTTPError, ValueError) as e:
            raise ChannelError(f"telegram transport: {type(e).__name__}") from None
        if r.status_code != 200 or not data.get("ok"):
            raise ChannelError(f"telegram {method}: http {r.status_code}",
                               permanent=_media_rejected(r.status_code, data.get("description")))
        return data

    def send_text(self, ref: str, text: str) -> str:
        d = self._call("sendMessage", {"chat_id": int(ref), "text": text})
        return str(d["result"]["message_id"])

    @staticmethod
    def _keyboard(card: OutCard, media: bool) -> list[list[dict]]:
        """Callback buttons by row, then one row of deep-link buttons. Callback index = position in card.buttons.

        A media card carries at most 3 feel buttons and never a question: questions go as their own message."""
        rows: dict[int, list[dict]] = {}
        feel = 0
        for i, b in enumerate(card.buttons):
            if media:
                if b["action"].startswith("ans:"):
                    continue
                if b["action"].startswith("feel:"):
                    feel += 1
                    if feel > MAX_FEEL_BUTTONS:
                        continue
            rows.setdefault(b.get("row", 0), []).append({"text": b["label"][:40], "callback_data": f"{card.card_id}:{i}"})
        out = [rows[k] for k in sorted(rows)]
        links = [{"text": label[:40], "url": url} for label, url in card.links if url.startswith("https://")]
        if links:
            out.append(links[:2])
        return out

    def send_card(self, ref: str, card: OutCard, **_: Any) -> str:
        text = f"{card.headline}\n{card.body}"
        if card.media and (card.media.photo or card.media.video):
            return self._send_media(ref, card, text)
        payload: dict[str, Any] = {"chat_id": int(ref), "text": text}
        kb = self._keyboard(card, media=False)
        if kb:
            payload["reply_markup"] = {"inline_keyboard": kb}
        return str(self._call("sendMessage", payload)["result"]["message_id"])

    @staticmethod
    def followups(card: OutCard) -> list[str]:
        """Messages a media card needs after the media itself: "caption" when the text does not fit a caption (the
        buttons ride that text), "question" when question buttons were kept off the media."""
        out = []
        if card.media and (card.media.photo or card.media.video):
            if utf16_len(f"{card.headline}\n{card.body}") > CAPTION_MAX:
                out.append("caption")
            if any(b["action"].startswith("ans:") for b in card.buttons):
                out.append("question")
        return out

    def send_followup(self, ref: str, card: OutCard, mode: str) -> str:
        """The text message a media card could not carry. Sent from its own outbox item, so a failure here retries
        only this message and never re-uploads the media."""
        if mode == "caption":
            text, kb = f"{card.headline}\n{card.body}", self._keyboard(card, media=True)
        elif mode == "question":
            text = card.body
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
        if fits:
            fields["caption"] = text
            if kb:
                fields["reply_markup"] = json.dumps({"inline_keyboard": kb})
        attempts: list[tuple[str, dict, dict]] = []
        if m.video and len(m.video) <= VIDEO_MAX_BYTES:
            attempts.append(("sendVideo", {**fields, "supports_streaming": "true", "width": m.width, "height": m.height,
                                           "duration": m.duration_s},
                             {"video": ("run.mp4", m.video, "video/mp4")}))
        if m.photo and len(m.photo) <= PHOTO_MAX_BYTES:
            attempts.append(("sendPhoto", fields, {"photo": ("card.png", m.photo, "image/png")}))
        if not attempts:
            raise ChannelError("telegram media over the size limit", permanent=True)
        last: ChannelError | None = None
        for method, payload, files in attempts:
            try:
                return str(self._call(method, payload, files)["result"]["message_id"])
            except ChannelError as e:
                if not e.permanent:
                    raise
                last = e
        assert last is not None
        raise last

    def ack_callback(self, inb: Inbound, text: str, clear: bool = True) -> None:
        try:
            self._call("answerCallbackQuery", {"callback_query_id": inb.callback_id, "text": text})
            if clear and inb.callback_message_id:
                self._call("editMessageReplyMarkup", {
                    "chat_id": int(inb.ref), "message_id": int(inb.callback_message_id),
                    "reply_markup": {"inline_keyboard": []}})
        except ChannelError:
            pass  # cosmetic only

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
        return Inbound("telegram", str(m["chat"]["id"]), msg_id, text=str(m["text"])[:500], name=name[:64])


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
        text = f"{card.headline}\n{card.body}"
        base = {"messaging_product": "whatsapp", "to": ref}
        if in_window:
            if not card.buttons:
                return self._post({**base, "type": "text", "text": {"body": text[:1000]}})
            if len(card.buttons) <= 3:
                interactive = {"type": "button", "body": {"text": text[:1024]}, "action": {"buttons": [
                    {"type": "reply", "reply": {"id": f"{card.card_id}:{i}", "title": b["label"][:20]}}
                    for i, b in enumerate(card.buttons)]}}
            else:
                interactive = {"type": "list", "body": {"text": text[:1024]}, "action": {
                    "button": "Choose", "sections": [{"title": "Options", "rows": [
                        {"id": f"{card.card_id}:{i}", "title": b["label"][:24]}
                        for i, b in enumerate(card.buttons[:10])]}]}}
            return self._post({**base, "type": "interactive", "interactive": interactive})
        return self._post(wa_template_payload(
            ref, self.s.wa_template, self.s.wa_template_lang, card, media_id=media_id, media_kind=media_kind,
            url_suffix=url_suffix, url_index=self.s.wa_url_index))

    def ack_callback(self, inb: Inbound, text: str, clear: bool = True) -> None:
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
                        out.append(Inbound("whatsapp", wa_id, mid, text=str(m["text"].get("body", ""))[:500], name=names.get(wa_id, "")))
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
