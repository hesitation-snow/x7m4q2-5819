"""Offline tests: never contact Telegram or use real credentials."""

import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

import send_telegram as sender


class TelegramDeliveryTests(unittest.TestCase):
    def test_missing_secrets(self):
        with self.assertRaisesRegex(sender.DeliveryError, "Actions Secrets"):
            sender.main("unused", {})

    def test_channels_and_usernames_are_rejected_before_network(self):
        with patch.object(sender, "api_call") as api:
            for chat_id in ("-100123456", "@some_channel", "0"):
                with self.assertRaises(sender.DeliveryError):
                    sender.verify_private_chat("test-token", chat_id)
            api.assert_not_called()

    def test_destination_must_be_expected_private_chat(self):
        for response in ({"id": 123, "type": "group"}, {"id": 456, "type": "private"}):
            with patch.object(sender, "api_call", return_value=response):
                with self.assertRaisesRegex(sender.DeliveryError, "Refusing"):
                    sender.verify_private_chat("test-token", "123")
        with patch.object(sender, "api_call", return_value={"id": 123, "type": "private"}):
            sender.verify_private_chat("test-token", "123")

    def test_multipart_contains_file_caption_and_recipient(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.ipa"
            path.write_bytes(b"test IPA bytes")
            with patch.object(sender, "api_call") as api:
                sender.send_file("test-token", "123", path, {"RELEASE_TAG": "v1-test"})
                token, method, body, content_type = api.call_args.args
                self.assertEqual((token, method), ("test-token", "sendDocument"))
                self.assertIn(b"test IPA bytes", body)
                self.assertIn(b'filename="test.ipa"', body)
                self.assertIn(b"iOS IPA", body)
                self.assertIn(b"v1-test", body)
                self.assertIn(b"\r\n\r\n123\r\n", body)
                self.assertNotIn(b"test-token", body)
                self.assertIn("multipart/form-data", content_type)

    def test_oversized_or_empty_files_are_not_uploaded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.apk"
            path.write_bytes(b"abcd")
            with patch.object(sender, "MAX_FILE_BYTES", 3), patch.object(sender, "api_call") as api:
                with self.assertRaisesRegex(sender.DeliveryError, "50 MB"):
                    sender.send_file("test-token", "123", path, {})
                api.assert_not_called()
            path.write_bytes(b"")
            with self.assertRaisesRegex(sender.DeliveryError, "empty"):
                sender.send_file("test-token", "123", path, {})

    def test_both_platforms_sent_but_other_files_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ("a.apk", "b.ipa", "not-an-artifact.txt"):
                (Path(directory) / name).write_bytes(b"test")
            with patch.object(sender, "verify_private_chat"), patch.object(sender, "send_file") as send:
                sender.main(directory, {"TELEGRAM_BOT_TOKEN": "test-token", "TELEGRAM_CHAT_ID": "123"})
                self.assertEqual([call.args[2].name for call in send.call_args_list], ["a.apk", "b.ipa"])

    def test_one_upload_failure_does_not_skip_other_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ("a.apk", "b.ipa"):
                (Path(directory) / name).write_bytes(b"test")
            with patch.object(sender, "verify_private_chat"), patch.object(sender, "send_file", side_effect=[sender.DeliveryError("failed"), None]) as send:
                with self.assertRaisesRegex(sender.DeliveryError, "failed"):
                    sender.main(directory, {"TELEGRAM_BOT_TOKEN": "test-token", "TELEGRAM_CHAT_ID": "123"})
                self.assertEqual(send.call_count, 2)

    def test_http_error_does_not_reveal_token_or_url(self):
        secret_url = "https://api.telegram.org/botDO-NOT-LOG/getChat"
        error = urllib.error.HTTPError(secret_url, 403, "DO-NOT-LOG", {}, None)
        with patch.object(sender.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(sender.DeliveryError) as caught:
                sender.api_call("DO-NOT-LOG", "getChat", b"", "text/plain")
            self.assertNotIn("DO-NOT-LOG", str(caught.exception))
            self.assertNotIn("https://", str(caught.exception))
            self.assertIn("403", str(caught.exception))

    def test_api_failure_and_invalid_response(self):
        for body in (b'{"ok":false}', b'[]', b'not json'):
            with patch.object(sender.urllib.request, "urlopen", return_value=io.BytesIO(body)):
                with self.assertRaises(sender.DeliveryError):
                    sender.api_call("test-token", "getChat", b"", "text/plain")
        with patch.object(sender.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps({"ok": True, "result": {"id": 123}}).encode())):
            self.assertEqual(sender.api_call("test-token", "getChat", b"", "text/plain"), {"id": 123})


if __name__ == "__main__":
    unittest.main()
