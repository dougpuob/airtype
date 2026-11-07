# Telegram clipper intake

Private http(s) URLs sent to the existing `@AirTypeBot` chat are queued with the
same Obsidian Clipper pipeline as a URL pasted in the WebUI. The WebUI process
polls Telegram. It does not open a port, set a webhook, or add an HTTP route.

This is off until the host config says otherwise. Nothing in this repository
contains a bot token. Do not create another bot and do not change BotFather
from these steps.

## What the running service already is

The clipper queue is the WebUI process on port 8003.

| | |
| --- | --- |
| Enqueue | `POST /api/clip-requests` with JSON `{"url": "https://...", "notes": ""}` |
| Handler | `_submit_clip_url` in `source/webui/app/main.py`. The Telegram worker calls that function in-process. It does not scrape the page itself and it does not call the HTTP route. |
| Auth | `[webui.auth]`. When it is on, unauthenticated calls get 401, including `/health` and `/openapi.json`. Public exceptions are `/`, `/app`, `/api/health`, `/api/auth/status`, and `/api/auth/login`. A browser session cookie, HTTP Basic, or a loopback-only `X-Airtype-Token` that matches `~/.airtype/api-token` (at least 32 characters, and no proxy headers) also passes. The poller does not use or bypass that check. |
| Task id | Clip request `id`, `YYYYMMDD-HHMMSS`, with `-2`, `-3`, … when several land in the same second. `GET /api/clip-requests/{id}` returns the record. `origin` is `telegram`. |
| Dedup | The clipper does not dedupe by URL. Two different Telegram messages with the same URL become two requests. The same Telegram update, retried after a crash, does not. Its key is `telegram:{update_id}:{ordinal}:{sha256-prefix}` on the request and in `clip-request-idempotency.json`. |

Known-source URLs (Threads, YouTube, Bilibili, a direct media file, and the rest of `known_sources`) still take their existing pipeline. Everything else is a web article.

## What is blocked before enqueue

The worker accepts `url` and `text_link` entities from the message text or caption, http and https only, at most 5 URLs and 2048 characters each. It does not scan the raw text for URLs.

A target is refused when `web_article.blocked_host_reason` would refuse it: `localhost`, `*.local`, `*.localhost`, and the literal ranges `0.0.0.0/8`, `10.0.0.0/8`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`, and `192.168.0.0/16`. Obfuscated forms of those same addresses (`2130706433`, `127.1`, hex, octal, IPv4-mapped IPv6) are refused too, as are `metadata.google.internal`, `metadata.goog`, IPv6 loopback, IPv6 link-local (`fe80::/10`), and the single address `100.100.169.254`. URLs with a username or password are refused so they are not stored.

These stay allowed, matching the clipper and the host's Tailscale layout: `*.ts.net` names, `100.64.0.0/10`, `100.100.100.100`, and Tailscale IPv6 ULA addresses. The worker does not resolve DNS and does not prefetch redirects. Downloaders inside the clipper follow redirects the same way they do for a URL pasted in the WebUI.

Service logs and the Telegram state file do not contain the bot token or URLs that carry userinfo or a query string. The clip request `source` field still stores the URL, because the downloader needs it.

## Deploy on the existing Linux host

The poller runs inside the process that already serves port 8003. Do not add a second service, and do not change the bind address, port, auth, or the rest of `~/.airtype/config.toml`.

1. Put this revision on the checkout that process already runs. Restart that process after the code is in place. A settings save from the WebUI does not delete `[webui.telegram]`.
2. Confirm outbound HTTPS to `api.telegram.org:443`. No inbound port is required.
3. If a webhook was ever set for this bot, remove it once, from the host, before enabling the poller. This process will not call `deleteWebhook`, and it will not poll while a webhook is set. Keep pending updates:

   ```bash
   umask 077
   # token stays in the environment of this shell, not in the repo or the unit file
   curl -sS -X POST "https://api.telegram.org/bot${AIRTYPE_TELEGRAM_BOT_TOKEN}/deleteWebhook" \
     --data-urlencode drop_pending_updates=false
   ```

4. Store the existing bot token outside the repo, mode `0600`, owned by the user the WebUI already runs as. Either a file:

   ```bash
   install -m 600 /dev/null /etc/airtype/telegram-bot-token
   printf '%s\n' "$AIRTYPE_TELEGRAM_BOT_TOKEN" > /etc/airtype/telegram-bot-token
   ```

   or a systemd drop-in that only adds an environment file (do not replace `ExecStart`):

   ```ini
   # /etc/systemd/system/<existing-webui-unit>.service.d/telegram.conf
   [Service]
   EnvironmentFile=/etc/airtype/telegram.env
   ```

   `/etc/airtype/telegram.env` is mode `0600` and contains one line:
   `AIRTYPE_TELEGRAM_BOT_TOKEN=...`

5. Add only this table to the host's `~/.airtype/config.toml`. Leave the ids at `0` until pairing below. `0` means unset.

   ```toml
   [webui.telegram]
   enabled = true
   token_file = "/etc/airtype/telegram-bot-token"   # omit the line when the env var is set
   allowed_user_id = 0
   allowed_chat_id = 0
   replies_enabled = false
   ```

6. Restart the existing WebUI process so it loads this code. The poller re-reads the token, the flag, and the allowlist on each cycle, so later id edits do not need another restart. `AIRTYPE_DISABLE_TELEGRAM_CLIPPER=1` stops the thread on the next start.

While `enabled` is false, or the token is missing, it does not call Telegram. While either id is unset it still polls, so pairing can be recorded, and it still refuses every URL.

## Pair a private chat

The bot cannot turn a phone number into a user id. Do not guess. Send `/start` yourself, read the id the bot recorded, and copy it into config only after it matches the account you control.

1. From the Telegram account that should be allowed, open a private chat with `@AirTypeBot` and send `/start` or `/whoami`. Do not include a URL. A URL in that message is ignored.
2. On the host, read the candidate file. The directory is `data_dir` from `[webui.storage]`, normally `~/.airtype/data`:

   ```bash
   jq . ~/.airtype/data/telegram/pairing-candidates.json
   ```

   Each entry has `user_id`, `chat_id`, `username`, `first_name`, `command`, and `update_id`. There is no message text and no URL. The file is mode `0600`. The same line is appended to the WebUI log as `telegram pairing candidate ...`.
3. Check the username against the account that sent `/start`. A `/start` from anyone else is also recorded and is not authorized.
4. Set both ids from that entry. Both must be positive. A private chat id is not assumed to equal the user id.

   ```toml
   allowed_user_id = 123456789
   allowed_chat_id = 123456789
   ```

   Environment overrides, when you would rather not put the ids in the toml: `AIRTYPE_TELEGRAM_ALLOWED_USER_ID` and `AIRTYPE_TELEGRAM_ALLOWED_CHAT_ID`.
5. Send an http or https link in that same private chat. The clip shows up in the WebUI queue. The request JSON has `"origin": "telegram"`. The queue label in the current UI still says Manual for every origin other than Watching; the JSON is the source of truth.
6. Messages that arrived before both ids were saved are not replayed. Send the URL again after the allowlist is in place.

`replies_enabled` stays false. The process then sends no Telegram messages at all. Setting it true (or `AIRTYPE_TELEGRAM_REPLIES=1`) adds one reply, `Queued N clip(s).`, to the allowlisted chat, with no URL in the text. Pairing stays in the JSON file either way.

## Crash, duplicates, and a second process

- `~/.airtype/data/telegram/state.json` stores `next_offset` (the next `update_id` to confirm) and any clip id already accepted for the current update. The offset moves forward only after that update is durable. Mode `0600`.
- A crash after enqueue and before the offset write redelivers the update. The idempotency key returns the existing clip request instead of starting a second download.
- A crash while a telegram clip was still queued or running leaves the usual restart error (`Interrupted when the server restarted`). On the next start, with the poller enabled, that same request id is queued again. A voice clip gets a new transcription job id; the clip request id does not change. A clip that failed for any other reason is not retried.
- `~/.airtype/data/telegram/.poller.lock` is held by the one process allowed to call `getUpdates`. Another WebUI process waits. Do not run a separate poller.
- `getUpdates` with HTTP 409, or a non-empty `getWebhookInfo` URL, pauses polling for 30 seconds and retries. It does not delete the webhook. Network errors back off from 1 second to 60. HTTP 429 uses Telegram's `retry_after`. HTTP 401 waits 60 seconds. Shutdown sets a stop flag; the thread is a daemon so a stuck long poll cannot hold the process open, and an update that was not durable locally stays unconfirmed at Telegram.

## Runtime prerequisites

- The existing WebUI Python environment (`fastapi`, the current `source/webui/requirements.txt`). This feature adds no package.
- Outbound TCP 443 to `api.telegram.org`.
- A writable WebUI data directory.
- The bot token of the bot that already exists, in the environment or the token file above.
- No webhook configured for that bot.
- `[webui.telegram] enabled = true` plus both allowlist ids, after the pairing check.

No live Telegram call is made from the repository tests or from a cloud checkout. Enabling the table on the host is what connects the bot.
