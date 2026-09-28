#!/usr/bin/env python3
"""Test media server for the self-test.

Behaves like real video CDNs:
  /<file>              normal, supports HTTP Range
  /slow/<file>         capped at RATE bytes/s *per connection* (what CDNs do)
  /norange/<file>      ignores Range (forces the single-connection fallback)
  /limited/<file>      slow + only MAX_CONN simultaneous connections, then 429
"""
import http.server
import os
import re
import socketserver
import sys
import threading
import time

ROOT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), 'media')
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
RATE = int(os.environ.get('SERVE_RATE', str(1024 * 1024)))
MAX_CONN = int(os.environ.get('SERVE_MAX_CONN', '3'))

_active = 0
_lock = threading.Lock()


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.handle_file(head=True)

    def do_GET(self):
        self.handle_file(head=False)

    def handle_file(self, head):
        global _active
        path = self.path.split('?', 1)[0]
        mode = 'plain'
        for prefix in ('slow', 'norange', 'limited'):
            if path.startswith(f'/{prefix}/'):
                mode = prefix
                path = path[len(prefix) + 1:]
                break
        local = self.translate_path(path)
        if not os.path.isfile(local):
            self.send_error(404)
            return
        if mode == 'limited':
            with _lock:
                if _active >= MAX_CONN:
                    self.send_response(429)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                _active += 1
        try:
            self.send_body(local, head, mode)
        finally:
            if mode == 'limited':
                with _lock:
                    _active -= 1

    def send_body(self, local, head, mode):
        size = os.path.getsize(local)
        start, end = 0, size - 1
        partial = False
        rng = self.headers.get('Range')
        if rng and mode != 'norange':
            m = re.match(r'bytes=(\d*)-(\d*)', rng)
            if m:
                if m.group(1):
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else size - 1
                else:
                    start = max(0, size - int(m.group(2)))
                end = min(end, size - 1)
                if start > end:
                    self.send_response(416)
                    self.send_header('Content-Range', f'bytes */{size}')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                partial = True
        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header('Content-Type', self.guess_type(local))
        self.send_header('Content-Length', str(length))
        if mode != 'norange':
            self.send_header('Accept-Ranges', 'bytes')
        if partial:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        if head:
            return
        throttle = mode in ('slow', 'limited')
        with open(local, 'rb') as fh:
            fh.seek(start)
            remaining = length
            began = time.time()
            sent = 0
            while remaining > 0:
                chunk = fh.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(chunk)
                sent += len(chunk)
                if throttle:
                    ahead = sent / RATE - (time.time() - began)
                    if ahead > 0:
                        time.sleep(ahead)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        # clients closing pooled keep-alive connections is normal
        if isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError, TimeoutError)):
            return
        super().handle_error(request, client_address)


if __name__ == '__main__':
    Server(('127.0.0.1', PORT), Handler).serve_forever()
