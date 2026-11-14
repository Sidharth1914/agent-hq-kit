#!/usr/bin/env python3
"""Live status of the Agent HQ team, for the animated page deploy/status/index.html.

    python3 deploy/hq_status.py --serve /run/hq-status/hq.sock  # VM service hq-status; tailscale serve exposes it
    python3 deploy/hq_status.py --once                   # print the JSON once
    python3 deploy/hq_status.py --selftest

What it reads, all on the VM, read-only:
- Claude transcripts (~/.claude/projects/*/*.jsonl) changed in the last 15 minutes. Each is one agent session:
  live chat, worker job or trader review. Its newest tool call is "what it is doing now". Agent/Task calls
  without a result yet are running subagents.
- GitHub issues in agent-hq (open; cached 60 s): the job queue and which runner holds each job.
- systemd: core services and trader-* timers.
- ntfy: the last pushes on the user's topic (the activity feed).
Texts are cut short. The page is served on the tailnet only (never public): it shows job titles and commands.
Standard library only.
"""
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request
import socketserver
from http.server import BaseHTTPRequestHandler
from pathlib import Path

HOME = Path.home()
PROJECTS = HOME / ".claude" / "projects"
PAGE = Path(__file__).resolve().parent / "status" / "index.html"
try:
    _url = subprocess.run(["git", "-C", str(Path(__file__).resolve().parent), "remote", "get-url", "origin"],
                          capture_output=True, text=True).stdout.strip()
except OSError:
    _url = ""
REPO = os.environ.get("HQ_REPO") or (_url.split("github.com", 1)[-1].strip(":/").removesuffix(".git")
                                     if "github.com" in _url else "")
ACTIVE = 15 * 60      # a session counts as live while its transcript changed this recently
CORE = ["agent-hq-remote.service", "agent-hq-worker.timer", "tailscaled.service", "hq-watch.timer"]
SUBAGENT_TOOLS = {"Agent", "Task"}


def cut(text, n=110):
    text = " ".join(str(text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(c.get("text", "") for c in content or [] if isinstance(c, dict) and c.get("type") == "text")


def describe_tool(name, inp):
    """Short human line for a tool call."""
    inp = inp or {}
    if name == "Bash":
        return "Running: " + cut(inp.get("description") or inp.get("command"), 90)
    if name in ("Read", "Edit", "Write", "NotebookEdit"):
        verb = {"Read": "Reading", "Edit": "Editing", "Write": "Writing", "NotebookEdit": "Editing"}[name]
        return f"{verb} {Path(str(inp.get('file_path', ''))).name}"
    if name in ("Grep", "Glob"):
        return "Searching: " + cut(inp.get("pattern"), 60)
    if name in ("WebFetch", "WebSearch"):
        return "Web: " + cut(inp.get("query") or inp.get("url"), 70)
    if name in SUBAGENT_TOOLS:
        return "Delegating: " + cut(inp.get("description"), 70)
    return name.replace("mcp__", "").replace("__", " · ")


def parse_session(lines):
    """One transcript (list of dicts) -> dict with kind, task, doing, subagents, tools count."""
    first_user, last_user, doing, last_ts = "", "", "", ""
    pending, tools = {}, 0
    for d in lines:
        last_ts = d.get("timestamp", last_ts)
        msg = d.get("message") or {}
        content = msg.get("content")
        if d.get("type") == "user":
            t = text_of(content).strip()
            if t and not d.get("isMeta") and not t.startswith(("<command-", "<local-command", "<system-reminder")):
                first_user = first_user or t
                last_user = t
                doing = "Thinking"
            for c in content if isinstance(content, list) else []:
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    pending.pop(c.get("tool_use_id"), None)
        elif d.get("type") == "assistant":
            for c in content if isinstance(content, list) else []:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use":
                    tools += 1
                    doing = describe_tool(c.get("name", ""), c.get("input"))
                    if c.get("name") in SUBAGENT_TOOLS:
                        inp = c.get("input") or {}
                        pending[c.get("id")] = {"role": inp.get("subagent_type") or "general",
                                                "task": cut(inp.get("description") or inp.get("prompt"), 70)}
                elif c.get("type") == "text" and c.get("text", "").strip():
                    doing = "Answering"
    if lines and lines[-1].get("type") == "assistant" and doing == "Answering":
        doing = "Done, waiting for you"
    kind = "worker" if first_user.startswith("You are the Agent HQ") else "chat"
    task, issue = first_user, None
    if kind == "worker":
        for line in first_user.splitlines():
            if line.startswith("Job:"):
                task = line.split("titled:", 1)[-1]
                num = line.split("#", 1)[-1].split()[0] if "#" in line else ""
                issue = int(num) if num.isdigit() else None
    return {"kind": kind, "task": cut(task if kind == "worker" else last_user, 120), "doing": cut(doing, 110),
            "subagents": list(pending.values()), "tools": tools, "last": last_ts, "issue": issue}


def sessions(now=None):
    now = now or time.time()
    out = []
    for f in PROJECTS.glob("*/*.jsonl"):
        try:
            age = now - f.stat().st_mtime
            if age > ACTIVE or f.stat().st_size == 0:
                continue
            lines = []
            for raw in f.read_text(encoding="utf-8", errors="replace").splitlines()[-4000:]:
                try:
                    lines.append(json.loads(raw))
                except ValueError:
                    pass
        except OSError:
            continue
        s = parse_session(lines)
        if "trader" in f.parent.name:
            s["kind"] = "trader"
        s.update(id=f.stem[:8], idle_s=int(age), busy=age < 90)
        out.append(s)
    return sorted(out, key=lambda s: s["idle_s"])


def run(cmd, timeout=20):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def services():
    out = {}
    for u in CORE:
        if run(["systemctl", "is-enabled", u]).strip() not in ("enabled", "static", "indirect", "alias"):
            continue  # not installed here (for example no Tailscale): leave it off the page
        out[u.split(".")[0]] = run(["systemctl", "is-active", u]).strip() or "unknown"
    trader = []
    for line in run(["systemctl", "list-timers", "trader-*", "--all", "--no-legend", "--plain"]).splitlines():
        parts = line.split()
        unit = next((p for p in parts if p.endswith(".timer")), "")
        if unit:
            nxt = " ".join(parts[:4]) if parts[0] not in ("-", "n/a") else "-"
            trader.append({"name": unit.replace("trader-", "").replace(".timer", ""), "next": cut(nxt, 30)})
    running = [l.split()[0].replace("trader-", "").replace(".service", "")
               for l in run(["systemctl", "list-units", "trader-*.service", "--state=activating", "--no-legend",
                             "--plain"]).splitlines() if l.strip()]
    mem = {}
    for line in Path("/proc/meminfo").read_text().splitlines() if Path("/proc/meminfo").exists() else []:
        k, v = line.split(":", 1)
        mem[k] = int(v.split()[0]) // 1024
    return {"core": out, "trader": trader, "trader_running": running,
            "mem": {"total": mem.get("MemTotal", 0), "available": mem.get("MemAvailable", 0)},
            "swap": {"total": mem.get("SwapTotal", 0), "free": mem.get("SwapFree", 0)}, "cpus": os.cpu_count() or 1,
            "load": os.getloadavg()[0] if hasattr(os, "getloadavg") else 0}


_cache = {"issues": (0, []), "feed": (0, [])}


def env_value(key):
    if os.environ.get(key):
        return os.environ[key]
    try:
        for line in (HOME / "agent-hq" / ".env").read_text().splitlines():
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def issues():
    t, data = _cache["issues"]
    if time.time() - t < 60:
        return data
    raw = run(["gh", "issue", "list", "-R", REPO, "--state", "all", "--limit", "15",
               "--json", "number,title,labels,state,updatedAt"], timeout=30)
    try:
        data = [{"n": i["number"], "title": cut(i["title"], 80), "state": i["state"],
                 "labels": [l["name"] for l in i["labels"]], "updated": i["updatedAt"]} for i in json.loads(raw)]
    except ValueError:
        pass  # keep the last good list
    _cache["issues"] = (time.time(), data)
    return data


def feed():
    t, data = _cache["feed"]
    if time.time() - t < 30:
        return data
    topic = env_value("NTFY_TOPIC")
    if topic:
        try:
            with urllib.request.urlopen(f"https://ntfy.sh/{topic}/json?poll=1&since=24h", timeout=10) as r:
                data = [{"t": j["time"], "msg": cut(j.get("message"), 120)}
                        for j in map(json.loads, r.read().decode("utf-8").splitlines()) if j.get("event") == "message"]
                data = data[-25:][::-1]
        except (OSError, ValueError):
            pass
    _cache["feed"] = (time.time(), data)
    return data


def status():
    return {"now": time.time(), "sessions": sessions(), "issues": issues(), "feed": feed(), "vm": services()}


def tailnet_owner():
    """Login name of this machine's Tailscale user (the tailnet owner), or '' if unknown."""
    try:
        st = json.loads(run(["tailscale", "status", "--json"]) or "{}")
        return st["User"][str(st["Self"]["UserID"])]["LoginName"]
    except (KeyError, TypeError, ValueError):
        return ""


OWNER_LOGIN = ""


def allowed(headers, owner):
    """Only the tailnet owner, through `tailscale serve` (which adds Tailscale-User-Login and strips any
    client-sent copy). The header alone is spoofable by a local process, so the server listens on a
    Unix socket with mode 0600 (owner: the Agent HQ user): only root (tailscaled) and that user can connect.
    That user can read the transcripts directly anyway, so the page gives it nothing new."""
    return bool(owner) and headers.get("Tailscale-User-Login", "") == owner


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if not allowed(self.headers, OWNER_LOGIN):
            self.send_error(403)
            return
        if self.path.startswith("/status.json"):
            body, ctype = json.dumps(status()).encode(), "application/json"
        elif self.path in ("/", "/index.html"):
            body, ctype = PAGE.read_bytes(), "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


_lock = threading.Lock()
_orig_status = status


def status():  # noqa: F811  one collection at a time; parallel requests share it
    with _lock:
        return _orig_status()


def selftest():
    tl = [{"type": "user", "timestamp": "a", "message": {"content": "You are the Agent HQ VM runner.\nJob: issue #4 in x (u), titled: Build report"}},
          {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Agent",
                                                          "input": {"subagent_type": "researcher", "description": "Find data"}}]}},
          {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t2", "name": "Bash",
                                                          "input": {"command": "pytest -q", "description": "Run tests"}}]}}]
    s = parse_session(tl)
    assert s["kind"] == "worker" and s["task"].strip() == "Build report" and s["issue"] == 4, s
    assert s["doing"] == "Running: Run tests" and s["subagents"] == [{"role": "researcher", "task": "Find data"}], s
    tl.append({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1"}]}})
    assert parse_session(tl)["subagents"] == [], "a subagent with a result is finished"
    c = parse_session([{"type": "user", "message": {"content": "<command-name>/x</command-name>"}},
                       {"type": "user", "message": {"content": "make the district report"}},
                       {"type": "assistant", "message": {"content": [{"type": "text", "text": "Done."}]}}])
    assert c["kind"] == "chat" and c["task"] == "make the district report" and c["doing"] == "Done, waiting for you", c
    assert allowed({"Tailscale-User-Login": "me@x"}, "me@x")
    assert not allowed({}, "me@x") and not allowed({"Tailscale-User-Login": "other@x"}, "me@x")
    assert not allowed({"Tailscale-User-Login": ""}, ""), "unknown owner means nobody gets in"
    assert cut("a" * 200, 10).endswith("…") and len(cut("a" * 200, 10)) == 10
    print("selftest ok")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        selftest()
    elif sys.argv[1:2] == ["--once"]:
        print(json.dumps(status(), indent=1))
    elif sys.argv[1:2] == ["--serve"]:
        path = sys.argv[2] if len(sys.argv) > 2 else "/run/hq-status/hq.sock"
        OWNER_LOGIN = tailnet_owner()
        if not OWNER_LOGIN:
            sys.exit("hq_status: cannot read the tailnet owner from `tailscale status --json`; refusing to serve")

        class UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
            daemon_threads = True

            def get_request(self):
                conn, _ = super().get_request()
                return conn, ("unix", 0)  # BaseHTTPRequestHandler expects (host, port)

        if os.path.exists(path):
            os.unlink(path)
        old = os.umask(0o177)  # socket created as 0600: nobody but this user (and root) can connect
        try:
            srv = UnixServer(path, Handler)
        finally:
            os.umask(old)
        srv.serve_forever()
    else:
        print(__doc__)
