#!/usr/bin/env python3
"""A minimal S3 endpoint, enough for `internal/storage/s3.go` to work against.

This exists because no real object store is reachable from this machine: MinIO
retired its community builds (the old download paths return 410 and the current
one refuses every operation without a licence), Docker Hub is blocked by the
proxy, and GitHub release assets 502 through it.

`minio-go` needs exactly five things, and none of them require signature
validation for our purposes — the goal is to prove the *client* uploads valid
JPEG frames and the *server* assembles segments correctly, not to test S3:

    HEAD   /{bucket}            bucket exists?
    PUT    /{bucket}            create bucket
    PUT    /{bucket}/{key...}   store an object
    GET    /{bucket}/{key...}   fetch it (presigned URLs land here)
    DELETE /{bucket}/{key...}   remove it

Signatures are accepted and ignored. Objects are written to a real directory so
the bytes can be inspected directly, independently of the API.

    python tool/e2e/s3_stub.py --port 9000 --dir C:/Users/Lhui/webcam-e2e/s3

This is a **test double**, not an S3 implementation. Do not use it for anything
that cares about authentication, consistency, multipart uploads or listing.
"""

from __future__ import annotations

import argparse
import os
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_lock = threading.Lock()

# Populated by main().
ROOT = ""
VERBOSE = True


def _safe_path(bucket: str, key: str) -> str | None:
    """Maps bucket/key onto a path under ROOT, refusing anything that escapes."""
    parts = [p for p in (bucket + "/" + key).split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        return None
    target = os.path.join(ROOT, *parts)
    if not os.path.abspath(target).startswith(os.path.abspath(ROOT)):
        return None
    return target


def _decode_aws_chunked(body: bytes) -> bytes:
    """Unwraps `Content-Encoding: aws-chunked` (SigV4 streaming) bodies.

    minio-go uploads `PutObject` with a streaming signature, so the wire body is

        <hex-size>;chunk-signature=<sig>\\r\\n<data>\\r\\n … 0;chunk-signature=<sig>\\r\\n\\r\\n

    Storing that verbatim corrupts the object — the frames come back with chunk
    headers glued to them, which is exactly what the byte-level check caught the
    first time this stub was used. A real S3 decodes it; so must the stub.
    """
    out = bytearray()
    i = 0
    while i < len(body):
        newline = body.find(b"\r\n", i)
        if newline == -1:
            break
        header = body[i:newline].split(b";", 1)[0]
        try:
            size = int(header, 16)
        except ValueError:
            # Not a chunk header: the body was sent unencoded after all.
            return body
        i = newline + 2
        if size == 0:
            break
        out += body[i : i + size]
        i += size + 2  # skip the data and its trailing CRLF
    return bytes(out)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "s3-stub/1"

    # Keep the console readable; the default logger writes to stderr per request.
    def log_message(self, fmt, *args):
        if VERBOSE:
            sys.stderr.write("    " + (fmt % args) + "\n")

    def _split(self) -> tuple[str, str]:
        path = urllib.parse.urlparse(self.path).path.lstrip("/")
        bucket, _, key = path.partition("/")
        return urllib.parse.unquote(bucket), urllib.parse.unquote(key)

    def _send(self, code: int, body: bytes = b"", content_type: str = "application/xml"):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        if body:
            self.send_header("Content-Type", content_type)
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _read_body(self) -> bytes:
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks = []
            while True:
                size_line = self.rfile.readline().strip()
                size = int(size_line.split(b";")[0] or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
            body = b"".join(chunks)
        else:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""

        # minio-go streams the signature, but does not always advertise it in
        # `Content-Encoding`; the framing marker in the body is the reliable
        # signal.
        if b";chunk-signature=" in body[:64]:
            decoded = _decode_aws_chunked(body)
            print(f"    (aws-chunked: {len(body)} -> {len(decoded)} bytes)")
            return decoded
        return body

    # --- verbs ---------------------------------------------------------------

    def do_HEAD(self):
        bucket, key = self._split()
        if not key:
            exists = os.path.isdir(os.path.join(ROOT, bucket))
            self._send(200 if exists else 404)
            return
        path = _safe_path(bucket, key)
        self._send(200 if path and os.path.isfile(path) else 404)

    def do_GET(self):
        bucket, key = self._split()
        query = urllib.parse.urlparse(self.path).query

        # GetBucketLocation — minio-go falls back to this when HEAD is refused.
        if not key and "location" in query:
            self._send(200, b'<?xml version="1.0"?><LocationConstraint/>')
            return

        path = _safe_path(bucket, key)
        if not path or not os.path.isfile(path):
            self._send(
                404,
                b'<?xml version="1.0"?><Error><Code>NoSuchKey</Code></Error>',
            )
            return

        with open(path, "rb") as handle:
            body = handle.read()
        print(f"  GET {bucket}/{key} -> {len(body)} bytes")
        self._send(200, body, "application/octet-stream")

    def do_PUT(self):
        bucket, key = self._split()

        if not key:
            with _lock:
                os.makedirs(os.path.join(ROOT, bucket), exist_ok=True)
            print(f"  MAKE BUCKET {bucket}")
            self._send(200)
            return

        path = _safe_path(bucket, key)
        if not path:
            self._send(400)
            return

        body = self._read_body()
        with _lock:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as handle:
                handle.write(body)
        print(f"  PUT {bucket}/{key} <- {len(body)} bytes")
        self.send_response(200)
        self.send_header("ETag", '"stub"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self):
        bucket, key = self._split()
        path = _safe_path(bucket, key)
        if path and os.path.isfile(path):
            with _lock:
                os.remove(path)
        print(f"  DELETE {bucket}/{key}")
        self._send(204)

    def do_POST(self):
        # Multipart uploads are not needed for our object sizes; refuse loudly
        # rather than silently storing something incomplete.
        bucket, key = self._split()
        self._read_body()
        print(f"  !! POST {bucket}/{key} (multipart is not supported by this stub)")
        self._send(501, b'<?xml version="1.0"?><Error><Code>NotImplemented</Code></Error>')


def main() -> int:
    global ROOT, VERBOSE

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--dir", required=True, help="where objects are written")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    ROOT = os.path.abspath(args.dir)
    VERBOSE = not args.quiet
    os.makedirs(ROOT, exist_ok=True)

    print(f"s3 stub listening on 127.0.0.1:{args.port}, objects under {ROOT}")
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
