#!/usr/bin/env python3
"""End-to-end tests for Buddy.app on macOS.

Runs the real app next to a full-screen stand-in presentation and checks the use
cases: background menu bar app, trigger phrases, dialog with Claude (local mock
server that validates every request), Swedish speech with lip sync, the avatar on
top of the presentation, end phrases, several moments, scripted lines, fallback
when Claude fails, and that Buddy does not hear itself.

Modes:
  inject  Sentences are delivered to Buddy as recognized text. No microphone.
  audio   Sentences are spoken with a Swedish macOS voice into a virtual
          microphone (BlackHole) and go through real speech recognition.
  live    Like inject, but against the real Claude API (needs ANTHROPIC_API_KEY).

Usage:
  python3 e2e/run_e2e.py --app build/Buddy.app --mode inject --out build/e2e/inject
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCENARIO = ROOT / "e2e" / "scenario.json"
SLIDE_COLOR = (20, 41, 110)
API_VERSION = "2026-10-21"
FALLBACK_BETA = "server-side-fallback-2026-07-01"
OVERLAY_MARGIN = 28
AVATAR_SIZE = 220

MOCK_REPLIES = {
    "Introduktion": [
        "Hej allihop! Jag är Buddy, talarens lilla AI-kompis. Jag har läst hela internet men förstår mig fortfarande inte på måndagar.",
        "Läskigt? Nej då, jag är mest bra på tråkiga saker. Som att sortera mejl och komma ihåg födelsedagar.",
        "Det tycker jag också. Nu får du fortsätta!",
    ],
    "Kan AI ta jobben?": [
        "AI tar gärna över de tråkiga uppgifterna. Men människor behövs för allt som kräver omdöme och hjärta.",
    ],
    "Improvisation": [
        "Ha, där fick du mig! Jag håller helt med dig.",
    ],
}
DEFAULT_REPLY = "Det låter klokt. Jag håller med!"

USE_CASES = {
    "UC1": "Ligger i bakgrunden som menyradsapp utan Dock-ikon",
    "UC2": "Lyssnar via mikrofonen och reagerar inte på vanligt tal",
    "UC3": "En triggerfras startar en dialog",
    "UC4": "Avataren dyker upp i hörnet ovanpå en presentation i helskärm",
    "UC5": "Buddy pratar svenska och munnen rör sig i takt med rösten",
    "UC6": "Dialogen följer manuset och fortsätter med flera repliker",
    "UC7": "En avslutsfras avslutar dialogen och avataren försvinner",
    "UC8": "Flera triggerfraser och avslutsfraser",
    "UC9": "Flera moment i en presentation, i ordning eller med egen trigger",
    "UC10": "Manusläge säger replikerna ordagrant utan Claude",
    "UC11": "Fortsätter prata (reservreplik) om Claude inte svarar",
    "UC12": "Buddy hör inte sin egen röst",
    "UC13": "Presentationen konfigureras med en JSON-fil",
}


class TestFailure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise TestFailure(message)


def normalize(text):
    return re.sub(r"\s+", " ", text or "").strip()


# ---------------------------------------------------------------------------
# Mock Claude Messages API


def validate_request(headers, body):
    """Problems with a Messages API request, as the real API would see them."""
    problems = []
    if not headers.get("x-api-key"):
        problems.append("missing x-api-key header")
    if headers.get("anthropic-version") != API_VERSION:
        problems.append("anthropic-version is %r, expected %r" % (headers.get("anthropic-version"), API_VERSION))
    if "application/json" not in headers.get("content-type", ""):
        problems.append("content-type is not application/json")
    if not isinstance(body, dict):
        return problems + ["body is not a JSON object"]
    model = body.get("model")
    if not isinstance(model, str) or not model.startswith("claude-"):
        problems.append("model is %r" % model)
        model = ""
    max_tokens = body.get("max_tokens")
    if not isinstance(max_tokens, int) or max_tokens <= 0:
        problems.append("max_tokens is %r" % max_tokens)
    if body.get("stream") is not True:
        problems.append("stream must be true")
    for key in ("temperature", "top_p", "top_k"):
        if key in body:
            problems.append("%s is rejected on API version %s" % (key, API_VERSION))
    thinking = body.get("thinking")
    if isinstance(thinking, dict) and thinking.get("type") in ("disabled", "enabled"):
        problems.append("thinking type %r is rejected by current models" % thinking.get("type"))
    effort = (body.get("output_config") or {}).get("effort")
    if effort not in ("low", "medium", "high", "xhigh", "max"):
        problems.append("output_config.effort is %r" % effort)
    system = body.get("system")
    if not isinstance(system, str) or not system.strip():
        problems.append("system prompt missing")
    messages = body.get("messages")
    if not isinstance(messages, list) or not messages:
        problems.append("messages missing")
    else:
        for index, message in enumerate(messages):
            expected = "user" if index % 2 == 0 else "assistant"
            if not isinstance(message, dict) or message.get("role") != expected:
                problems.append("messages[%d] should have role %s" % (index, expected))
                continue
            content = message.get("content")
            if not isinstance(content, str) or not content.strip():
                problems.append("messages[%d] has empty content" % index)
        if isinstance(messages[-1], dict) and messages[-1].get("role") != "user":
            problems.append("last message must be from the user")
    takes_fallback = model.startswith(("claude-opus-5", "claude-sonnet-5-5", "claude-fable-5"))
    beta = headers.get("anthropic-beta", "")
    if takes_fallback:
        if body.get("fallbacks") != "default":
            problems.append('fallbacks should be "default" for %s' % model)
        if FALLBACK_BETA not in beta:
            problems.append("anthropic-beta should include %s" % FALLBACK_BETA)
    elif "fallbacks" in body:
        problems.append("fallbacks is not supported for %s" % model)
    return problems


def moment_title(body):
    system = (body or {}).get("system") or ""
    match = re.search(r"## Det här momentet: (.+)", system)
    return match.group(1).strip() if match else ""


class MockClaude:
    """Streams scripted replies in the Messages API's server-sent event format."""

    def __init__(self):
        self.requests = []
        self.fail_next = 0
        self.turns = {}
        self.lock = threading.Lock()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        return "http://127.0.0.1:%d/v1/messages" % self.port

    def start(self):
        self.thread.start()

    def stop(self):
        self.server.shutdown()

    def count(self):
        with self.lock:
            return len(self.requests)

    def wait_for_request(self, index, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if len(self.requests) > index:
                    return self.requests[index]
            time.sleep(0.1)
        raise TestFailure("Claude received no request #%d within %ds" % (index + 1, timeout))

    def _handler(self):
        mock = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                length = int(self.headers.get("content-length") or 0)
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw)
                except ValueError:
                    body = None
                headers = {k.lower(): v for k, v in self.headers.items()}
                problems = validate_request(headers, body)
                moment = moment_title(body)
                with mock.lock:
                    failing = mock.fail_next > 0
                    if failing:
                        mock.fail_next -= 1
                        reply = None
                    else:
                        turn = mock.turns.get(moment, 0)
                        mock.turns[moment] = turn + 1
                        replies = MOCK_REPLIES.get(moment) or [DEFAULT_REPLY]
                        reply = replies[min(turn, len(replies) - 1)]
                    mock.requests.append({
                        "headers": headers,
                        "body": body,
                        "problems": problems,
                        "moment": moment,
                        "reply": reply,
                        "failed": failing,
                    })
                if failing:
                    payload = json.dumps({"type": "error", "error": {"type": "api_error", "message": "Mock failure"}}).encode()
                    self.send_response(500)
                    self.send_header("content-type", "application/json")
                    self.send_header("content-length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.send_header("cache-control", "no-cache")
                self.end_headers()
                model = (body or {}).get("model", "claude")

                def event(name, data):
                    chunk = "event: %s\ndata: %s\n\n" % (name, json.dumps(data, ensure_ascii=False))
                    self.wfile.write(chunk.encode("utf-8"))
                    self.wfile.flush()

                event("message_start", {"type": "message_start", "message": {
                    "id": "msg_mock", "type": "message", "role": "assistant", "model": model,
                    "content": [], "stop_reason": None, "usage": {"input_tokens": 50, "output_tokens": 1}}})
                # Adaptive thinking with display "omitted": an empty thinking block first.
                event("content_block_start", {"type": "content_block_start", "index": 0,
                                              "content_block": {"type": "thinking", "thinking": "", "signature": ""}})
                event("content_block_delta", {"type": "content_block_delta", "index": 0,
                                              "delta": {"type": "signature_delta", "signature": "mock"}})
                event("content_block_stop", {"type": "content_block_stop", "index": 0})
                event("ping", {"type": "ping"})
                event("content_block_start", {"type": "content_block_start", "index": 1,
                                              "content_block": {"type": "text", "text": ""}})
                for start in range(0, len(reply), 11):
                    time.sleep(0.03)
                    event("content_block_delta", {"type": "content_block_delta", "index": 1,
                                                  "delta": {"type": "text_delta", "text": reply[start:start + 11]}})
                event("content_block_stop", {"type": "content_block_stop", "index": 1})
                event("message_delta", {"type": "message_delta",
                                        "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                        "usage": {"output_tokens": 40}})
                event("message_stop", {"type": "message_stop"})

        return Handler


# ---------------------------------------------------------------------------
# Helpers that run on the Mac


def run(args, check_result=True, capture=True):
    return subprocess.run(args, check=check_result, capture_output=capture, text=True)


def build_tools(folder):
    folder.mkdir(parents=True, exist_ok=True)
    tools = {}
    for name in ("Probe", "PresentationStub"):
        target = folder / name
        source = ROOT / "e2e" / "tools" / ("%s.swift" % name)
        if not target.exists() or target.stat().st_mtime < source.stat().st_mtime:
            run(["swiftc", "-parse-as-library", "-O", str(source), "-o", str(target)])
        tools[name] = target
    return tools


def swedish_voice():
    output = run(["say", "-v", "?"]).stdout
    for line in output.splitlines():
        match = re.match(r"^(.+?)\s+([a-z]{2}[_-][A-Z]{2})\s+#", line)
        if match and match.group(2).lower().startswith("sv"):
            return match.group(1).strip()
    return None


def window_list(tools):
    return json.loads(run([str(tools["Probe"]), "windows"]).stdout)


def region_stats(tools, png, screen_width, rect, color=SLIDE_COLOR):
    x, y, w, h = rect
    args = [str(tools["Probe"]), "region", str(png), str(screen_width)] + [str(v) for v in (x, y, w, h)] + [str(c) for c in color]
    return json.loads(run(args).stdout)


def screenshot(path):
    run(["screencapture", "-x", "-t", "png", str(path)], check_result=False)
    return path if Path(path).exists() else None


# ---------------------------------------------------------------------------
# Buddy under test


class Buddy:
    def __init__(self, args, workdir, mock_url, voice):
        self.app = Path(args.app).resolve()
        self.mode = args.mode
        self.dir = workdir
        self.voice = voice
        self.device = args.audio_device
        self.mock_url = mock_url
        self.events = []
        self.offset = 0
        self.log_path = workdir / "events.jsonl"
        self.inbox = workdir / "inbox.jsonl"
        self.commands = workdir / "commands.jsonl"
        self.data = workdir / "data"
        self.slow = 2.5 if self.mode == "audio" else 1.0
        self.pid = None

    def launch(self):
        for path in (self.inbox, self.commands):
            path.write_text("")
        env = {
            "BUDDY_DATA_DIR": str(self.data),
            "BUDDY_EVENT_LOG": str(self.log_path),
            "BUDDY_SESSION_FILE": str(SCENARIO),
            "BUDDY_COMMANDS": str(self.commands),
            "BUDDY_SET_corner": "bottomRight",
            "BUDDY_SET_screen": "main",
            "BUDDY_SET_avatarSize": str(AVATAR_SIZE),
            "BUDDY_SET_voiceProvider": "system",
            "BUDDY_SET_listenOnLaunch": "1",
            "BUDDY_SET_triggerSilence": "0.8",
            "BUDDY_SET_replySilence": "1.2",
            "BUDDY_SET_idleTimeout": "90",
            "BUDDY_SET_showSubtitles": "1",
        }
        if self.mode == "live":
            env["BUDDY_ANTHROPIC_KEY"] = os.environ.get("ANTHROPIC_API_KEY", "")
        else:
            env["BUDDY_CLAUDE_URL"] = self.mock_url
            env["BUDDY_ANTHROPIC_KEY"] = "sk-ant-e2e-mock"
        if self.mode in ("inject", "live"):
            env["BUDDY_INBOX"] = str(self.inbox)
        args = ["open", "-n", "-g", "-F"]
        for key, value in env.items():
            args += ["--env", "%s=%s" % (key, value)]
        args += ["--stdout", str(self.dir / "stdout.log"), "--stderr", str(self.dir / "stderr.log"), str(self.app)]
        run(args)

    # Events -------------------------------------------------------------

    def read(self):
        if not self.log_path.exists():
            return
        with open(self.log_path, "rb") as handle:
            handle.seek(self.offset)
            data = handle.read()
        end = data.rfind(b"\n")
        if end < 0:
            return
        self.offset += end + 1
        for line in data[:end].splitlines():
            try:
                self.events.append(json.loads(line))
            except ValueError:
                pass

    def mark(self):
        self.read()
        return len(self.events)

    def find_all(self, kind, since=0):
        self.read()
        return [e for e in self.events[since:] if e.get("type") == kind]

    def last(self, kind):
        found = self.find_all(kind)
        return found[-1] if found else None

    def wait_for(self, predicate, timeout, what, since=0):
        deadline = time.time() + timeout * self.slow
        index = since
        while time.time() < deadline:
            self.read()
            while index < len(self.events):
                event = self.events[index]
                index += 1
                if predicate(event):
                    return event
            if self.pid and not self.alive():
                raise TestFailure("Buddy quit unexpectedly while waiting for %s" % what)
            time.sleep(0.1)
        recent = "; ".join(describe(e) for e in self.events[-8:])
        raise TestFailure("timed out after %.0fs waiting for %s (last events: %s)" % (timeout * self.slow, what, recent))

    def wait_type(self, kind, timeout, since=0, **fields):
        def matches(event):
            return event.get("type") == kind and all(event.get(k) == v for k, v in fields.items())
        label = kind + (" " + json.dumps(fields, ensure_ascii=False) if fields else "")
        return self.wait_for(matches, timeout, label, since)

    def phase(self):
        event = self.last("phase")
        return event["phase"] if event else None

    def input_ready(self):
        self.read()
        for event in reversed(self.events):
            if event.get("type") == "inputStarted":
                return True
            if event.get("type") == "inputStopped":
                return False
        return False

    def wait_input_ready(self, timeout=15):
        deadline = time.time() + timeout * self.slow
        while time.time() < deadline:
            if self.input_ready():
                return
            time.sleep(0.1)
        raise TestFailure("the microphone did not come back on")

    def alive(self):
        if not self.pid:
            return True
        return subprocess.run(["kill", "-0", str(self.pid)], capture_output=True).returncode == 0

    # Input --------------------------------------------------------------

    def append(self, path, obj):
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(obj, ensure_ascii=False) + "\n")

    def say(self, text):
        """The presenter says something."""
        if self.mode == "audio":
            self.wait_input_ready()
            time.sleep(0.6)
            run(["say", "-v", self.voice, "-a", self.device, "-r", "165", text])
        else:
            self.append(self.inbox, {"say": text, "wordDelay": 0.12})

    def command(self, name, value=None):
        obj = {"command": name}
        if value is not None:
            obj["value"] = value
        self.append(self.inbox if self.mode != "audio" else self.commands, obj)

    def ensure_listening(self):
        """Ends any running moment so the next test starts from a clean state."""
        if self.phase() not in (None, "listening", "paused"):
            since = self.mark()
            self.command("toggle")
            self.wait_type("phase", 15, since, phase="listening")
        self.wait_input_ready()


def describe(event):
    kind = event.get("type")
    extra = event.get("phase") or event.get("title") or event.get("text") or event.get("message") or event.get("mode") or ""
    return ("%s %s" % (kind, extra)).strip()[:90]


# ---------------------------------------------------------------------------
# Tests

TESTS = []


def test(test_id, title, use_cases, modes=("inject", "audio", "live")):
    def register(function):
        TESTS.append({"id": test_id, "title": title, "useCases": use_cases, "modes": modes, "run": function})
        return function
    return register


class Context:
    def __init__(self, buddy, mock, tools, out, mode, scenario):
        self.buddy = buddy
        self.mock = mock
        self.tools = tools
        self.out = out
        self.mode = mode
        self.scenario = scenario
        self.notes = []
        self.screen = None
        self.first_reply_mark = 0
        self.first_reply_text = ""
        self.screen_capture_works = None

    def note(self, text):
        self.notes.append(text)


def speech_texts(ctx, since):
    return [normalize(e.get("text")) for e in ctx.buddy.find_all("speechStarted", since)]


def await_reply(ctx, since, timeout=30):
    """Waits until Buddy has spoken and gone back to waiting or listening."""
    buddy = ctx.buddy
    buddy.wait_type("speechStarted", timeout, since)
    buddy.wait_for(lambda e: e.get("type") == "phase" and e.get("phase") in ("awaitingReply", "listening"),
                   timeout + 30, "Buddy to finish talking", since)


@test("T01", "Startar som menyradsapp utan Dock-ikon med overlay redo", ["UC1", "UC13"])
def test_launch(ctx):
    buddy = ctx.buddy
    launch = buddy.wait_type("launch", 40)
    buddy.pid = launch.get("pid")
    ctx.screen = launch["screens"][0]
    check(launch.get("activationPolicy") == "accessory",
          "activation policy is %s, expected accessory (no Dock icon)" % launch.get("activationPolicy"))
    status = buddy.wait_type("statusItem", 10)
    check(status.get("visible") and status.get("hasIcon"), "menu bar icon is not visible")
    check(launch.get("hotKeysRegistered") == 3, "only %s of 3 keyboard shortcuts registered" % launch.get("hotKeysRegistered"))
    check(launch.get("session") == ctx.scenario["name"], "active presentation is %r" % launch.get("session"))
    check(launch.get("moments") == [m["title"] for m in ctx.scenario["moments"]], "moments loaded: %s" % launch.get("moments"))
    panels = buddy.wait_type("overlayPanels", 10)["panels"]
    check(len(panels) >= 1, "no overlay window")
    panel = panels[0]
    check(panel["level"] >= 1000, "overlay window level %s is below the screen saver level" % panel["level"])
    check(panel["joinsAllSpaces"] and panel["fullScreenAuxiliary"], "overlay does not join full-screen spaces")
    check(panel["ignoresMouse"], "overlay would block clicks on the presentation")
    ctx.note("Röst för Buddy: %s (%s). Svenska röster: %s" % (
        launch.get("voice"), launch.get("voiceLanguage"), ", ".join(launch.get("languageVoices") or []) or "inga"))


@test("T02", "Börjar lyssna", ["UC2"])
def test_listening(ctx):
    buddy = ctx.buddy
    permissions = buddy.find_all("permissions")
    listening = buddy.wait_for(lambda e: e.get("type") in ("listening", "inputError") or
                               (e.get("type") == "permissions" and e.get("microphone") is False),
                               30, "listening to start")
    check(listening.get("type") == "listening" and listening.get("on"),
          "did not start listening: %s %s" % (describe(listening), permissions))
    buddy.wait_input_ready(20)
    if ctx.mode == "audio":
        started = buddy.last("inputStarted")
        check(started.get("source") == "microphone", "input is %s, not the microphone" % started.get("source"))
        ctx.note("Taligenkänning: %s, på enheten: %s" % (started.get("locale"), started.get("onDevice")))


@test("T03", "Vanligt tal startar ingen dialog", ["UC2"])
def test_ordinary_speech(ctx):
    buddy = ctx.buddy
    since = buddy.mark()
    buddy.say("Idag ska vi prata om hur AI förändrar arbetslivet.")
    if ctx.mode == "audio":
        heard = buddy.wait_type("transcript", 15, since)
        ctx.note("Mikrofonen hörde: %s" % heard.get("text"))
    time.sleep(3 * buddy.slow)
    check(not buddy.find_all("momentStarted", since), "a moment started without a trigger phrase")
    transcripts = buddy.find_all("transcript", since)
    check(transcripts, "nothing was heard")
    text = normalize(transcripts[-1]["text"]).lower()
    check("arbetslivet" in text or "ai" in text, "speech was not recognized correctly: %r" % text)


@test("T04", "Triggerfras startar dialogen; Buddy svarar och syns över presentationen",
      ["UC3", "UC4", "UC5", "UC6", "UC8"])
def test_trigger(ctx):
    buddy, mock = ctx.buddy, ctx.mock
    buddy.ensure_listening()
    since = buddy.mark()
    requests_before = mock.count()
    ctx.first_reply_mark = since
    buddy.say("Det här med AI-agenter är spännande. Vad tycker du, Buddy?")
    heard = buddy.wait_type("heard", 20, since, kind="trigger")
    check(heard["phrase"] == "vad tycker du buddy", "matched %r" % heard["phrase"])
    started = buddy.wait_type("momentStarted", 5, since)
    check(started["title"] == "Introduktion", "started moment %r, expected the first one" % started["title"])
    buddy.wait_type("phase", 10, since, phase="thinking")
    if ctx.mode != "live":
        request = mock.wait_for_request(requests_before, 10)
        check(not request["problems"], "invalid Claude request: %s" % "; ".join(request["problems"]))
        body = request["body"]
        check("## Det här momentet: Introduktion" in body["system"], "system prompt lacks the moment")
        check("presenterar sig som talarens AI-kompis" in body["system"], "system prompt lacks the script")
        check("Du är Buddy" in body["system"], "system prompt lacks the persona")
        last = body["messages"][-1]["content"]
        check("Vad tycker du" in last or "vad tycker du" in last.lower(), "the question was not sent to Claude: %r" % last)
    speech = buddy.wait_type("speechStarted", 20, since)
    buddy.wait_type("avatar", 5, since, mode="speaking")
    overlay = buddy.wait_type("overlayState", 5, since, mode="speaking")
    # Evidence while Buddy speaks: snapshot of the robot, window order and a screenshot.
    buddy.command("snapshot", "speaking")
    time.sleep(0.4)
    windows = window_list(ctx.tools)
    (ctx.out / "windows-speaking.json").write_text(json.dumps(windows, indent=2))
    shot = screenshot(ctx.out / "screen-speaking.png")
    check_overlay_on_top(ctx, overlay, windows)
    check_screenshot(ctx, shot, expect_robot=True)
    buddy.wait_type("phase", 40, since, phase="awaitingReply")
    said = buddy.find_all("buddySaid", since)
    check(said, "Buddy said nothing")
    ctx.first_reply_text = normalize(said[-1]["text"])
    if ctx.mode != "live":
        check(ctx.first_reply_text == normalize(MOCK_REPLIES["Introduktion"][0]),
              "Buddy said %r" % ctx.first_reply_text)
    else:
        check(re.search(r"[åäöÅÄÖ]| och | jag | det ", " %s " % ctx.first_reply_text),
              "the reply does not look Swedish: %r" % ctx.first_reply_text)
    check(normalize(speech["text"]) in ctx.first_reply_text, "spoken sentence is not part of the reply")
    buddy.wait_type("avatar", 5, since, mode="listening")


def check_overlay_on_top(ctx, overlay, windows):
    panel = overlay["panels"][0]
    check(panel["isVisible"] and panel["onActiveSpace"], "overlay window is not on the visible space")
    frame = panel["cgFrame"]
    screen = ctx.screen
    right_gap = screen["w"] - (frame["x"] + frame["w"])
    bottom_gap = screen["h"] - (frame["y"] + frame["h"])
    check(abs(right_gap - OVERLAY_MARGIN) <= 2 and abs(bottom_gap - OVERLAY_MARGIN) <= 2,
          "overlay is not in the bottom right corner (gaps %.0f, %.0f)" % (right_gap, bottom_gap))
    mine = [w for w in windows if w["owner"] == "Buddy" and abs(w["w"] - frame["w"]) < 2 and abs(w["h"] - frame["h"]) < 2]
    check(mine, "the overlay window is not on screen")
    presentation = [w for w in windows if w["owner"] == "PresentationStub" and w["w"] > 300]
    check(presentation, "the presentation window is not on screen")
    check(mine[0]["order"] < presentation[0]["order"], "the overlay is behind the presentation")
    full = presentation[0]["w"] >= screen["w"] - 1 and presentation[0]["h"] >= screen["h"] - 1
    ctx.note("Presentationen i helskärm: %s; overlay över presentationen: ja" % ("ja" if full else "nej (fönster)"))


def check_screenshot(ctx, shot, expect_robot):
    """Looks at the real screen. Skipped when the runner may not record the screen."""
    if not shot:
        ctx.note("Skärmdump kunde inte tas")
        return
    screen = ctx.screen
    if ctx.screen_capture_works is None:
        center = region_stats(ctx.tools, shot, screen["w"], (screen["w"] * 0.2, screen["h"] * 0.75, screen["w"] * 0.2, 60))
        ctx.screen_capture_works = center["fractionMatching"] > 0.5
        if not ctx.screen_capture_works:
            ctx.note("Skärmdumpen visar inte presentationen (saknar skärminspelningsbehörighet); bildkontroll hoppades över")
    if not ctx.screen_capture_works:
        return
    size = AVATAR_SIZE
    robot = (screen["w"] - OVERLAY_MARGIN - size, screen["h"] - OVERLAY_MARGIN - size * 1.2, size, size * 1.2)
    stats = region_stats(ctx.tools, shot, screen["w"], robot)
    covered = 1 - stats["fractionMatching"]
    if expect_robot:
        check(covered > 0.15, "the robot is not visible in the screenshot (%.0f%% of the corner covered)" % (covered * 100))
        ctx.note("Roboten täcker %.0f%% av hörnet i skärmdumpen" % (covered * 100))
    else:
        check(covered < 0.05, "something is still drawn in the corner (%.0f%%)" % (covered * 100))


@test("T05", "Svensk röst och munrörelser i takt med ljudet", ["UC5"])
def test_lip_sync(ctx):
    buddy = ctx.buddy
    since = ctx.first_reply_mark
    tts = buddy.find_all("tts", since)
    check(tts, "no speech was synthesized")
    languages = {t.get("voiceLanguage", "") for t in tts}
    check(all(lang.lower().startswith("sv") for lang in languages), "voice language %s is not Swedish" % sorted(languages))
    check(all(t.get("result") in ("file", "live") for t in tts), "synthesis failed: %s" % [t.get("error") for t in tts])
    ended = buddy.find_all("speechEnded", since)
    check(ended, "no sentence finished playing")
    for sentence in ended:
        check(sentence["samples"] >= 5, "too few mouth samples for %r" % sentence["text"])
        check(sentence["maxMouth"] >= 0.3, "the mouth barely opened (max %.2f) for %r" % (sentence["maxMouth"], sentence["text"]))
        check(sentence["openFraction"] >= 0.15, "the mouth was open only %.0f%% of the time" % (sentence["openFraction"] * 100))
    closed = buddy.find_all("mouthClosed", since)
    check(closed and closed[-1]["t"] >= ended[-1]["t"] - 0.5, "the mouth did not close after speaking")
    snapshot = buddy.wait_type("snapshot", 10, since)
    check(snapshot.get("mouthDifference", 0) > 0.003, "open and closed mouth look the same in the drawing")
    for key in ("current", "open", "closed"):
        path = snapshot.get(key)
        check(path and Path(path).exists(), "snapshot %s missing" % key)
        shutil.copy(path, ctx.out / Path(path).name)
    modes = {t.get("result") for t in tts}
    ctx.note("Talsyntes: %s; munöppning max %.2f" % (", ".join(sorted(modes)), max(s["maxMouth"] for s in ended)))


@test("T06", "Följdfråga: Buddy svarar igen med samtalet som sammanhang", ["UC6"])
def test_follow_up(ctx):
    buddy, mock = ctx.buddy, ctx.mock
    check(buddy.phase() == "awaitingReply", "Buddy is not waiting for a reply (phase %s)" % buddy.phase())
    buddy.wait_input_ready()
    since = buddy.mark()
    before = mock.count()
    buddy.say("Men är det inte lite läskigt med AI?")
    buddy.wait_type("presenterSaid", 20, since)
    if ctx.mode != "live":
        request = mock.wait_for_request(before, 15)
        check(not request["problems"], "invalid Claude request: %s" % "; ".join(request["problems"]))
        roles = [m["role"] for m in request["body"]["messages"]]
        check(roles == ["user", "assistant", "user"], "conversation roles %s" % roles)
        check(normalize(request["body"]["messages"][1]["content"]) == ctx.first_reply_text,
              "Buddy's first reply is missing from the history")
        check("läskigt" in request["body"]["messages"][2]["content"], "the follow-up question was not sent")
    await_reply(ctx, since)
    check(buddy.phase() == "awaitingReply", "phase is %s after the second reply" % buddy.phase())


@test("T07", "Avslutsfras: Buddy säger hej då och försvinner", ["UC7", "UC8"])
def test_end_phrase(ctx):
    buddy, mock = ctx.buddy, ctx.mock
    buddy.wait_input_ready()
    since = buddy.mark()
    before = mock.count()
    buddy.say("Tack, Buddy!")
    heard = buddy.wait_type("heard", 20, since, kind="endPhrase")
    check(heard["phrase"] == "tack buddy", "matched %r" % heard["phrase"])
    buddy.wait_type("phase", 5, since, phase="closing")
    farewell = buddy.wait_type("speechStarted", 15, since)
    check(normalize(farewell["text"]) in ctx.scenario["farewells"], "farewell was %r" % farewell["text"])
    ended = buddy.wait_type("momentEnded", 20, since)
    check(ended["title"] == "Introduktion" and ended["reason"] == "endPhrase", "moment ended: %s" % ended)
    buddy.wait_type("phase", 10, since, phase="listening")
    buddy.wait_type("avatar", 5, since, mode="hidden")
    check(mock.count() == before, "Claude was asked again after the end phrase")
    time.sleep(1.0)
    check_screenshot(ctx, screenshot(ctx.out / "screen-after-end.png"), expect_robot=False)


@test("T08", "Annan triggerfras startar nästa moment, som slutar efter ett svar", ["UC8", "UC9"])
def test_next_moment(ctx):
    buddy, mock = ctx.buddy, ctx.mock
    buddy.ensure_listening()
    since = buddy.mark()
    before = mock.count()
    buddy.say("AI kommer att förändra mycket, eller hur, Buddy?")
    heard = buddy.wait_type("heard", 20, since, kind="trigger")
    check(heard["phrase"] == "eller hur buddy", "matched %r" % heard["phrase"])
    started = buddy.wait_type("momentStarted", 5, since)
    check(started["title"] == "Kan AI ta jobben?", "started %r, expected the next moment" % started["title"])
    if ctx.mode != "live":
        request = mock.wait_for_request(before, 10)
        check("## Det här momentet: Kan AI ta jobben?" in request["body"]["system"], "wrong moment sent to Claude")
        check("sista svar" in request["body"]["messages"][-1]["content"], "Claude was not told this is the last reply")
    ended = buddy.wait_type("momentEnded", 40, since)
    check(ended["reason"] == "lastTurn", "moment ended because of %s" % ended["reason"])
    buddy.wait_type("phase", 10, since, phase="listening")


@test("T09", "Egen trigger startar manusmomentet; repliker sägs ordagrant utan Claude", ["UC9", "UC10"],
      modes=("inject", "audio"))
def test_scripted(ctx):
    buddy, mock = ctx.buddy, ctx.mock
    buddy.ensure_listening()
    since = buddy.mark()
    before = mock.count()
    buddy.say("Har du några sista ord, Buddy?")
    heard = buddy.wait_type("heard", 20, since, kind="trigger")
    check(heard["phrase"] == "några sista ord buddy", "matched %r" % heard["phrase"])
    started = buddy.wait_type("momentStarted", 5, since)
    check(started["title"] == "Avslutning", "started %r" % started["title"])
    lines = ctx.scenario["moments"][2]["lines"]
    first = buddy.wait_type("speechStarted", 15, since)
    check(normalize(first["text"]) == lines[0], "first line was %r" % first["text"])
    buddy.wait_type("phase", 20, since, phase="awaitingReply")
    buddy.wait_input_ready()
    second_since = buddy.mark()
    buddy.say("Och sen då?")
    second = buddy.wait_type("speechStarted", 20, second_since)
    check(normalize(second["text"]) == lines[1], "second line was %r" % second["text"])
    ended = buddy.wait_type("momentEnded", 20, since)
    check(ended["title"] == "Avslutning" and ended["reason"] == "lastTurn", "moment ended: %s" % ended)
    check(mock.count() == before, "Claude was called during a scripted moment")
    buddy.wait_type("phase", 10, since, phase="listening")


@test("T10", "När alla moment är gjorda improviserar Buddy kort", ["UC9"], modes=("inject", "audio"))
def test_improvisation(ctx):
    buddy = ctx.buddy
    buddy.ensure_listening()
    since = buddy.mark()
    buddy.say("Vad tycker du, Buddy?")
    started = buddy.wait_type("momentStarted", 20, since)
    check(started["title"] == "Improvisation", "started %r, expected improvisation" % started["title"])
    ended = buddy.wait_type("momentEnded", 40, since)
    check(ended["reason"] == "lastTurn", "ended because of %s" % ended["reason"])
    buddy.wait_type("phase", 10, since, phase="listening")


@test("T11", "Börja om och avsluta med den andra avslutsfrasen", ["UC7", "UC8", "UC9"], modes=("inject", "audio"))
def test_reset_and_second_end_phrase(ctx):
    buddy = ctx.buddy
    buddy.ensure_listening()
    since = buddy.mark()
    buddy.command("reset")
    buddy.wait_for(lambda e: e.get("type") == "progress" and e.get("completed") == [], 10, "progress reset", since)
    buddy.say("Vad tycker du, Buddy?")
    started = buddy.wait_type("momentStarted", 20, since)
    check(started["title"] == "Introduktion", "started %r after reset" % started["title"])
    buddy.wait_type("phase", 40, since, phase="awaitingReply")
    buddy.wait_input_ready()
    end_since = buddy.mark()
    buddy.say("Det räcker, Buddy.")
    heard = buddy.wait_type("heard", 20, end_since, kind="endPhrase")
    check(heard["phrase"] == "det räcker buddy", "matched %r" % heard["phrase"])
    ended = buddy.wait_type("momentEnded", 20, end_since)
    check(ended["reason"] == "endPhrase", "ended because of %s" % ended["reason"])
    buddy.wait_type("phase", 15, end_since, phase="listening")


@test("T12", "Om Claude inte svarar säger Buddy en reservreplik", ["UC11"], modes=("inject", "audio"))
def test_fallback(ctx):
    buddy, mock = ctx.buddy, ctx.mock
    buddy.ensure_listening()
    since = buddy.mark()
    mock.fail_next = 1
    buddy.say("Eller hur, Buddy?")
    started = buddy.wait_type("momentStarted", 20, since)
    check(started["title"] == "Kan AI ta jobben?", "started %r" % started["title"])
    buddy.wait_type("claudeError", 15, since)
    speech = buddy.wait_type("speechStarted", 15, since)
    check(normalize(speech["text"]) in ctx.scenario["fallbackLines"], "Buddy said %r instead of a fallback line" % speech["text"])
    buddy.wait_type("phase", 40, since, phase="listening")


@test("T13", "Buddy hör inte sin egen röst", ["UC12"])
def test_echo(ctx):
    buddy = ctx.buddy
    buddy.read()
    events = buddy.events
    intervals = []
    start = None
    for event in events:
        if event.get("type") == "speechStarted" and start is None:
            start = event["t"]
        elif event.get("type") == "mouthClosed" and start is not None:
            intervals.append((start, event["t"]))
            start = None
    check(intervals, "Buddy never spoke")
    for begin, end in intervals:
        heard_inside = [e for e in events if e.get("type") in ("transcript", "heard", "presenterSaid") and begin <= e["t"] <= end + 0.3]
        check(not heard_inside, "Buddy heard something while it was talking: %s" % [describe(e) for e in heard_inside[:3]])
    mic_off = [e for e in events if e.get("type") == "microphone" and e.get("on") is False]
    check(len(mic_off) >= len(intervals) // 2, "the microphone was not turned off while speaking")
    ctx.note("Buddy pratade %d gånger; inget hördes medan Buddy pratade" % len(intervals))


@test("T14", "Avslutas rent", ["UC1"])
def test_quit(ctx):
    buddy = ctx.buddy
    since = buddy.mark()
    buddy.command("quit")
    buddy.wait_type("terminate", 15, since)
    deadline = time.time() + 10
    while time.time() < deadline and buddy.alive():
        time.sleep(0.2)
    check(not buddy.alive(), "Buddy is still running")


# ---------------------------------------------------------------------------
# Runner


def collect_crash_reports(out):
    folder = Path.home() / "Library" / "Logs" / "DiagnosticReports"
    found = []
    if folder.exists():
        for path in folder.glob("Buddy*"):
            if time.time() - path.stat().st_mtime < 3600:
                shutil.copy(path, out / path.name)
                found.append(path.name)
    return found


def write_report(ctx, results, out, mode, started):
    passed = sum(1 for r in results if r["status"] == "passed")
    failed = sum(1 for r in results if r["status"] == "failed")
    covered = {}
    for result in results:
        for uc in result["useCases"]:
            covered.setdefault(uc, []).append(result)
    lines = ["# Buddy e2e (%s)" % mode, ""]
    lines.append("%d av %d tester gick igenom på %.0f s." % (passed, len(results), time.time() - started))
    lines.append("")
    lines.append("| Test | Resultat | Tid | Detaljer |")
    lines.append("|---|---|---|---|")
    for r in results:
        icon = {"passed": "✅", "failed": "❌", "skipped": "⏭️"}[r["status"]]
        detail = (r.get("error") or "").replace("|", "\\|").replace("\n", " ")
        lines.append("| %s %s | %s | %.1f s | %s |" % (r["id"], r["title"], icon, r["seconds"], detail[:300]))
    lines += ["", "## Användningsfall", "", "| Fall | Beskrivning | Status |", "|---|---|---|"]
    for uc, description in USE_CASES.items():
        runs = covered.get(uc, [])
        if not runs:
            status = "– (inte i det här läget)"
        elif all(r["status"] == "passed" for r in runs):
            status = "✅ " + ", ".join(r["id"] for r in runs)
        else:
            status = "❌ " + ", ".join("%s %s" % (r["id"], r["status"]) for r in runs)
        lines.append("| %s | %s | %s |" % (uc, description, status))
    if ctx.notes:
        lines += ["", "## Observationer", ""] + ["- " + n for n in ctx.notes]
    report = "\n".join(lines) + "\n"
    (out / "report.md").write_text(report)
    (out / "results.json").write_text(json.dumps({"mode": mode, "passed": passed, "failed": failed,
                                                  "results": [{k: v for k, v in r.items() if k != "run"} for r in results],
                                                  "notes": ctx.notes}, indent=2, ensure_ascii=False))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(report + "\n")
    print(report)
    return failed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", default=str(ROOT / "build" / "Buddy.app"))
    parser.add_argument("--mode", choices=("inject", "audio", "live"), default="inject")
    parser.add_argument("--out", default=None)
    parser.add_argument("--audio-device", default="BlackHole 2ch")
    parser.add_argument("--voice", default=None, help="macOS voice that speaks the presenter's lines (audio mode)")
    parser.add_argument("--windowed", action="store_true", help="show the presentation in a window instead of full screen")
    args = parser.parse_args()

    out = Path(args.out or ROOT / "build" / "e2e" / args.mode).resolve()
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    started = time.time()

    if args.mode == "live" and not os.environ.get("ANTHROPIC_API_KEY"):
        print("live mode needs ANTHROPIC_API_KEY")
        return 2
    voice = None
    if args.mode == "audio":
        voice = args.voice or swedish_voice()
        if not voice:
            print("No Swedish voice is installed for the presenter (say -v '?'). Install one in System Settings.")
            return 2

    tools = build_tools(ROOT / "build" / "e2e-tools")
    scenario = json.loads(SCENARIO.read_text())
    mock = MockClaude()
    mock.start()

    stub_args = [str(tools["PresentationStub"])] + (["--windowed"] if args.windowed else [])
    stub = subprocess.Popen(stub_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(4)

    buddy = Buddy(args, out, mock.url, voice)
    ctx = Context(buddy, mock, tools, out, args.mode, scenario)
    results = []
    try:
        buddy.launch()
        for entry in TESTS:
            result = {"id": entry["id"], "title": entry["title"], "useCases": entry["useCases"], "seconds": 0.0}
            if args.mode not in entry["modes"]:
                result["status"] = "skipped"
                result["error"] = "inte i läget %s" % args.mode
                results.append(result)
                continue
            began = time.time()
            try:
                entry["run"](ctx)
                result["status"] = "passed"
            except TestFailure as error:
                result["status"] = "failed"
                result["error"] = str(error)
            except Exception as error:  # noqa: BLE001 - report anything unexpected as a failure
                result["status"] = "failed"
                result["error"] = "%s: %s" % (type(error).__name__, error)
                traceback.print_exc()
            result["seconds"] = time.time() - began
            print("%s %s: %s %s" % (entry["id"], entry["title"], result["status"], result.get("error", "")), flush=True)
            results.append(result)
            if result["status"] == "failed" and entry["id"] != "T14" and buddy.alive():
                try:
                    buddy.ensure_listening()
                except TestFailure:
                    pass
            if not buddy.alive() and entry["id"] != "T14":
                crashes = collect_crash_reports(out)
                ctx.note("Buddy avslutades oväntat. Kraschrapporter: %s" % (crashes or "inga"))
                break
    finally:
        if buddy.alive() and buddy.pid:
            subprocess.run(["kill", str(buddy.pid)], capture_output=True)
        stub.terminate()
        mock.stop()
        (out / "claude-requests.json").write_text(json.dumps(mock.requests, indent=2, ensure_ascii=False))

    failed = write_report(ctx, results, out, args.mode, started)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
