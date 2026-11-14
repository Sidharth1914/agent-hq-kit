"""Stop hook for live chats (Remote Control) on the VM.

After every reply it appends the user's message and Claude's answer to
~/results/chat/<date> <session>.md, on the server, a plain-text log of every chat. When a reply took 3 minutes or more it also
sends an ntfy push (no answer text, only "reply ready"), so the phone buzzes for long jobs.

Does nothing on the cloud runner, the laptop, or the issue worker (HQ_RUNNER=1).
"""
import json
import os
import sys
import urllib.request
from datetime import datetime
from pathlib import Path

RESULTS = Path.home() / "results"
LONG = 180  # seconds


def text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(c.get("text", "") for c in content or [] if c.get("type") == "text")


def last_turn(lines):
    """(user text, answer text, seconds) for the last turn of a transcript (list of dicts)."""
    start = None
    for i, d in enumerate(lines):
        t = text_of(d.get("message", {}).get("content")).strip()
        if d.get("type") == "user" and t and not d.get("isMeta") and not t.startswith(("<command-", "<local-command")):
            start = i  # a real user message, not a tool result, slash-command echo or injected context
    if start is None:
        return None
    user = text_of(lines[start]["message"]["content"]).strip()
    answer = "\n\n".join(t for d in lines[start + 1:] if d.get("type") == "assistant"
                         for t in [text_of(d.get("message", {}).get("content")).strip()] if t)
    def ts(d):
        try:
            return datetime.fromisoformat(d["timestamp"].replace("Z", "+00:00"))
        except (KeyError, ValueError):
            return None
    t0, t1 = ts(lines[start]), ts(lines[-1])
    return user, answer, (t1 - t0).total_seconds() if t0 and t1 else 0


def topic():
    if os.environ.get("NTFY_TOPIC"):
        return os.environ["NTFY_TOPIC"]
    env = Path.home() / "agent-hq" / ".env"
    for line in env.read_text().splitlines() if env.exists() else []:
        if line.startswith("NTFY_TOPIC="):
            return line.split("=", 1)[1].strip()
    return ""


def in_hq(cwd, home=None):
    """True for ~/agent-hq and folders inside it (worktrees), not for look-alikes such as ~/agent-hq-old."""
    hq = (home or Path.home()) / "agent-hq"
    return bool(cwd) and (Path(cwd) == hq or hq in Path(cwd).parents)


def main():
    if os.environ.get("HQ_RUNNER") or not RESULTS.is_dir():
        return
    hook = json.load(sys.stdin)
    if not in_hq(hook.get("cwd", "")):
        return  # user-level hook: skip other Claude runs on this machine
    lines = [json.loads(l) for l in open(hook["transcript_path"], encoding="utf-8") if l.strip()]
    turn = last_turn(lines)
    if not turn or not turn[1]:
        return
    user, answer, secs = turn
    sid = hook.get("session_id", "chat")[:8]
    first = next((d["timestamp"][:10] for d in lines if d.get("timestamp")), datetime.now().strftime("%Y-%m-%d"))
    out = RESULTS / "chat" / f"{first} {sid}.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("a", encoding="utf-8") as f:
        f.write(f"## {datetime.now():%d %b %H:%M} · You\n\n{user}\n\n### Answer\n\n{answer}\n\n---\n\n")
    if secs >= LONG and topic():
        # No answer text in the push: ntfy.sh is a public service and the topic name is its only lock.
        body = f"✅ Chat reply ready ({int(secs // 60)} min). Open the Agent HQ chat.".encode()
        req = urllib.request.Request(f"https://ntfy.sh/{topic()}", data=body, headers={"Title": "Agent HQ"})
        try:
            urllib.request.urlopen(req, timeout=10)
        except OSError:
            pass


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        tl = [{"type": "user", "timestamp": "2026-11-13T10:00:00Z", "message": {"content": "old"}},
              {"type": "user", "timestamp": "2026-11-13T10:01:00Z", "message": {"content": "hi"}},
              {"type": "assistant", "timestamp": "2026-11-13T10:02:00Z", "message": {"content": [{"type": "tool_use"}]}},
              {"type": "user", "timestamp": "2026-11-13T10:03:00Z", "message": {"content": [{"type": "tool_result"}]}},
              {"type": "assistant", "timestamp": "2026-11-13T10:05:00Z", "message": {"content": [{"type": "text", "text": "done"}]}}]
        assert last_turn(tl) == ("hi", "done", 240.0), last_turn(tl)
        tl.append({"type": "user", "isMeta": True, "message": {"content": "injected"}})
        tl.append({"type": "user", "message": {"content": "<local-command-stdout>ok</local-command-stdout>"}})
        assert last_turn(tl)[0] == "hi", "meta and slash-command lines are not user turns"
        h = Path("/home/u")
        assert in_hq("/home/u/agent-hq", h) and in_hq("/home/u/agent-hq/.claude/worktrees/x", h)
        assert not in_hq("/home/u/agent-hq-old", h) and not in_hq("", h) and not in_hq("/home/u", h)
        print("selftest ok")
    else:
        try:
            main()
        except Exception as e:  # a hook must never break the chat
            print(f"chat_hook: {e}", file=sys.stderr)
