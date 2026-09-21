"""Send build artifacts to an explicitly configured Telegram private chat.

Only workflow_dispatch opts in. No credentials or API URLs are logged, and
ambiguous upload failures are not retried automatically (to avoid duplicates).
"""

import hashlib
import http.client
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid


MAX_FILE_BYTES = 50_000_000


class DeliveryError(Exception):
    pass


def api_call(token, method, body, content_type):
    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=body,
        headers={"Content-Type": content_type},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        # HTTP exception strings contain the URL (and therefore the bot token).
        raise DeliveryError(f"Telegram HTTP {error.code}; check bot permissions, chat ID and file size.") from None
    except (urllib.error.URLError, TimeoutError, OSError, http.client.HTTPException):
        raise DeliveryError("Telegram network error; check the bot chat before manually retrying.") from None
    except (ValueError, UnicodeError):
        raise DeliveryError("Telegram returned an invalid response.") from None
    if not isinstance(result, dict) or result.get("ok") is not True:
        raise DeliveryError("Telegram rejected the request; check the bot and chat configuration.")
    return result.get("result")


def verify_private_chat(token, chat_id):
    if not chat_id.isascii() or not chat_id.isdigit() or int(chat_id) <= 0:
        raise DeliveryError("TELEGRAM_CHAT_ID must be your positive numeric private-chat ID, not a channel or group.")
    body = urllib.parse.urlencode({"chat_id": chat_id}).encode("utf-8")
    chat = api_call(token, "getChat", body, "application/x-www-form-urlencoded")
    if not isinstance(chat, dict) or chat.get("type") != "private" or str(chat.get("id")) != chat_id:
        raise DeliveryError("Refusing delivery: the configured destination is not the expected private chat.")


def send_file(token, chat_id, path, env):
    if path.stat().st_size > MAX_FILE_BYTES:
        raise DeliveryError(f"{path.name} exceeds the 50 MB upload limit; download it from Actions artifacts instead.")
    payload = path.read_bytes()
    if not payload:
        raise DeliveryError(f"{path.name} is empty.")
    run_url = (
        f"{env.get('GITHUB_SERVER_URL', 'https://github.com')}/"
        f"{env.get('GITHUB_REPOSITORY', '')}/actions/runs/{env.get('GITHUB_RUN_ID', '')}"
    )
    platform = "Android APK" if path.suffix.lower() == ".apk" else "iOS IPA"
    caption = (
        f"Yomiru · {platform}\n"
        f"TAG：{env.get('RELEASE_TAG', '')}\n"
        f"提交：{env.get('GITHUB_SHA', '')[:12]}\n"
        f"构建次数：{env.get('GITHUB_RUN_ATTEMPT', '1')}\n"
        f"SHA-256：{hashlib.sha256(payload).hexdigest()}\n{run_url}"
    )[:1024]
    boundary = f"Yomiru{uuid.uuid4().hex}"
    chunks = []
    for name, value in (("chat_id", chat_id), ("caption", caption)):
        chunks.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode("utf-8")
        )
    filename = path.name.replace('"', '_').replace("\r", "_").replace("\n", "_")
    chunks.extend([
        f'--{boundary}\r\nContent-Disposition: form-data; name="document"; filename="{filename}"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode("utf-8"),
        payload,
        f"\r\n--{boundary}--\r\n".encode("ascii"),
    ])
    api_call(token, "sendDocument", b"".join(chunks), f"multipart/form-data; boundary={boundary}")


def main(directory, env=None):
    env = os.environ if env is None else env
    token = env.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat_id = env.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat_id:
        raise DeliveryError("Add TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in repository Actions Secrets, then send /start to your bot.")
    files = sorted(path for path in Path(directory).iterdir() if path.is_file() and path.suffix.lower() in (".apk", ".ipa"))
    if not files:
        raise DeliveryError("No APK or IPA artifacts were found.")
    verify_private_chat(token, chat_id)
    errors = []
    for path in files:
        try:
            send_file(token, chat_id, path, env)
            print(f"Sent {path.name}")
        except DeliveryError as error:
            errors.append(str(error))
    if errors:
        raise DeliveryError("; ".join(errors))


if __name__ == "__main__":
    try:
        main(sys.argv[1] if len(sys.argv) > 1 else "telegram-dist")
    except (DeliveryError, OSError) as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
