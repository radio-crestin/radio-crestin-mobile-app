#!/usr/bin/env python3
"""
HLS Proxy - Forwards and logs all HLS requests.
Usage: python3 proxy.py [--port 8080]
"""

import argparse
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, urljoin
import urllib.request
import urllib.error

UPSTREAM_BASE = "https://hls.radiocrestin.ro"
UPSTREAM_PATH = "/hls/radio-moody-chicago/index.m3u8"
UPSTREAM_URL = UPSTREAM_BASE + UPSTREAM_PATH

request_counter = 0


class ProxyHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        global request_counter
        request_counter += 1
        req_id = request_counter
        ts = time.strftime("%H:%M:%S")

        # Map local path to upstream
        if self.path == "/" or self.path == "/index.m3u8":
            upstream_url = UPSTREAM_URL
        else:
            # Resolve relative paths (e.g. /hls/radio-moody-chicago/chunk.ts)
            upstream_url = urljoin(UPSTREAM_URL, self.path.lstrip("/"))
            # If path starts with /hls/, treat as absolute on upstream
            if self.path.startswith("/hls/"):
                upstream_url = UPSTREAM_BASE + self.path

        client_ip = self.client_address[0]
        print(f"[#{req_id}] {ts}  {client_ip}  {self.command} {self.path}  ->  {upstream_url}")

        try:
            req = urllib.request.Request(upstream_url)
            # Forward relevant headers
            for header in ["Range", "Accept", "User-Agent"]:
                if self.headers.get(header):
                    req.add_header(header, self.headers[header])

            start = time.time()
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = resp.read()
                elapsed = time.time() - start
                status = resp.status
                content_type = resp.getheader("Content-Type", "application/octet-stream")

                print(f"       <- {status} | {content_type} | {len(body)} bytes | {elapsed:.3f}s")

                # Rewrite URLs in m3u8 playlists to route through proxy
                if content_type and "mpegurl" in content_type.lower() or self.path.endswith(".m3u8"):
                    text = body.decode("utf-8", errors="replace")
                    text = text.replace(UPSTREAM_BASE, "")
                    body = text.encode("utf-8")

                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Access-Control-Allow-Origin", "*")
                # Forward cache headers
                for hdr in ["Cache-Control", "ETag", "Last-Modified"]:
                    val = resp.getheader(hdr)
                    if val:
                        self.send_header(hdr, val)
                self.end_headers()
                self.wfile.write(body)

        except urllib.error.HTTPError as e:
            print(f"       <- HTTP Error {e.code}: {e.reason}")
            self.send_response(e.code)
            self.end_headers()
            self.wfile.write(e.read())
        except Exception as e:
            print(f"       <- Error: {e}")
            self.send_response(502)
            self.end_headers()
            self.wfile.write(f"Proxy error: {e}".encode())

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress default logging, we do our own


def main():
    parser = argparse.ArgumentParser(description="HLS Proxy with request logging")
    parser.add_argument("--port", type=int, default=8080, help="Port to listen on (default: 8080)")
    parser.add_argument("--host", default="0.0.0.0", help="Host to bind to (default: 0.0.0.0)")
    args = parser.parse_args()

    server = HTTPServer((args.host, args.port), ProxyHandler)
    print(f"HLS Proxy started")
    print(f"  Upstream:  {UPSTREAM_URL}")
    print(f"  Local URL: http://localhost:{args.port}/index.m3u8")
    print(f"  Network:   http://<your-ip>:{args.port}/index.m3u8")
    print()

    # Try to show the local network IP
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        print(f"  Detected LAN IP: http://{ip}:{args.port}/index.m3u8")
    except Exception:
        pass

    print(f"\nListening on {args.host}:{args.port} ... (Ctrl+C to stop)\n")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(f"\nStopped. Total requests handled: {request_counter}")
        server.server_close()


if __name__ == "__main__":
    main()
