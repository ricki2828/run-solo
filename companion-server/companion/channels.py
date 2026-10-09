"""Channel adapters behind one interface. Buttons are defined by the server, never by the LLM."""
from __future__ import annotations

import hashlib
import hmac
from dataclasses import dataclass
from typing import Any

import httpx

from .config import Settings


class ChannelError(Exception):
    pass


@dataclass(frozen=True)
class OutCard:
    card_id: str
    headline: str
    body: str
    buttons: list[dict]  # [{"label": str, "action": str, "row": int}] ; callback = f"{card_id}:{index}"


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

    def _call(self, method: str, payload: dict) -> dict:
        try:
            r = self.http.post(f"{self.s.telegram_api}/bot{self.s.telegram_token}/{method}", json=payload, timeout=10)
            data = r.json()
        except (httpx.HTTPError, ValueError) as e:
            raise ChannelError(f"telegram transport: {type(e).__name__}") from None
        if r.status_code != 200 or not data.get("ok"):
            raise ChannelError(f"telegram {method}: http {r.status_code}")
        return data

    def send_text(self, ref: str, text: str) -> str:
        d = self._call("sendMessage", {"chat_id": int(ref), "text": text})
        return str(d["result"]["message_id"])

    def send_card(self, ref: str, card: OutCard, **_: Any) -> str:
        rows: dict[int, list[dict]] = {}
        for i, b in enumerate(card.buttons):
            rows.setdefault(b.get("row", 0), []).append(
                {"text": b["label"][:40], "callback_data": f"{card.card_id}:{i}"})
        payload: dict[str, Any] = {"chat_id": int(ref), "text": f"{card.headline}\n{card.body}"}
        if rows:
            payload["reply_markup"] = {"inline_keyboard": [rows[k] for k in sorted(rows)]}
        return str(self._call("sendMessage", payload)["result"]["message_id"])

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

    def send_card(self, ref: str, card: OutCard, *, in_window: bool = False, **_: Any) -> str:
        """Inside the 24 h service window: free-form interactive. Outside: the approved template."""
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
        components: list[dict] = [{"type": "body", "parameters": [
            {"type": "text", "text": card.headline[:60]}, {"type": "text", "text": " ".join(card.body.split())[:1000]}]}]
        for i, _b in enumerate(card.buttons[:3]):
            components.append({"type": "button", "sub_type": "quick_reply", "index": str(i),
                               "parameters": [{"type": "payload", "payload": f"{card.card_id}:{i}"}]})
        return self._post({**base, "type": "template", "template": {
            "name": self.s.wa_template, "language": {"code": self.s.wa_template_lang}, "components": components}})

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
