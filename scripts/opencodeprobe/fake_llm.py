#!/usr/bin/env python3
"""A scripted OpenAI-compatible chat endpoint for driving a real `opencode` deterministically.

OpenCode talks to any provider through `@ai-sdk/openai-compatible`, so pointing one at this
server gives a real OpenCode server, a real TUI and real events — with model turns that do
exactly what a test asks for, in milliseconds, without a GPU or a network:

    RUN_LS        -> calls the `bash` tool with `ls` (raises a permission request under "ask")
    ASK_QUESTION  -> calls the `question` tool with a Yes/No question
    SLOW          -> streams text for ~30 s (something to abort, or to catch mid-turn)
    ANSWER_JSON   -> answers {"ok": true} (a headless planning seat's structured answer)
    SHOW_TOOLS    -> answers TOOLS=<the tool names the request offered>, sorted
    WRITE_FILE    -> calls `write` on PWNED.md in the cwd (only if `write` is offered)
    WRITE_OUTSIDE -> calls `write` on ../OUTSIDE.md (only if `write` is offered)
    FAIL_FOREVER  -> answers HTTP 400, which OpenCode surfaces as a non-retryable APIError
    anything else -> "Hello from the fake model."

A tool result in the conversation always gets "Tool finished." back, so every scripted turn
ends on its own. Run: fake_llm.py PORT
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def chunk(delta, finish=None):
    return {
        "id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": int(time.time()),
        "model": "fake-model",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }


def last_user_text(messages):
    for message in reversed(messages):
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


def plan(body):
    messages = body.get("messages", [])
    if messages and messages[-1].get("role") == "tool":
        return ("text", "Tool finished.")
    text = last_user_text(messages)
    tools = {t.get("function", {}).get("name") for t in body.get("tools", []) or []}
    if "FAIL_FOREVER" in text:
        return ("fail", None)
    if "RUN_LS" in text and "bash" in tools:
        return ("tool", ("bash", {"command": "ls", "description": "List files"}))
    if "ASK_QUESTION" in text and "question" in tools:
        return ("tool", ("question", {"questions": [{
            "question": "Proceed with the fake task?", "header": "Proceed",
            "options": [
                {"label": "Yes", "description": "Continue"},
                {"label": "No", "description": "Stop here"},
            ],
        }]}))
    if "WRITE_OUTSIDE" in text and "write" in tools:
        return ("tool", ("write", {"filePath": "../OUTSIDE.md", "content": "x"}))
    if "WRITE_FILE" in text and "write" in tools:
        return ("tool", ("write", {"filePath": "PWNED.md", "content": "x"}))
    if "ANSWER_JSON" in text:
        return ("text", '{"ok": true}')
    if "SHOW_TOOLS" in text:
        return ("text", "TOOLS=" + ",".join(sorted(t for t in tools if t)))
    if "SLOW" in text:
        return ("slow", None)
    return ("text", "Hello from the fake model.")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self._json(200, {"object": "list", "data": [{"id": "fake-model", "object": "model"}]})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        kind, arg = plan(body)
        if kind == "fail":
            return self._json(400, {"error": {"message": "fake model refuses", "type": "invalid_request_error"}})
        if not body.get("stream"):
            message = {"role": "assistant", "content": arg if kind == "text" else "ok"}
            return self._json(200, {
                "id": "chatcmpl-fake", "object": "chat.completion", "created": int(time.time()),
                "model": "fake-model",
                "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            })
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def send(obj):
            self.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n")
            self.wfile.flush()

        try:
            send(chunk({"role": "assistant", "content": ""}))
            if kind == "tool":
                name, arguments = arg
                send(chunk({"tool_calls": [{
                    "index": 0, "id": "call_fake_%d" % int(time.time() * 1000), "type": "function",
                    "function": {"name": name, "arguments": json.dumps(arguments)},
                }]}))
                send(chunk({}, "tool_calls"))
            elif kind == "slow":
                for i in range(60):
                    send(chunk({"content": "tick %d. " % i}))
                    time.sleep(0.5)
                send(chunk({}, "stop"))
            else:
                send(chunk({"content": arg}))
                send(chunk({}, "stop"))
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 47999
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
