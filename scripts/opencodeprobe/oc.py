#!/usr/bin/env python3
"""Tiny OpenCode HTTP client for probes: oc.py METHOD PATH [JSON-BODY] [directory=DIR]

Reads the server from $OC_URL (default http://127.0.0.1:47940) and its password from
$OC_PASSWORD. Prints `<status> <body>`.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def call(method, path, body=None, **query):
    base = os.environ.get("OC_URL", "http://127.0.0.1:47940")
    url = base + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    password = os.environ.get("OC_PASSWORD")
    if password:
        token = base64.b64encode(f"opencode:{password}".encode()).decode()
        request.add_header("Authorization", "Basic " + token)
    try:
        with urllib.request.urlopen(request, timeout=float(os.environ.get("OC_TIMEOUT", "15"))) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode(errors="replace")


if __name__ == "__main__":
    args = sys.argv[1:]
    query = dict(a.split("=", 1) for a in args if a.startswith("directory="))
    rest = [a for a in args if not a.startswith("directory=")]
    method, path = rest[0], rest[1]
    body = json.loads(rest[2]) if len(rest) > 2 else None
    status, payload = call(method, path, body, **query)
    print(status, json.dumps(payload))
