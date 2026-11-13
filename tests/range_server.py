"""Serve a directory over HTTP with Range support for the update tests.

Usage: range_server.py ROOT PORT_FILE. Every GET is appended to ROOT/requests.log. ROOT/faults
lists PATH:START ranges to refuse with 503, and ROOT/slow lists paths to answer after 1.5 seconds.
The server also works as an HTTP proxy for itself: a request that names a whole URL, as one
sent through a proxy does, is served by its path and logged with " via proxy" at the end.
The chosen port is written to PORT_FILE once the server is listening. The server exits once
ROOT is removed, so a test that loses track of the process does not leave it running.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import re
import sys
import threading
import time
from urllib.parse import urlsplit

root, port_file = sys.argv[1:]


def exit_without_root():
    while os.path.isdir(root):
        time.sleep(0.5)
    os._exit(0)


def listed(name):
    try:
        with open(os.path.join(root, name)) as file:
            return file.read().split()
    except FileNotFoundError:
        return []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        target = urlsplit(self.path)
        path = target.path
        match = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        with open(os.path.join(root, "requests.log"), "a") as log:
            log.write("%s %s%s\n" % (path, match.group(0) if match else "-", " via proxy" if target.scheme else ""))
        if path in listed("slow"):
            time.sleep(1.5)
        if match and "%s:%s" % (path, match.group(1)) in listed("faults"):
            return self.send_error(503)
        file_path = os.path.join(root, path.lstrip("/"))
        if not os.path.isfile(file_path):
            return self.send_error(404)
        with open(file_path, "rb") as file:
            data = file.read()
        if match:
            start, end = int(match.group(1)), min(int(match.group(2)), len(data) - 1)
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, len(data)))
            data = data[start:end + 1]
        else:
            self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=exit_without_root, daemon=True).start()
with open(port_file + ".tmp", "w") as file:
    file.write(str(server.server_address[1]))
os.replace(port_file + ".tmp", port_file)
server.serve_forever()
