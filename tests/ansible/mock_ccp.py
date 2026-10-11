#!/usr/bin/env python3
"""TEST ONLY: minimal stand-in for the CyberArk CCP REST endpoint.

GET /AIMWebService/api/Accounts?AppId=<id>&Query=Safe=<s>;Object=<o>
  - no Query           -> 400 (what a real CCP answers to a bare request)
  - wrong AppId        -> 403
  - unknown object     -> 404
  - known object       -> 200 {"UserName": ..., "Content": ..., "Safe": ..., "Name": ...}

Usage: mock_ccp.py <port> <accounts.json> [app_id]
accounts.json maps "<safe>/<object>" to {"UserName": "...", "Content": "..."}.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

PORT = int(sys.argv[1])
ACCOUNTS = json.load(open(sys.argv[2], encoding="utf-8"))
APP_ID = sys.argv[3] if len(sys.argv) > 3 else "MUREX_IT"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        url = urlsplit(self.path)
        if url.path.rstrip("/") != "/AIMWebService/api/Accounts":
            return self._send(404, {"ErrorCode": "APPAP000E", "ErrorMsg": "not found"})
        qs = parse_qs(url.query)
        if qs.get("AppId", [""])[0] != APP_ID:
            return self._send(403, {"ErrorCode": "APPAP306E", "ErrorMsg": "AppId not authorized"})
        query = qs.get("Query", [""])[0]
        if not query:
            return self._send(400, {"ErrorCode": "APPAP227E", "ErrorMsg": "Query is missing"})
        parts = dict(p.split("=", 1) for p in query.split(";") if "=" in p)
        key = f"{parts.get('Safe', '')}/{parts.get('Object', '')}"
        if key not in ACCOUNTS:
            return self._send(404, {"ErrorCode": "APPAP004E", "ErrorMsg": f"Password object matching query [{query}] was not found"})
        acct = ACCOUNTS[key]
        return self._send(200, {"UserName": acct["UserName"], "Content": acct["Content"],
                                "Safe": parts["Safe"], "Name": parts["Object"]})

    def log_message(self, fmt, *args):
        # Log the query, never the response.
        sys.stderr.write("mock_ccp %s\n" % (fmt % args))


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
