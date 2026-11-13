#!/usr/bin/env python3
"""Local rate limit fixture for scripts/tests/test_rate_limit_check.sh.

Binds 127.0.0.1 on an ephemeral port and writes the chosen port to a file.
Modes:

  limit=N window=S   return 200 for the first N requests, then 429 with a
                     Retry-After of S seconds
  never              always return 200
  bad-retry          always return 429 with the given --retry-value

Every response carries a cf-ray header with a location suffix. Each request is
appended to the record file as one JSON line with the method, path, auth and
cookie headers, and body length. The fixture is test-only and is never part of
the kit scripts.
"""

import argparse
import json
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

count_lock = threading.Lock()
request_count = 0
record_lock = threading.Lock()


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "rate-limit-fixture"
    sys_version = ""

    def log_message(self, format, *args):  # noqa: A002, ARG002
        return

    def _handle(self):
        global request_count

        length_text = self.headers.get("Content-Length", "0")
        try:
            length = int(length_text)
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length > 0 else b""

        record = {
            "method": self.command,
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
            "cookie": self.headers.get("Cookie"),
            "body_length": len(body),
        }
        with record_lock:
            with open(self.server.record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(record) + "\n")
                handle.flush()

        status, retry_after = self._result()

        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("cf-ray", f"{self.server.ray_prefix}-{self.server.location}")
        if retry_after is not None:
            self.send_header("Retry-After", retry_after)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _result(self):
        global request_count

        mode = self.server.mode
        if mode == "never":
            return 200, None
        if mode == "bad-retry":
            return 429, self.server.retry_value
        with count_lock:
            request_count += 1
            current = request_count
        if current <= self.server.limit:
            return 200, None
        return 429, str(self.server.window)

    do_GET = _handle
    do_HEAD = _handle
    do_POST = _handle
    do_PUT = _handle
    do_PATCH = _handle
    do_DELETE = _handle


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["limit", "never", "bad-retry"], default="limit")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--window", type=int, default=60)
    parser.add_argument("--retry-value", default="0")
    parser.add_argument("--location", default="SIN")
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--record", required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    server.mode = args.mode
    server.limit = args.limit
    server.window = args.window
    server.retry_value = args.retry_value
    server.location = args.location
    server.ray_prefix = uuid.uuid4().hex[:16]
    server.record_path = args.record

    port = server.server_address[1]
    with open(args.port_file, "w", encoding="utf-8") as handle:
        handle.write(str(port) + "\n")
        handle.flush()

    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
