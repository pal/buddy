#!/usr/bin/env python3
"""End-to-end tests for Buddy.app on macOS.

Runs the real app next to a full-screen stand-in presentation and checks the use
cases: background menu bar app, trigger phrases, dialog with Claude (local mock
server that validates every request), Swedish speech with lip sync, the avatar on
top of the presentation, end phrases, several moments, scripted lines, fallback
when Claude fails, and that Buddy does not hear itself. A second run of the app
uses ElevenLabs (local mock server that validates every request and answers with
real Swedish speech): choosing a Swedish voice from the Voice Library, Eleven v4
Turbo with audio tags, fixed lines prepared with Eleven v4, and the fallback to
the macOS voice.

Modes:
  inject  Sentences are delivered to Buddy as recognized text. No microphone.
  audio   Sentences are spoken with a Swedish macOS voice into a virtual
          microphone (BlackHole) and go through real speech recognition.
  live    Like inject, but against the real Claude API (needs ANTHROPIC_API_KEY).

Usage:
  python3 e2e/run_e2e.py --app build/Buddy.app --mode inject --out build/e2e/inject
"""

import argparse
import hashlib
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
from urllib.parse import parse_qs, unquote, urlparse

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
# Used when the system prompt allows audio tags (ElevenLabs v3/v4 voices).
TAGGED_REPLY = ("[laughs] Hej allihop! Jag är Buddy, talarens lilla AI-kompis. "
                "[whispers] Jag har läst hela internet men förstår mig fortfarande inte på måndagar.")
MOCK_REPLIES_WITH_TAGS = {"Introduktion": [TAGGED_REPLY]}

ELEVEN_KEY = "xi-e2e-mock"
AUDIO_TAGS = {"laughs", "chuckles", "sighs", "whispers", "excited", "curious", "mischievously", "surprised"}
TAG_MODELS = ("eleven_v3", "eleven_v4")
KNOWN_MODELS = {"eleven_v4_turbo", "eleven_v4", "eleven_v3", "eleven_v3_conversational",
                "eleven_flash_v2_5", "eleven_multilingual_v2"}
SPEECH_FIELDS = {"text", "model_id", "language_code", "voice_settings", "pronunciation_dictionary_locators",
                 "seed", "previous_text", "next_text", "previous_request_ids", "next_request_ids",
                 "use_pvc_as_ivc", "apply_text_normalization", "apply_language_text_normalization", "audio_effects"}
OUTPUT_FORMATS = {"mp3_22050_32", "mp3_24000_48", "mp3_44100_32", "mp3_44100_64", "mp3_44100_96", "mp3_44100_128",
                  "opus_48000_32", "opus_48000_64", "opus_48000_96", "opus_48000_128", "pcm_16000", "pcm_22050",
                  "pcm_24000", "wav_16000", "wav_22050", "wav_24000"}

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
    "UC14": "Naturligt tal med ElevenLabs Eleven v4 Turbo: ljudtaggar, textning utan taggar och munrörelser",
    "UC15": "En svensk röst väljs ur ElevenLabs röstbibliotek",
    "UC16": "Fasta repliker förbereds med Eleven v4 och spelas direkt",
    "UC17": "Om ElevenLabs inte svarar pratar Buddy vidare med macOS-rösten",
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

    def reset_turns(self):
        with self.lock:
            self.turns = {}

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
                tags_allowed = "[laughs]" in ((body or {}).get("system") or "")
                with mock.lock:
                    failing = mock.fail_next > 0
                    if failing:
                        mock.fail_next -= 1
                        reply = None
                    else:
                        turn = mock.turns.get(moment, 0)
                        mock.turns[moment] = turn + 1
                        replies = (MOCK_REPLIES_WITH_TAGS.get(moment) if tags_allowed else None) \
                            or MOCK_REPLIES.get(moment) or [DEFAULT_REPLY]
                        reply = replies[min(turn, len(replies) - 1)]
                    mock.requests.append({
                        "headers": headers,
                        "body": body,
                        "problems": problems,
                        "moment": moment,
                        "reply": reply,
                        "failed": failing,
                        "tagsAllowed": tags_allowed,
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
# Mock ElevenLabs API


def library_voices(base):
    """Swedish voices in the shared Voice Library, shaped like GET /v1/shared-voices."""
    def voice(voice_id, owner, name, gender, age, use_case, description):
        return {
            "public_owner_id": owner, "voice_id": voice_id, "date_unix": 1760000000, "name": name,
            "accent": "swedish", "gender": gender, "age": age, "descriptive": "warm", "use_case": use_case,
            "category": "professional", "language": "sv", "locale": "sv-SE", "description": description,
            "preview_url": "%s/previews/%s.wav" % (base, voice_id), "usage_character_count_1y": 250000,
            "usage_character_count_7d": 4000, "play_api_usage_character_count_1y": 90000, "cloned_by_count": 310,
            "rate": None, "fiat_rate": None, "free_users_allowed": True, "live_moderation_enabled": False,
            "featured": True, "verified_languages": [{"language": "sv", "model_id": "eleven_v4", "accent": "swedish",
                                                      "locale": "sv-SE", "preview_url": None}],
            "notice_period": None, "instagram_username": None, "twitter_username": None, "youtube_username": None,
            "tiktok_username": None, "image_url": None, "is_added_by_user": False, "is_bookmarked": None,
        }
    return [
        voice("lib-sv-1", "owner-sv-1", "Sanna", "female", "young", "conversational", "Varm och glad svensk röst"),
        voice("lib-sv-2", "owner-sv-2", "Erik", "male", "middle_aged", "narrative_story", "Lugn berättarröst från Stockholm"),
    ]


def premade_voice(base):
    return {"voice_id": "premade-rachel", "name": "Rachel", "category": "premade",
            "labels": {"accent": "american", "gender": "female", "age": "young", "use_case": "narration"},
            "description": None, "preview_url": "%s/previews/premade-rachel.wav" % base, "available_for_tiers": [],
            "high_quality_base_model_ids": [], "sharing": None, "verified_languages": [], "is_owner": False,
            "is_legacy": False}


def validate_speech(headers, query, body):
    """Problems with a text-to-speech request, as the real API would see them."""
    problems = []
    if headers.get("xi-api-key") != ELEVEN_KEY:
        problems.append("xi-api-key is %r" % headers.get("xi-api-key"))
    if "application/json" not in headers.get("content-type", ""):
        problems.append("content-type is not application/json")
    output_format = (query.get("output_format") or ["mp3_44100_128"])[0]
    if output_format not in OUTPUT_FORMATS:
        problems.append("output_format %r is unknown or needs a higher plan" % output_format)
    if not isinstance(body, dict):
        return problems + ["body is not a JSON object"]
    unknown = sorted(set(body) - SPEECH_FIELDS)
    if unknown:
        problems.append("unknown fields %s" % unknown)
    text = body.get("text")
    if not isinstance(text, str) or not text.strip():
        problems.append("text is missing")
        text = ""
    model = body.get("model_id")
    if model not in KNOWN_MODELS:
        problems.append("unknown model_id %r" % model)
        model = ""
    language = body.get("language_code")
    if language is not None:
        if model == "eleven_multilingual_v2":
            problems.append("language_code is not supported for eleven_multilingual_v2")
        if not re.fullmatch(r"[a-z]{2,3}", str(language)):
            problems.append("language_code %r is not ISO 639" % language)
    tags = re.findall(r"\[([^\]]*)\]", text)
    if tags and not model.startswith(TAG_MODELS):
        problems.append("audio tags %s sent to %s, which would read them aloud" % (tags, model))
    for tag in tags:
        if tag not in AUDIO_TAGS:
            problems.append("unexpected audio tag [%s]" % tag)
    return problems


class MockElevenLabs:
    """Answers like the ElevenLabs API, with real Swedish speech from the macOS voice."""

    def __init__(self, folder, voice):
        self.folder = folder
        self.voice = voice
        self.folder.mkdir(parents=True, exist_ok=True)
        self.requests = []
        self.fail_speech = 0
        self.lock = threading.Lock()
        self.render_lock = threading.Lock()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.port = self.server.server_address[1]
        self.library = library_voices(self.url)
        self.mine = [premade_voice(self.url)]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.port

    def start(self):
        self.thread.start()

    def stop(self):
        self.server.shutdown()

    def all(self, kind=None, since=0):
        with self.lock:
            return [r for r in self.requests[since:] if kind is None or r["kind"] == kind]

    def count(self):
        with self.lock:
            return len(self.requests)

    def speech_audio(self, text):
        """WAV audio of the text without its audio tags."""
        clean = re.sub(r"\[[^\]]*\]", " ", text)
        clean = re.sub(r"\s+", " ", clean).strip() or "Hm."
        path = self.folder / ("%s.wav" % hashlib.sha1(clean.encode("utf-8")).hexdigest()[:16])
        with self.render_lock:
            if not path.exists():
                voice = ["-v", self.voice] if self.voice else []
                run(["say"] + voice + ["-o", str(path), "--file-format=WAVE", "--data-format=LEI16@22050", clean])
        return path.read_bytes()

    def _handler(self):
        mock = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, payload, content_type="application/json"):
                data = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode("utf-8")
                self.send_response(status)
                self.send_header("content-type", content_type)
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def record(self, kind, **fields):
                entry = {"kind": kind, "method": self.command, "path": urlparse(self.path).path, "t": time.time()}
                entry.update(fields)
                with mock.lock:
                    mock.requests.append(entry)
                return entry

            def key_problems(self, headers):
                return [] if headers.get("xi-api-key") == ELEVEN_KEY else ["xi-api-key is %r" % headers.get("xi-api-key")]

            def do_GET(self):
                url = urlparse(self.path)
                path = unquote(url.path)
                query = parse_qs(url.query)
                headers = {k.lower(): v for k, v in self.headers.items()}
                if path.startswith("/previews/"):
                    self.reply(200, mock.speech_audio("Hej! Så här låter jag."), "audio/wav")
                    return
                if path == "/v1/shared-voices":
                    problems = self.key_problems(headers)
                    if query.get("language") != ["sv"]:
                        problems.append("language filter is %r, expected sv" % query.get("language"))
                    size = int((query.get("page_size") or ["30"])[0])
                    if size > 100:
                        problems.append("page_size %d is above 100" % size)
                    self.record("libraryVoices", query=query, problems=problems)
                    self.reply(200, {"voices": mock.library, "has_more": False, "total_count": len(mock.library),
                                     "last_sort_id": None})
                    return
                if path == "/v1/voices":
                    self.record("myVoices", problems=self.key_problems(headers))
                    self.reply(200, {"voices": mock.mine})
                    return
                self.reply(404, {"detail": "Not Found"})

            def do_POST(self):
                url = urlparse(self.path)
                path = unquote(url.path)
                query = parse_qs(url.query)
                headers = {k.lower(): v for k, v in self.headers.items()}
                length = int(self.headers.get("content-length") or 0)
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw)
                except ValueError:
                    body = None
                speech = re.fullmatch(r"/v1/text-to-speech/([A-Za-z0-9_.~-]+)", path)
                if speech:
                    voice_id = speech.group(1)
                    problems = validate_speech(headers, query, body)
                    known = {v["voice_id"] for v in mock.mine}
                    if voice_id not in known:
                        problems.append("voice %s is not in My voices" % voice_id)
                    with mock.lock:
                        failing = mock.fail_speech > 0
                        if failing:
                            mock.fail_speech -= 1
                    self.record("speech", voice=voice_id, query=query, body=body, problems=problems, failed=failing)
                    if failing:
                        self.reply(500, {"detail": {"status": "server_error", "message": "Mock ElevenLabs failure"}})
                        return
                    if problems:
                        self.reply(422, {"detail": [{"loc": ["body"], "msg": "; ".join(problems)}]})
                        return
                    self.reply(200, mock.speech_audio(body["text"]), "audio/wav")
                    return
                add = re.fullmatch(r"/v1/voices/add/([A-Za-z0-9_.~-]+)/([A-Za-z0-9_.~-]+)", path)
                if add:
                    owner, voice_id = add.group(1), add.group(2)
                    problems = self.key_problems(headers)
                    name = (body or {}).get("new_name") if isinstance(body, dict) else None
                    if not isinstance(name, str) or not name.strip():
                        problems.append("new_name is missing")
                    library = next((v for v in mock.library if v["voice_id"] == voice_id and v["public_owner_id"] == owner), None)
                    if not library:
                        problems.append("no library voice %s/%s" % (owner, voice_id))
                    self.record("addVoice", owner=owner, voice=voice_id, body=body, problems=problems)
                    if problems:
                        self.reply(400, {"detail": {"status": "invalid_request", "message": "; ".join(problems)}})
                        return
                    new_id = "added-%s" % voice_id
                    with mock.lock:
                        library["is_added_by_user"] = True
                        if not any(v["voice_id"] == new_id for v in mock.mine):
                            copy = premade_voice(mock.url)
                            copy.update({"voice_id": new_id, "name": name, "category": "professional",
                                         "labels": {"accent": "swedish", "gender": library["gender"], "language": "sv"},
                                         "preview_url": library["preview_url"],
                                         "sharing": {"status": "copied", "original_voice_id": voice_id,
                                                     "public_owner_id": owner}})
                            mock.mine.append(copy)
                    self.reply(200, {"voice_id": new_id})
                    return
                self.reply(404, {"detail": "Not Found"})

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
    def __init__(self, args, workdir, mock_url, voice, extra_env=None):
        self.app = Path(args.app).resolve()
        self.mode = args.mode
        self.dir = workdir
        self.dir.mkdir(parents=True, exist_ok=True)
        self.voice = voice
        self.device = args.audio_device
        self.mock_url = mock_url
        self.extra_env = extra_env or {}
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
        env.update(self.extra_env)
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

    def find_all(self, event_type, since=0):
        self.read()
        return [e for e in self.events[since:] if e.get("type") == event_type]

    def last(self, event_type):
        found = self.find_all(event_type)
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

    def wait_type(self, event_type, timeout, since=0, **fields):
        def matches(event):
            return event.get("type") == event_type and all(event.get(k) == v for k, v in fields.items())
        label = event_type + (" " + json.dumps(fields, ensure_ascii=False) if fields else "")
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


def test(test_id, title, use_cases, modes=("inject", "audio", "live"), quits=False):
    def register(function):
        TESTS.append({"id": test_id, "title": title, "useCases": use_cases, "modes": modes, "quits": quits,
                      "run": function})
        return function
    return register


class Context:
    def __init__(self, buddy, mock, tools, out, mode, scenario, eleven=None, args=None):
        self.buddy = buddy
        self.mock = mock
        self.eleven = eleven
        self.args = args
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
        buddy.wait_type("transcript", 15, since)
    time.sleep(3 * buddy.slow)
    check(not buddy.find_all("momentStarted", since), "a moment started without a trigger phrase")
    transcripts = buddy.find_all("transcript", since)
    check(transcripts, "nothing was heard")
    text = normalize(transcripts[-1]["text"])
    check("arbetslivet" in text.lower(), "speech was not recognized correctly: %r" % text)
    if ctx.mode == "audio":
        ctx.note("Mikrofonen och taligenkänningen hörde: \u201c%s\u201d" % text)


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
    presentation = sorted((w for w in windows if w["owner"] == "PresentationStub" and w["alpha"] > 0),
                          key=lambda w: w["w"] * w["h"], reverse=True)
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
        check(sentence["openFraction"] <= 0.92,
              "the mouth stayed open %.0f%% of the time instead of following the syllables" % (sentence["openFraction"] * 100))
        rate = sentence["openings"] / max(sentence["seconds"], 0.1)
        check(rate >= 1.0, "the mouth opened only %.1f times per second for %r" % (rate, sentence["text"]))
    closed = buddy.find_all("mouthClosed", since)
    check(closed and closed[-1]["t"] >= ended[-1]["t"] - 0.5, "the mouth did not close after speaking")
    snapshot = buddy.wait_type("snapshot", 10, since)
    check(snapshot.get("mouthDifference", 0) > 0.003, "open and closed mouth look the same in the drawing")
    for key in ("current", "open", "closed"):
        path = snapshot.get(key)
        check(path and Path(path).exists(), "snapshot %s missing" % key)
        shutil.copy(path, ctx.out / Path(path).name)
    modes = {t.get("result") for t in tts}
    rates = [s["openings"] / max(s["seconds"], 0.1) for s in ended]
    ctx.note("Talsyntes: %s; munnen öppnas %.1f gånger per sekund, öppen %.0f%% av tiden" % (
        ", ".join(sorted(modes)), sum(rates) / len(rates), 100 * sum(s["openFraction"] for s in ended) / len(ended)))


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
    said = buddy.wait_type("buddySaid", 30, since)
    check(normalize(said["text"]) in ctx.scenario["fallbackLines"], "Buddy said %r instead of a fallback line" % said["text"])
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


@test("T14", "Avslutas rent", ["UC1"], quits=True)
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
# ElevenLabs (a second run of the app, after T14 has quit the first)


def start_elevenlabs_buddy(ctx):
    """Launches a fresh Buddy that speaks with ElevenLabs through the mock server."""
    if getattr(ctx, "eleven_started", False):
        return
    ctx.eleven_started = True
    ctx.mock.reset_turns()
    extra = {
        "BUDDY_SET_voiceProvider": "elevenLabs",
        "BUDDY_SET_elevenLabsKey": ELEVEN_KEY,
        "BUDDY_ELEVENLABS_URL": ctx.eleven.url,
    }
    buddy = Buddy(ctx.args, ctx.out / "elevenlabs", ctx.mock.url, ctx.buddy.voice, extra)
    ctx.buddy = buddy
    buddy.launch()
    launch = buddy.wait_type("launch", 40)
    buddy.pid = launch.get("pid")
    buddy.wait_type("listening", 30, on=True)
    buddy.wait_input_ready(20)


def eleven_speech(ctx, since):
    requests = ctx.eleven.all("speech", since)
    for request in requests:
        check(not request["problems"], "invalid ElevenLabs request: %s" % "; ".join(request["problems"]))
    return requests


def check_mouth(sentences):
    check(sentences, "no sentence finished playing")
    for sentence in sentences:
        check(sentence["samples"] >= 5, "too few mouth samples for %r" % sentence["text"])
        check(sentence["maxMouth"] >= 0.3, "the mouth barely opened (max %.2f) for %r" % (sentence["maxMouth"], sentence["text"]))
        rate = sentence["openings"] / max(sentence["seconds"], 0.1)
        check(rate >= 1.0, "the mouth opened only %.1f times per second for %r" % (rate, sentence["text"]))


@test("T15", "ElevenLabs: svenska röster listas och en väljs ur röstbiblioteket", ["UC15"], modes=("inject",))
def test_eleven_voice_library(ctx):
    start_elevenlabs_buddy(ctx)
    buddy, eleven = ctx.buddy, ctx.eleven
    since = buddy.mark()
    before = eleven.count()
    buddy.command("elevenVoices")
    listed = buddy.wait_type("elevenLabsVoices", 20, since)
    check(not listed.get("error"), "listing voices failed: %s" % listed.get("error"))
    check(listed.get("library") == [v["name"] for v in eleven.library], "library voices: %s" % listed.get("library"))
    check("Rachel" in (listed.get("mine") or []), "own voices: %s" % listed.get("mine"))
    library_requests = eleven.all("libraryVoices", before)
    check(library_requests, "the Voice Library was not asked")
    for request in library_requests + eleven.all("myVoices", before):
        check(not request["problems"], "invalid request: %s" % "; ".join(request["problems"]))
    since = buddy.mark()
    buddy.command("elevenUseVoice", "lib-sv-1")
    selected = buddy.wait_type("elevenLabsVoiceSelected", 20, since)
    check(selected.get("voiceID") == "added-lib-sv-1" and selected.get("name") == "Sanna",
          "selected %s" % selected)
    added = eleven.all("addVoice", before)
    check(added and not added[0]["problems"], "the voice was not added to My voices: %s" % added)
    check(added[0]["body"].get("new_name") == "Sanna", "added with the name %r" % added[0]["body"].get("new_name"))


@test("T16", "ElevenLabs Eleven v4 Turbo: ljudtaggar, textning utan taggar och munrörelser", ["UC14"],
      modes=("inject",))
def test_eleven_dialog(ctx):
    start_elevenlabs_buddy(ctx)
    buddy, mock, eleven = ctx.buddy, ctx.mock, ctx.eleven
    buddy.ensure_listening()
    since = buddy.mark()
    claude_before = mock.count()
    eleven_before = eleven.count()
    buddy.say("Det här med AI-agenter är spännande. Vad tycker du, Buddy?")
    started = buddy.wait_type("momentStarted", 20, since)
    check(started["title"] == "Introduktion", "started %r" % started["title"])
    request = mock.wait_for_request(claude_before, 10)
    check(not request["problems"], "invalid Claude request: %s" % "; ".join(request["problems"]))
    check(request["tagsAllowed"], "Claude was not told that the voice can perform audio tags")
    buddy.wait_type("phase", 60, since, phase="awaitingReply")
    speech = eleven_speech(ctx, eleven_before)
    check(len(speech) == 3, "expected 3 sentences rendered by ElevenLabs, got %d" % len(speech))
    for item in speech:
        check(item["body"].get("model_id") == "eleven_v4_turbo", "model %r" % item["body"].get("model_id"))
        check(item["body"].get("language_code") == "sv", "language_code %r" % item["body"].get("language_code"))
        check(item["voice"] == "added-lib-sv-1", "voice %s" % item["voice"])
    texts = [item["body"]["text"] for item in speech]
    check(texts[0] == "[laughs] Hej allihop!", "first sentence sent as %r" % texts[0])
    check(texts[2].startswith("[whispers] "), "third sentence sent as %r" % texts[2])
    subtitles = [e["text"] for e in buddy.find_all("subtitle", since) if e.get("text")]
    check(subtitles, "no subtitles were shown")
    check(all("[" not in text and "]" not in text for text in subtitles), "audio tags in the subtitles: %s" % subtitles)
    check(subtitles[0] == "Hej allihop!", "first subtitle %r" % subtitles[0])
    tts = buddy.find_all("tts", since)
    check(tts and all(t.get("provider") == "elevenLabs" and t.get("result") == "file" for t in tts),
          "speech was not made by ElevenLabs: %s" % [(t.get("provider"), t.get("result"), t.get("error")) for t in tts])
    check_mouth(buddy.find_all("speechEnded", since))
    said = buddy.find_all("buddySaid", since)
    check(said and normalize(said[-1]["text"]) == normalize(TAGGED_REPLY), "Buddy said %r" % (said and said[-1]["text"]))
    rendering = [t["ms"] for t in tts if t.get("cached") is False]
    ctx.note("ElevenLabs (låtsasserver): %d meningar, %.0f ms per mening inklusive talsyntes på Macen" % (
        len(rendering), sum(rendering) / max(len(rendering), 1)))
    end_since = buddy.mark()
    buddy.wait_input_ready()
    buddy.say("Tack, Buddy!")
    ended = buddy.wait_type("momentEnded", 30, end_since)
    check(ended["reason"] == "endPhrase", "moment ended because of %s" % ended["reason"])
    buddy.wait_type("phase", 15, end_since, phase="listening")


@test("T17", "Fasta repliker förbereds med Eleven v4 och spelas direkt från cachen", ["UC16"], modes=("inject",))
def test_eleven_prepared_lines(ctx):
    start_elevenlabs_buddy(ctx)
    buddy, eleven = ctx.buddy, ctx.eleven
    buddy.ensure_listening()
    since = buddy.mark()
    before = eleven.count()
    buddy.command("prepare")
    prepared = buddy.wait_type("prepared", 90, since)
    speech = eleven_speech(ctx, before)
    check(prepared.get("failed") == 0, "%s lines could not be prepared" % prepared.get("failed"))
    check(prepared.get("rendered") == len(speech) == 5,
          "prepared %s lines with %d requests, expected 5" % (prepared.get("rendered"), len(speech)))
    check(all(item["body"].get("model_id") == "eleven_v4" for item in speech),
          "fixed lines were prepared with %s" % sorted({item["body"].get("model_id") for item in speech}))
    scripted_since = buddy.mark()
    before = eleven.count()
    buddy.say("Har du några sista ord, Buddy?")
    started = buddy.wait_type("momentStarted", 20, scripted_since)
    check(started["title"] == "Avslutning", "started %r" % started["title"])
    lines = ctx.scenario["moments"][2]["lines"]
    first = buddy.wait_type("speechStarted", 15, scripted_since)
    check(normalize(first["text"]) == lines[0], "first line was %r" % first["text"])
    buddy.wait_type("phase", 20, scripted_since, phase="awaitingReply")
    buddy.wait_input_ready()
    buddy.say("Och sen då?")
    ended = buddy.wait_type("momentEnded", 30, scripted_since)
    check(ended["reason"] == "lastTurn", "moment ended because of %s" % ended["reason"])
    tts = buddy.find_all("tts", scripted_since)
    check(len(tts) == 2 and all(t.get("cached") and t.get("model") == "eleven_v4" for t in tts),
          "lines did not play from the Eleven v4 cache: %s" % [(t.get("model"), t.get("cached")) for t in tts])
    check(eleven.count() == before, "ElevenLabs was asked again instead of using the prepared audio")
    buddy.wait_type("phase", 15, scripted_since, phase="listening")


@test("T18", "Om ElevenLabs inte svarar pratar Buddy vidare med macOS-rösten", ["UC17"], modes=("inject",))
def test_eleven_fallback(ctx):
    start_elevenlabs_buddy(ctx)
    buddy, eleven = ctx.buddy, ctx.eleven
    buddy.ensure_listening()
    since = buddy.mark()
    before = eleven.count()
    eleven.fail_speech = 10
    try:
        buddy.say("Eller hur, Buddy?")
        started = buddy.wait_type("momentStarted", 20, since)
        check(started["title"] == "Kan AI ta jobben?", "started %r" % started["title"])
        fallback = buddy.wait_for(lambda e: e.get("type") == "tts" and e.get("fallback"), 40,
                                  "the macOS voice to take over", since)
        check(fallback.get("provider") == "system" and fallback.get("result") in ("file", "live"),
              "fallback speech: %s" % fallback)
        buddy.wait_type("speechStarted", 20, since)
        ended = buddy.wait_type("momentEnded", 60, since)
        check(ended["reason"] == "lastTurn", "moment ended because of %s" % ended["reason"])
    finally:
        eleven.fail_speech = 0
    failed = [r for r in eleven.all("speech", before) if r["failed"]]
    check(failed, "ElevenLabs was not asked")
    check_mouth(buddy.find_all("speechEnded", since))
    buddy.wait_type("phase", 15, since, phase="listening")


@test("T19", "Avslutas rent (ElevenLabs)", ["UC1"], modes=("inject",), quits=True)
def test_quit_elevenlabs(ctx):
    start_elevenlabs_buddy(ctx)
    test_quit(ctx)


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
        if result["status"] == "skipped":
            continue  # a test that does not run in this mode covers nothing here
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
    eleven = MockElevenLabs(out / "elevenlabs-audio", swedish_voice())
    eleven.start()

    stub_args = [str(tools["PresentationStub"])] + (["--windowed"] if args.windowed else [])
    stub = subprocess.Popen(stub_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(4)

    buddy = Buddy(args, out, mock.url, voice)
    ctx = Context(buddy, mock, tools, out, args.mode, scenario, eleven=eleven, args=args)
    results = []
    blocked = None
    try:
        try:
            buddy.launch()
        except subprocess.CalledProcessError as error:
            blocked = "Buddy could not be opened: %s" % (error.stderr or error)
        for entry in TESTS:
            result = {"id": entry["id"], "title": entry["title"], "useCases": entry["useCases"], "seconds": 0.0}
            if args.mode not in entry["modes"]:
                result["status"] = "skipped"
                result["error"] = "inte i läget %s" % args.mode
                results.append(result)
                continue
            if blocked:
                result["status"] = "failed" if entry["id"] == "T01" else "skipped"
                result["error"] = blocked
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
            if entry["id"] == "T01" and result["status"] == "failed":
                blocked = "skipped because the app did not start correctly (T01)"
                continue
            current = ctx.buddy
            if result["status"] == "failed" and not entry["quits"] and current.alive():
                try:
                    current.ensure_listening()
                except TestFailure:
                    pass
            if not current.alive() and not entry["quits"]:
                crashes = collect_crash_reports(out)
                ctx.note("Buddy avslutades oväntat. Kraschrapporter: %s" % (crashes or "inga"))
                break
    finally:
        current = ctx.buddy
        if current.alive() and current.pid:
            subprocess.run(["kill", str(current.pid)], capture_output=True)
        stub.terminate()
        mock.stop()
        eleven.stop()
        (out / "claude-requests.json").write_text(json.dumps(mock.requests, indent=2, ensure_ascii=False))
        (out / "elevenlabs-requests.json").write_text(json.dumps(eleven.requests, indent=2, ensure_ascii=False))

    failed = write_report(ctx, results, out, args.mode, started)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
