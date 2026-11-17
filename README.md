# Convo

One iPhone inbox for WhatsApp and Signal, running on a bridge you host yourself.
The design comes from the HTML mockup in this folder (`index.html`).

```
iPhone app (SwiftUI)  ──HTTP + WebSocket, bearer token──▶  convo-bridge (Node)
                                                            ├─ WhatsApp: Baileys, linked as a companion device
                                                            └─ Signal: signal-cli-rest-api, linked as a secondary device
```

Neither network gets your password. The bridge is a **linked device**, just like WhatsApp Web or Signal Desktop. Messages
are stored in SQLite on your server (`/data/convo.db`).

| Folder | What it is |
| --- | --- |
| `bridge/` | The self-hosted bridge: `docker compose` with the bridge and signal-cli |
| `ios/` | Xcode project for the iPhone app (iOS 17+) |
| `index.html`, `src/` | The original HTML example |

## 1. Run the bridge

On any always-on machine with Docker (a home server, NAS or small VPS):

```bash
cd bridge
cp .env.example .env
```

Set `BRIDGE_TOKEN` in `.env` to a long random string. You can generate one with this command:

```bash
openssl rand -hex 24
```

```bash
docker compose up -d --build
```

Check that it is up:

```bash
curl http://localhost:8080/health
```

The bridge listens on port 8080. Only the bridge talks to signal-cli, which is not exposed.

**Reaching it from your phone.** The app allows plain `http://` only on your local network (IP addresses and `.local` names).
To reach it from anywhere, put it behind HTTPS, for example:
- Tailscale: run `tailscale serve --bg 8080` on the server, then use `https://<machine>.<tailnet>.ts.net` in the app.
- A reverse proxy (Caddy, Traefik, nginx) with a certificate. It has to pass WebSocket upgrades through to `/api/events`.

Don't expose port 8080 on the internet without HTTPS. The token would travel in plain text.

## 2. Build the iPhone app

**Without a Mac (sideload):** every push to `main` builds an unsigned `Convo.ipa` on GitHub Actions and publishes it as the
[`latest` release](../../releases/tag/latest). Install it with AltStore, SideStore or Sideloadly, which sign it with your Apple ID.

**With a Mac:** you need Xcode 16 or newer.

1. Open `ios/Convo.xcodeproj`.
2. Select the **Convo** target. Under *Signing & Capabilities*, pick your team and change the bundle identifier
   (`com.example.convo`) to something of your own.
3. Connect your iPhone and press Run. A free Apple ID works, but the app then expires after 7 days.

## 3. Connect and link your accounts

In the app, open **Settings**:

1. Enter the bridge address (for example `http://192.168.1.10:8080`) and your `BRIDGE_TOKEN`, then tap **Connect**.
2. **WhatsApp:** if WhatsApp is on this same iPhone, enter your number and tap **Get pairing code**. Then in WhatsApp go to
   *Settings → Linked devices → Link a device → Link with phone number instead* and type the code.
   If WhatsApp is on another phone, just scan the QR code shown.
3. **Signal:** tap **Show link QR code** and scan it in Signal (*Settings → Linked devices → Link new device*). Signal can only
   scan with the camera, so if Signal is on this iPhone, share the code to another screen (AirDrop to a Mac or iPad) and scan
   it there. Or fetch it on a computer:
   `curl -H "Authorization: Bearer $BRIDGE_TOKEN" http://<bridge>:8080/api/signal/qr > signal.png`

New messages show up live. Pull down on the inbox to refresh, and use **+** to start a chat by phone number.

## What works

- One inbox with WhatsApp and Signal chats (direct and groups), newest first, with unread counts and search
- Sending and receiving text and photos; voice notes, videos, stickers and files show as a short label
- Contacts tab (A–Z), WhatsApp profile pictures, group sender names, in-app banners for new messages
- Light and dark mode

## Not included (yet)

- **Push notifications when the app is closed.** These need an Apple Developer account and APNs on the bridge. For now
  the app catches up whenever you open it.
- Calls, reactions, replies, edits, typing indicators, read receipts back to the sender, and voice/video playback.

## Bridge API

Every request needs the header `Authorization: Bearer <BRIDGE_TOKEN>`.

| Method and path | Purpose |
| --- | --- |
| `GET /api/status` | Link state of WhatsApp (`connecting`, `qr`, `linked`) and Signal (`connecting`, `unlinked`, `linked`) |
| `POST /api/whatsapp/pair` `{phone}` | WhatsApp pairing code |
| `POST /api/whatsapp/logout` | Unlink WhatsApp |
| `GET /api/signal/qr` | PNG QR code to link Signal |
| `GET /api/chats` | All chats |
| `POST /api/chats` `{network, phone}` | Start a chat |
| `GET /api/chats/:id/messages?before=<ms>` | Last 60 messages, before a timestamp if given |
| `POST /api/chats/:id/messages` `{text, image?}` | Send (`image` is base64 JPEG) |
| `POST /api/chats/:id/read` | Mark as read |
| `GET /api/chats/:id/avatar`, `GET /api/media/:messageId` | Images |
| `WS /api/events` | Live events: `message`, `chat`, `status`, `reload` |

Ids are URL-encoded as one path segment.

## Good to know

- WhatsApp does not officially support third-party clients. Baileys is widely used, but accounts that use it can be
  restricted. Use it at your own risk.
- If Signal still shows *unlinked* after you scanned the code, run `docker compose restart signal`.
- Back up both Docker volumes (`bridge-data`, `signal-data`): they hold your message history and linked-device keys.
