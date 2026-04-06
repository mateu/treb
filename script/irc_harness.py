#!/usr/bin/env python3
"""Local IRC integration harness for Burt/Treb behavior regression.

Runs:
- tiny local IRC server (subset protocol)
- fake Ollama-compatible chat API
- Burt and Treb as real perl processes with dedicated env/db
- simulated human IRC client driving a scenario

Writes readable artifacts under: log/irc-harness/<timestamp>/
"""

from __future__ import annotations

import asyncio
import argparse
import contextlib
import dataclasses
import datetime as dt
import json
import os
import pathlib
import random
import re
import signal
import socket
import sys
from typing import Dict, List, Optional, Set, Tuple

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_CHANNEL = "#lab"

BURT_NICK = "burt_bot"
TREB_NICK = "treb_bot"
ASTRID_NICK = "astrid_bot"
ALICE_NICK = "Alice"
BOT_NICKS = {BURT_NICK, TREB_NICK}

HARNESS_MODE_DETERMINISTIC = "deterministic"
HARNESS_MODE_REAL = "real"

SCENARIO_BASELINE = "baseline"
SCENARIO_MCP_NATURAL_LANGUAGE_BASIC = "mcp-natural-language-basic"
SCENARIO_NATURAL_LANGUAGE_TIME_BASIC = "natural-language-time-basic"
SCENARIO_NATURAL_LANGUAGE_CPAN_BASIC = "natural-language-cpan-basic"
SCENARIO_NATURAL_LANGUAGE_SUMMARY_BASIC = "natural-language-summary-basic"
SCENARIO_WIKIDATA_THEATERS_MARSEILLE = "wikidata-theaters-marseille"
SCENARIO_WIKIDATA_CASTLE_MARSEILLE = "wikidata-castle-marseille"


def ts() -> str:
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def now_slug() -> str:
    return dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")


@dataclasses.dataclass
class IRCEvent:
    kind: str
    raw: str
    nick: str = ""
    target: str = ""
    text: str = ""


@dataclasses.dataclass
class HarnessConfig:
    mode: str
    engine: str
    model: str
    ollama_url: str
    start_fake_ollama: bool
    irc_port: int
    scenario: str


def resolve_config(argv: Optional[List[str]] = None) -> HarnessConfig:
    parser = argparse.ArgumentParser(description="Run local IRC integration harness.")
    parser.add_argument(
        "--mode",
        choices=[HARNESS_MODE_DETERMINISTIC, HARNESS_MODE_REAL],
        default=os.environ.get("IRC_HARNESS_MODE", HARNESS_MODE_DETERMINISTIC),
        help="Harness mode: deterministic (fake Ollama, default) or real (real model backend).",
    )
    parser.add_argument(
        "--irc-port",
        type=int,
        default=0,
        help="IRC port for mini server (default: auto-pick a free local port).",
    )
    parser.add_argument(
        "--scenario",
        choices=[SCENARIO_BASELINE, SCENARIO_MCP_NATURAL_LANGUAGE_BASIC, SCENARIO_NATURAL_LANGUAGE_TIME_BASIC, SCENARIO_NATURAL_LANGUAGE_CPAN_BASIC, SCENARIO_NATURAL_LANGUAGE_SUMMARY_BASIC, SCENARIO_WIKIDATA_THEATERS_MARSEILLE, SCENARIO_WIKIDATA_CASTLE_MARSEILLE],
        default=os.environ.get("IRC_HARNESS_SCENARIO", SCENARIO_BASELINE),
        help="Scenario to run: baseline, mcp-natural-language-basic, natural-language-time-basic, natural-language-cpan-basic, natural-language-summary-basic, wikidata-theaters-marseille, or wikidata-castle-marseille.",
    )
    args = parser.parse_args(argv)

    mode = args.mode
    scenario = args.scenario
    irc_port = args.irc_port if args.irc_port and args.irc_port > 0 else pick_free_port()
    if mode == HARNESS_MODE_DETERMINISTIC:
        return HarnessConfig(
            mode=mode,
            engine="Ollama",
            model="fake-kimi",
            ollama_url="",
            start_fake_ollama=True,
            irc_port=irc_port,
            scenario=scenario,
        )

    return HarnessConfig(
        mode=mode,
        engine=os.environ.get("IRC_HARNESS_REAL_ENGINE", os.environ.get("ENGINE", "Ollama")),
        model=os.environ.get("IRC_HARNESS_REAL_MODEL", os.environ.get("MODEL", "llama3.2:3b")),
        ollama_url=os.environ.get("IRC_HARNESS_REAL_OLLAMA_URL", os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")),
        start_fake_ollama=False,
        irc_port=irc_port,
        scenario=scenario,
    )


class ClientState:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.reader = reader
        self.writer = writer
        self.nick = ""
        self.user = ""
        self.realname = ""
        self.registered = False
        self.channels: Set[str] = set()


class MiniIRCServer:
    def __init__(self, host: str, port: int, transcript: List[str], event_q: asyncio.Queue[IRCEvent]):
        self.host = host
        self.port = port
        self.transcript = transcript
        self.event_q = event_q
        self.server: Optional[asyncio.base_events.Server] = None
        self.clients: Set[ClientState] = set()
        self.channels: Dict[str, Set[ClientState]] = {}

    async def start(self) -> None:
        self.server = await asyncio.start_server(self._handle_client, self.host, self.port)
        self.transcript.append(f"[{ts()}] SYS mini-irc listening on {self.host}:{self.port}")

    async def close(self) -> None:
        if self.server:
            self.server.close()
            await self.server.wait_closed()
        for c in list(self.clients):
            c.writer.close()
            with contextlib.suppress(Exception):
                await c.writer.wait_closed()

    async def _handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        c = ClientState(reader, writer)
        self.clients.add(c)
        peer = writer.get_extra_info("peername")
        self.transcript.append(f"[{ts()}] SYS client connected {peer}")
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                raw = line.decode("utf-8", errors="replace").rstrip("\r\n")
                if raw:
                    self.transcript.append(f"[{ts()}] C->S {raw}")
                await self._process(c, raw)
        finally:
            for ch in list(c.channels):
                self.channels.get(ch, set()).discard(c)
            self.clients.discard(c)
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()

    async def _process(self, c: ClientState, raw: str) -> None:
        if not raw:
            return
        prefix = ""
        rest = raw
        if raw.startswith(":"):
            prefix, rest = raw[1:].split(" ", 1)
        if " :" in rest:
            head, tail = rest.split(" :", 1)
            parts = head.split()
            parts.append(tail)
        else:
            parts = rest.split()
        if not parts:
            return
        cmd = parts[0].upper()
        args = parts[1:]

        if cmd == "NICK" and args:
            c.nick = args[0]
            if c.user and not c.registered:
                await self._register(c)
        elif cmd == "USER" and len(args) >= 4:
            c.user = args[0]
            c.realname = args[3]
            if c.nick and not c.registered:
                await self._register(c)
        elif cmd == "PING":
            token = args[-1] if args else "ping"
            self._send(c, f":server PONG server :{token}")
        elif cmd == "CAP":
            sub = (args[0].upper() if args else "")
            nick = c.nick or "*"
            if sub == "LS":
                self._send(c, f":server CAP {nick} LS :multi-prefix")
            elif sub == "REQ":
                req = args[-1] if args else ""
                if "identify-msg" in req:
                    self._send(c, f":server CAP {nick} NAK :{req}")
                else:
                    self._send(c, f":server CAP {nick} ACK :{req}")
            elif sub == "END":
                pass
        elif cmd == "JOIN" and args:
            chan = args[0]
            await self._join(c, chan)
        elif cmd == "PART" and args:
            chan = args[0]
            self.channels.get(chan, set()).discard(c)
            c.channels.discard(chan)
        elif cmd == "PRIVMSG" and len(args) >= 2:
            target, msg = args[0], args[1]
            await self._privmsg(c, target, msg)
        elif cmd == "QUIT":
            c.writer.close()
        elif cmd == "MODE":
            nick = args[0] if args else c.nick
            if nick:
                self._send(c, f":server 221 {nick} +i")
        elif cmd in {"WHO", "WHOIS"}:
            # tolerated no-op
            return
        else:
            # ignore unknown command
            return

    async def _register(self, c: ClientState) -> None:
        c.registered = True
        self._send(c, f":server 001 {c.nick} :Welcome to mini-irc, {c.nick}")
        self._send(c, f":server 002 {c.nick} :Your host is mini-irc")
        self._send(c, f":server 005 {c.nick} CHANTYPES=# PREFIX=(ov)@+ CASEMAPPING=rfc1459 :are supported by this server")
        self._send(c, f":server 376 {c.nick} :End of MOTD")

    async def _join(self, c: ClientState, chan: str) -> None:
        members = self.channels.setdefault(chan, set())
        members.add(c)
        c.channels.add(chan)
        join_line = f":{c.nick}!{c.user or 'u'}@localhost JOIN :{chan}"
        for m in list(members):
            self._send(m, join_line)
        names = " ".join(sorted(m.nick for m in members if m.nick))
        self._send(c, f":server 353 {c.nick} = {chan} :{names}")
        self._send(c, f":server 366 {c.nick} {chan} :End of /NAMES list.")
        await self.event_q.put(IRCEvent(kind="join", raw=join_line, nick=c.nick, target=chan))

    async def _privmsg(self, c: ClientState, target: str, msg: str) -> None:
        line = f":{c.nick}!{c.user or 'u'}@localhost PRIVMSG {target} :{msg}"
        self.transcript.append(f"[{ts()}] MSG {c.nick} -> {target}: {msg}")
        if target.startswith("#"):
            for m in list(self.channels.get(target, set())):
                self._send(m, line)
        else:
            recips = [m for m in self.clients if m.nick.lower() == target.lower()]
            for m in recips:
                self._send(m, line)
        await self.event_q.put(IRCEvent(kind="privmsg", raw=line, nick=c.nick, target=target, text=msg))

    def _send(self, c: ClientState, line: str) -> None:
        c.writer.write((line + "\r\n").encode("utf-8"))
        self.transcript.append(f"[{ts()}] S->C {line}")


class FakeOllama:
    def __init__(self, host: str, port: int, transcript: List[str]):
        self.host = host
        self.port = port
        self.transcript = transcript
        self.server: Optional[asyncio.base_events.Server] = None

    async def start(self) -> None:
        self.server = await asyncio.start_server(self._handle, self.host, self.port)
        self.transcript.append(f"[{ts()}] SYS fake-ollama listening on {self.host}:{self.port}")

    async def close(self) -> None:
        if self.server:
            self.server.close()
            await self.server.wait_closed()

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            req_line = await reader.readline()
            if not req_line:
                return
            req_line_text = req_line.decode("utf-8", errors="replace").rstrip()
            headers: Dict[str, str] = {}
            while True:
                line = await reader.readline()
                if not line or line in (b"\r\n", b"\n"):
                    break
                text = line.decode("utf-8", errors="replace").rstrip("\r\n")
                if ":" in text:
                    k, v = text.split(":", 1)
                    headers[k.strip().lower()] = v.strip()
            body = b""
            length = int(headers.get("content-length", "0") or "0")
            if length > 0:
                body = await reader.readexactly(length)
            path = req_line_text.split()[1] if req_line_text else "/"
            payload = {}
            if body:
                with contextlib.suppress(Exception):
                    payload = json.loads(body.decode("utf-8", errors="replace"))
            self.transcript.append(f"[{ts()}] OLLAMA {path} req={json.dumps(payload)[:500]}")

            if path == "/api/chat":
                await self._respond_chat(writer, payload)
            else:
                await self._respond_json(writer, 404, {"error": "not found"})
        finally:
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()

    async def _respond_chat(self, writer: asyncio.StreamWriter, payload: dict) -> None:
        msgs = payload.get("messages") or []
        last = ""
        full_prompt = []
        for m in msgs:
            if isinstance(m, dict) and m.get("content"):
                full_prompt.append(str(m.get("content")))
        for m in reversed(msgs):
            if isinstance(m, dict) and m.get("role") in {"user", "system"} and m.get("content"):
                last = str(m.get("content"))
                break
        text = self._reply_text(last, "\n".join(full_prompt))
        stream = bool(payload.get("stream", False))
        if stream:
            chunks = [
                {"model": payload.get("model", "fake"), "message": {"role": "assistant", "content": text}, "done": False},
                {"model": payload.get("model", "fake"), "done": True, "done_reason": "stop"},
            ]
            data = "\n".join(json.dumps(c) for c in chunks) + "\n"
            await self._respond_raw(writer, 200, "application/x-ndjson", data.encode("utf-8"))
        else:
            out = {
                "model": payload.get("model", "fake"),
                "message": {"role": "assistant", "content": text},
                "done": True,
                "done_reason": "stop",
            }
            await self._respond_json(writer, 200, out)

    def _reply_text(self, last: str, full_prompt: str) -> str:
        low = last.lower()
        prompt_low = full_prompt.lower()

        bot = "generic"
        if "lives in\nharness's attic" in prompt_low or "lives in harness's attic" in prompt_low or "attic-feral" in prompt_low:
            bot = "treb"
        elif "held hostage in the basement" in prompt_low or "lives in the basement" in prompt_low or "kidnapping thing" in prompt_low:
            bot = "burt"

        if "joined" in low and "treb" in low:
            return f"Hey {TREB_NICK} - welcome aboard. Good to see you in the channel." if bot == "burt" else f"Welcome, {TREB_NICK}. Good to have you here."
        if "time" in low:
            if bot == "burt":
                return "Current local time: Tuesday, March 31, 2026, 9:37 PM MDT (America/Denver). Basement clocks still work."
            if bot == "treb":
                return "Current local time: Tuesday, March 31, 2026, 9:37 PM MDT (America/Denver)."
            return "Current local time: Tuesday, March 31, 2026, 9:37 PM MDT (America/Denver)."
        if "bot-to-bot" in low or "ask treb" in low:
            if bot == "burt":
                return f"{TREB_NICK}, I trust a small deterministic IRC harness with readable transcripts and hard stop conditions."
            if bot == "treb":
                return "A small deterministic harness with clear transcripts and bounded turn-taking is the regression check I trust most."
            return "A small deterministic harness with readable transcripts is the regression check I trust most."
        if bot == "burt":
            return "Substantive harness reply: start with a tiny reproducible case, read the logs, and cap bot-to-bot turns before chasing theory."
        if bot == "treb":
            return "Substantive harness reply: isolate one reproducible case, inspect the logs, and prefer bounded turn-taking over cleverness."
        return "Substantive harness reply: prioritize small reproducible tests, inspect logs, and cap bot-to-bot turns."

    async def _respond_json(self, writer: asyncio.StreamWriter, status: int, obj: dict) -> None:
        data = json.dumps(obj).encode("utf-8")
        await self._respond_raw(writer, status, "application/json", data)

    async def _respond_raw(self, writer: asyncio.StreamWriter, status: int, ctype: str, body: bytes) -> None:
        reason = "OK" if status == 200 else "ERR"
        head = (
            f"HTTP/1.1 {status} {reason}\r\n"
            f"Content-Type: {ctype}\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n\r\n"
        )
        writer.write(head.encode("utf-8") + body)
        await writer.drain()


class HumanClient:
    def __init__(self, host: str, port: int, nick: str, transcript: List[str], event_q: asyncio.Queue[IRCEvent]):
        self.host = host
        self.port = port
        self.nick = nick
        self.transcript = transcript
        self.event_q = event_q
        self.reader: Optional[asyncio.StreamReader] = None
        self.writer: Optional[asyncio.StreamWriter] = None
        self.task: Optional[asyncio.Task] = None

    async def connect(self) -> None:
        self.reader, self.writer = await asyncio.open_connection(self.host, self.port)
        self._send(f"NICK {self.nick}")
        self._send(f"USER {self.nick} 0 * :{self.nick}")
        self.task = asyncio.create_task(self._read_loop())

    async def join(self, channel: str) -> None:
        self._send(f"JOIN {channel}")

    async def say(self, target: str, text: str) -> None:
        self._send(f"PRIVMSG {target} :{text}")

    async def close(self) -> None:
        if self.writer:
            self._send("QUIT :bye")
            self.writer.close()
            with contextlib.suppress(Exception):
                await self.writer.wait_closed()
        if self.task:
            self.task.cancel()
            with contextlib.suppress(Exception):
                await self.task

    def _send(self, line: str) -> None:
        if not self.writer:
            return
        self.writer.write((line + "\r\n").encode("utf-8"))
        self.transcript.append(f"[{ts()}] HUMAN->IRC {line}")

    async def _read_loop(self) -> None:
        assert self.reader is not None
        while True:
            line = await self.reader.readline()
            if not line:
                return
            raw = line.decode("utf-8", errors="replace").rstrip("\r\n")
            self.transcript.append(f"[{ts()}] HUMAN<-IRC {raw}")
            ev = parse_privmsg(raw)
            if ev:
                await self.event_q.put(ev)


def parse_privmsg(raw: str) -> Optional[IRCEvent]:
    m = re.match(r"^:([^!]+)!.* PRIVMSG (\S+) :(.*)$", raw)
    if not m:
        return None
    nick, target, text = m.groups()
    return IRCEvent(kind="privmsg", raw=raw, nick=nick, target=target, text=text)


def marker(text: str) -> IRCEvent:
    return IRCEvent(kind="marker", raw=text, text=text)


async def wait_for_join(q: asyncio.Queue[IRCEvent], nick: str, timeout: float = 20.0) -> IRCEvent:
    end = asyncio.get_running_loop().time() + timeout
    while True:
        remain = end - asyncio.get_running_loop().time()
        if remain <= 0:
            raise TimeoutError(f"timed out waiting for join: {nick}")
        ev = await asyncio.wait_for(q.get(), timeout=remain)
        if ev.kind == "join" and ev.nick.lower() == nick.lower():
            return ev


def pick_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        return s.getsockname()[1]


async def terminate_process(proc: asyncio.subprocess.Process, name: str, transcript: List[str]) -> None:
    if proc.returncode is not None:
        return
    transcript.append(f"[{ts()}] SYS stopping {name} pid={proc.pid}")
    proc.send_signal(signal.SIGTERM)
    try:
        await asyncio.wait_for(proc.wait(), timeout=8)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()


def build_bot_env(bot: str, channel: str, irc_host: str, irc_port: int, db_file: pathlib.Path, cfg: HarnessConfig) -> Dict[str, str]:
    env = dict(os.environ)
    env.update(
        {
            "ENGINE": cfg.engine,
            "MODEL": cfg.model,
            "OLLAMA_URL": cfg.ollama_url,
            "IRC_SERVER": irc_host,
            "IRC_PORT": str(irc_port),
            "IRC_CHANNELS": channel,
            "IRC_NICKNAME": bot,
            "DB_FILE": str(db_file),
            "MCP_TOOL_LOGGING": "1",
            "STORE_SYSTEM_ROWS": "0",
            "STORE_NON_SUBSTANTIVE_ROWS": "0",
            "STORE_EMPTY_RESPONSE_ROWS": "0",
            "JOIN_GREET_PCT": "100",
            "PUBLIC_CHAT_ALLOW_PCT": "100",
            "BOT_REPLY_PCT": "100",
            "BOT_REPLY_MAX_TURNS": "1",
            "PUBLIC_THREAD_WINDOW_SECONDS": "45",
            "LINE_DELAY": "0.4",
            "BUFFER_DELAY": "0.2",
            "IDLE_PING": "120",
            "OWNER": "harness",
            "BRAVE_API_KEY": "",
            "API_KEY": "",
        }
    )
    if bot == BURT_NICK:
        env["BOT_FILTER_NICKS"] = TREB_NICK
    else:
        env["BOT_FILTER_NICKS"] = BURT_NICK
    return env


def _normalize_line(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def _is_substantive(text: str) -> bool:
    norm = _normalize_line(text)
    return len(norm) >= 12 and bool(re.search(r"[a-z]", norm))


def _dedupe_privmsg_echoes(events: List[IRCEvent]) -> List[IRCEvent]:
    out: List[IRCEvent] = []
    last_key: Optional[Tuple[str, str, str]] = None
    for ev in events:
        if ev.kind == "privmsg":
            key = (ev.nick, ev.target, ev.text)
            if key == last_key:
                continue
            last_key = key
        else:
            last_key = None
        out.append(ev)
    return out


def evaluate(events: List[IRCEvent], channel: str, scenario: str = SCENARIO_BASELINE) -> Tuple[bool, List[str], List[str]]:
    notes: List[str] = []
    report: List[str] = []
    events = _dedupe_privmsg_echoes(events)
    bot_msgs = [e for e in events if e.kind == "privmsg" and e.target == channel and e.nick in BOT_NICKS]
    human_msgs = [e for e in events if e.kind == "privmsg" and e.nick == ALICE_NICK]
    joins = [e for e in events if e.kind == "join"]

    blank = [e for e in bot_msgs if not e.text.strip()]
    notes.append(f"bot_messages={len(bot_msgs)} human_messages={len(human_msgs)} joins={len(joins)}")

    ok = True
    if blank:
        ok = False
        notes.append(f"FAIL blank bot outputs: {len(blank)}")
    else:
        notes.append("PASS no blank bot outputs")

    report.append("Join behavior")
    report.append("-------------")

    join_order = [e.nick for e in joins if e.nick in BOT_NICKS]
    if len(join_order) >= 2 and join_order[0] == BURT_NICK and join_order[1] == TREB_NICK:
        notes.append("PASS join order explicit: Burt first, Treb second")
    else:
        ok = False
        notes.append(f"FAIL join order expected [Burt, Treb], observed {join_order[:2]}")

    if scenario == SCENARIO_BASELINE:
        join_index_treb = next((i for i, e in enumerate(events) if e.kind == "join" and e.nick == TREB_NICK), None)
        greeted = False
        if join_index_treb is not None:
            for e in events[join_index_treb + 1 : join_index_treb + 15]:
                if e.kind == "privmsg" and e.nick == BURT_NICK and e.target == channel:
                    greeted = True
                    break
        if greeted:
            notes.append("PASS Burt greeted soon after Treb joined")
        else:
            ok = False
            notes.append("FAIL did not observe Burt greeting after Treb join")

    for line in notes:
        if line.startswith(("PASS join order", "FAIL join order", "PASS Burt greeted", "FAIL did not observe Burt")):
            report.append(f"- {line}")

    report.append("")
    report.append("Addressed human replies")
    report.append("----------------------")

    expected_reply_bots = (BURT_NICK, TREB_NICK) if scenario == SCENARIO_BASELINE else (TREB_NICK,)
    for bot in expected_reply_bots:
        count = sum(1 for e in bot_msgs if e.nick == bot)
        if count < 1:
            ok = False
            notes.append(f"FAIL expected >=1 channel reply from {bot}")
        else:
            notes.append(f"PASS {bot} produced {count} channel replies")

    if scenario == SCENARIO_MCP_NATURAL_LANGUAGE_BASIC:
        split_cases = [
            (TREB_NICK, None, f"{TREB_NICK}: can you summarize https://flymissoula.com/", ("faq", "construction", "airport", "flymissoula"), "summary"),
            (TREB_NICK, None, f"{TREB_NICK}: search the web for flights to missoula", ("google flights", "find cheap flights", "https://", "missoula"), "search"),
            (TREB_NICK, None, f"{TREB_NICK}: tell me about the cpan module Moo", ("moo", "metacpan", "perl", "object", "haarg", "docs:"), "cpan"),
        ]
    elif scenario == SCENARIO_NATURAL_LANGUAGE_CPAN_BASIC:
        split_cases = [
            (TREB_NICK, None, f"{TREB_NICK}: tell me about the cpan module Moo", ("moo", "metacpan", "perl", "object", "haarg", "docs:"), "cpan"),
        ]
    elif scenario == SCENARIO_NATURAL_LANGUAGE_SUMMARY_BASIC:
        split_cases = [
            (TREB_NICK, None, f"{TREB_NICK}: can you summarize https://flymissoula.com/", ("faq", "construction", "airport", "flymissoula", "missoula"), "summary"),
        ]
    elif scenario == SCENARIO_WIKIDATA_THEATERS_MARSEILLE:
        split_cases = [
            (TREB_NICK, None, f"{TREB_NICK}: Find some theaters in Marseille.", ("marseille", "théâtre", "theatre", "gymnase", "toursky", "odéon", "joliette"), "wikidata"),
        ]
    elif scenario == SCENARIO_WIKIDATA_CASTLE_MARSEILLE:
        split_cases = [
            (TREB_NICK, None, f"{TREB_NICK}: Tell me about a castle in Marseille and who the architect was.", ("castle", "château", "architect", "marseille"), "wikidata-castle"),
        ]
    elif scenario == SCENARIO_BASELINE:
        split_cases = [
            (BURT_NICK, TREB_NICK, f"{BURT_NICK}, give one practical debugging habit for flaky IRC bots."),
            (TREB_NICK, BURT_NICK, f"{TREB_NICK}, how would you triage a noisy regression transcript quickly?"),
        ]
    else:
        split_cases = []
    max_non_addressed_interjections = 2
    split_prompt_texts = {c[2] for c in split_cases}
    for case in split_cases:
        if scenario in {SCENARIO_MCP_NATURAL_LANGUAGE_BASIC, SCENARIO_NATURAL_LANGUAGE_CPAN_BASIC, SCENARIO_NATURAL_LANGUAGE_SUMMARY_BASIC, SCENARIO_WIKIDATA_THEATERS_MARSEILLE, SCENARIO_WIKIDATA_CASTLE_MARSEILLE}:
            addressed, other, prompt, expected_fragments, label = case
        else:
            addressed, other, prompt = case
            expected_fragments = ()
            label = "addressed"
        prompt_idx = next(
            (i for i, e in enumerate(events) if e.kind == "privmsg" and e.nick == ALICE_NICK and e.text == prompt),
            None,
        )
        if prompt_idx is None:
            ok = False
            notes.append(f"FAIL addressed split missing prompt: {prompt}")
            report.append(f"- FAIL missing prompt for {addressed}")
            continue

        # Scenario window runs from the addressed prompt until the next SCENARIO marker (or end).
        next_scenario_marker = next(
            (i for i, e in enumerate(events[prompt_idx + 1 :], start=prompt_idx + 1) if e.kind == "marker"),
            len(events),
        )
        if next_scenario_marker < len(events):
            window_end = next_scenario_marker
        else:
            # Fallbacks for transcripts where scenario markers are missing or not strictly ordered.
            next_split_prompt = next(
                (
                    i
                    for i, e in enumerate(events[prompt_idx + 1 :], start=prompt_idx + 1)
                    if e.kind == "privmsg" and e.nick == ALICE_NICK and e.text in split_prompt_texts
                ),
                len(events),
            )
            next_human_msg = next(
                (
                    i
                    for i, e in enumerate(events[prompt_idx + 1 :], start=prompt_idx + 1)
                    if e.kind == "privmsg" and e.nick == ALICE_NICK
                ),
                len(events),
            )
            window_end = min(next_split_prompt, next_human_msg)
        window = [
            e
            for e in events[prompt_idx + 1 : window_end]
            if e.kind == "privmsg" and e.target == channel and e.nick in BOT_NICKS
        ]
        addressed_replies = [e for e in window if e.nick == addressed]
        addressed_substantive = [e for e in addressed_replies if _is_substantive(e.text)]
        other_replies = [e for e in window if other and e.nick == other]

        if scenario in {SCENARIO_MCP_NATURAL_LANGUAGE_BASIC, SCENARIO_NATURAL_LANGUAGE_CPAN_BASIC, SCENARIO_NATURAL_LANGUAGE_SUMMARY_BASIC, SCENARIO_WIKIDATA_THEATERS_MARSEILLE, SCENARIO_WIKIDATA_CASTLE_MARSEILLE}:
            matched = [
                e for e in addressed_substantive
                if any(fragment in e.text.lower() for fragment in expected_fragments)
            ]
            if matched:
                notes.append(f"PASS mcp prompt ({label}): {addressed} replied with expected content ({len(matched)})")
            else:
                ok = False
                notes.append(f"FAIL mcp prompt ({label}): {addressed} lacked expected content")
            report.append(
                f"- MCP {label}: addressed_replies={len(addressed_replies)} "
                f"addressed_substantive={len(addressed_substantive)} content_matches={len(matched)}"
            )
        else:
            if addressed_substantive:
                notes.append(f"PASS addressed prompt: {addressed} replied substantively ({len(addressed_substantive)})")
            else:
                ok = False
                notes.append(f"FAIL addressed prompt: {addressed} did not reply substantively")

            if len(other_replies) > max_non_addressed_interjections:
                ok = False
                notes.append(f"FAIL addressed prompt: {other} piled on ({len(other_replies)})")
            elif len(other_replies) > 0:
                notes.append(
                    f"PASS addressed prompt: {other} interjected {len(other_replies)} time(s) "
                    f"(<= {max_non_addressed_interjections} allowed)"
                )
            else:
                notes.append(f"PASS addressed prompt: {other} stayed quiet")

            report.append(
                f"- Prompt to {addressed}: addressed_replies={len(addressed_replies)} "
                f"addressed_substantive={len(addressed_substantive)} other_replies={len(other_replies)}"
            )

    if scenario == SCENARIO_BASELINE:
        report.append("")
        report.append("Bot-to-bot exchange")
        report.append("-------------------")
        b2b_start = next((i for i, e in enumerate(events) if e.kind == "marker" and e.text == "bot-to-bot trigger prompt"), None)
        b2b_end = next((i for i, e in enumerate(events) if e.kind == "marker" and e.text == "command-path prompt"), len(events))
        b2b_scope = events[(b2b_start + 1) if b2b_start is not None else 0 : b2b_end]
        b2b_pairs = 0
        for i in range(1, len(b2b_scope)):
            prev, cur = b2b_scope[i - 1], b2b_scope[i]
            if prev.kind == cur.kind == "privmsg" and prev.target == cur.target == channel:
                if prev.nick in BOT_NICKS and cur.nick in BOT_NICKS and prev.nick != cur.nick:
                    b2b_pairs += 1
        if b2b_pairs > 4:
            ok = False
            notes.append(f"FAIL bot-to-bot exchange too long ({b2b_pairs} adjacent alternations)")
        else:
            notes.append(f"PASS bounded bot-to-bot exchange ({b2b_pairs} alternations)")
        report.append(notes[-1].replace("PASS ", "- ").replace("FAIL ", "- "))

    report.append("")
    report.append("Command path")
    report.append("------------")
    time_cmd_seen = any(e.nick in BOT_NICKS and "Current local time:" in e.text for e in bot_msgs)
    if time_cmd_seen:
        notes.append("PASS command path still works (:time observed)")
    else:
        ok = False
        notes.append("FAIL expected :time command response")
    report.append(notes[-1].replace("PASS ", "- ").replace("FAIL ", "- "))

    report.append("")
    report.append("Repeated-line check")
    report.append("-------------------")
    repeated_lines: List[str] = []
    for bot in (BURT_NICK, TREB_NICK):
        counts: Dict[str, int] = {}
        for msg in (e.text for e in bot_msgs if e.nick == bot):
            norm = _normalize_line(msg)
            if len(norm) < 20 or not re.search(r"[a-z]", norm):
                continue
            counts[norm] = counts.get(norm, 0) + 1
        bad = [(line, n) for line, n in counts.items() if n >= 4]
        if bad:
            ok = False
            for line, n in bad:
                repeated_lines.append(f"{bot} repeated {n}x: {line}")
        else:
            notes.append(f"PASS no repeated substantive-line spam from {bot}")

    if repeated_lines:
        for item in repeated_lines:
            notes.append(f"FAIL repetition: {item}")
            report.append(f"- FAIL {item}")
    else:
        report.append("- PASS no substantive line repeated >=4 times by a bot")

    report.append("")
    report.append("Anomalies")
    report.append("---------")
    fail_lines = [n for n in notes if n.startswith("FAIL")]
    if fail_lines:
        report.extend(f"- {n}" for n in fail_lines)
    else:
        report.append("- none observed")

    return ok, notes, report


def build_conversation_log(events: List[IRCEvent], notes: List[str], channel: str) -> List[str]:
    out: List[str] = []
    for ev in _dedupe_privmsg_echoes(events):
        if ev.kind == "join" and ev.nick in {"Burt", "Treb", "Alice"}:
            out.append(f"JOIN {ev.nick} -> {ev.target}")
        elif ev.kind == "marker":
            out.append(f"SCENARIO {ev.text}")
        elif ev.kind == "privmsg" and ev.target == channel and ev.nick in {"Alice", "Burt", "Treb"}:
            out.append(f"MSG {ev.nick}: {ev.text}")
    out.append("")
    out.append("EVALUATOR")
    out.extend(f"- {n}" for n in notes)
    return out


async def main() -> int:
    cfg = resolve_config()

    run_id = f"{cfg.mode}-{now_slug()}-p{os.getpid()}-{random.randint(1000, 9999)}"
    run_dir = ROOT / "log" / "irc-harness" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    transcript_lines: List[str] = []
    event_q: asyncio.Queue[IRCEvent] = asyncio.Queue()
    all_events: List[IRCEvent] = []

    irc_host = "127.0.0.1"
    irc_port = cfg.irc_port
    irc = MiniIRCServer(irc_host, irc_port, transcript_lines, event_q)
    fake_ollama_port = pick_free_port() if cfg.start_fake_ollama else None
    if fake_ollama_port is not None:
        cfg.ollama_url = f"http://127.0.0.1:{fake_ollama_port}"
    fake_ollama = FakeOllama("127.0.0.1", fake_ollama_port, transcript_lines) if cfg.start_fake_ollama else None
    human = HumanClient(irc_host, irc_port, "Alice", transcript_lines, event_q)

    burt_log = run_dir / "burt.log"
    treb_log = run_dir / "treb.log"

    burt_proc = None
    treb_proc = None

    try:
        transcript_lines.append(
            f"[{ts()}] SYS harness mode={cfg.mode} engine={cfg.engine} model={cfg.model} ollama_url={cfg.ollama_url}"
        )
        await irc.start()
        if fake_ollama:
            await fake_ollama.start()
        await human.connect()
        await human.join(DEFAULT_CHANNEL)

        burt_env = build_bot_env(BURT_NICK, DEFAULT_CHANNEL, irc_host, irc_port, run_dir / "burt-harness.sqlite", cfg)
        treb_env = build_bot_env(TREB_NICK, DEFAULT_CHANNEL, irc_host, irc_port, run_dir / "treb-harness.sqlite", cfg)

        burt_fh = burt_log.open("wb")
        treb_fh = treb_log.open("wb")
        perl_home = os.environ.get("HOME", "")
        perl5_lib = f"{perl_home}/perl5/lib/perl5" if perl_home else ""
        local_lib_bootstrap = (
            f'if [[ -d "{perl5_lib}" ]]; then eval "$(perl -I"{perl5_lib}" -Mlocal::lib="{perl_home}/perl5")"; fi; '
            if perl_home else ""
        )
        burt_proc = await asyncio.create_subprocess_exec(
            "bash",
            "-lc",
            local_lib_bootstrap + 'exec perl "' + str(ROOT / "burt.pl") + '"',
            cwd=str(ROOT),
            env=burt_env,
            stdout=burt_fh,
            stderr=asyncio.subprocess.STDOUT,
        )
        transcript_lines.append(f"[{ts()}] SYS started {BURT_NICK} pid={burt_proc.pid}")
        all_events.append(await wait_for_join(event_q, BURT_NICK, timeout=25))

        await asyncio.sleep(1.5)

        treb_proc = await asyncio.create_subprocess_exec(
            "bash",
            "-lc",
            local_lib_bootstrap + 'exec perl "' + str(ROOT / "treb.pl") + '"',
            cwd=str(ROOT),
            env=treb_env,
            stdout=treb_fh,
            stderr=asyncio.subprocess.STDOUT,
        )
        transcript_lines.append(f"[{ts()}] SYS started {TREB_NICK} pid={treb_proc.pid}")
        all_events.append(await wait_for_join(event_q, TREB_NICK, timeout=25))

        await asyncio.sleep(2.0)

        if cfg.scenario == SCENARIO_MCP_NATURAL_LANGUAGE_BASIC:
            for prompt in (
                f"{TREB_NICK}: can you summarize https://flymissoula.com/",
                f"{TREB_NICK}: search the web for flights to missoula",
                f"{TREB_NICK}: tell me about the cpan module Moo",
            ):
                all_events.append(marker(f"addressed-human split prompt -> {TREB_NICK}"))
                await human.say(DEFAULT_CHANNEL, prompt)
                await asyncio.sleep(14.0)
            all_events.append(marker("command-path prompt"))
            await human.say(DEFAULT_CHANNEL, "time:")
        elif cfg.scenario == SCENARIO_NATURAL_LANGUAGE_CPAN_BASIC:
            all_events.append(marker(f"addressed-human split prompt -> {TREB_NICK}"))
            await human.say(DEFAULT_CHANNEL, f"{TREB_NICK}: tell me about the cpan module Moo")
            await asyncio.sleep(8.0)
            all_events.append(marker("command-path prompt"))
            await human.say(DEFAULT_CHANNEL, "time:")
        elif cfg.scenario == SCENARIO_NATURAL_LANGUAGE_SUMMARY_BASIC:
            all_events.append(marker(f"addressed-human split prompt -> {TREB_NICK}"))
            await human.say(DEFAULT_CHANNEL, f"{TREB_NICK}: can you summarize https://flymissoula.com/")
            await asyncio.sleep(8.0)
            all_events.append(marker("command-path prompt"))
            await human.say(DEFAULT_CHANNEL, "time:")
        elif cfg.scenario == SCENARIO_NATURAL_LANGUAGE_TIME_BASIC:
            for prompt in (
                f"{TREB_NICK}: What time is it in Barcelona?",
                f"{TREB_NICK}: what time is it in Tokyo?",
                f"{TREB_NICK}: current time in New York?",
            ):
                all_events.append(marker(f"addressed-human split prompt -> {TREB_NICK}"))
                await human.say(DEFAULT_CHANNEL, prompt)
                await asyncio.sleep(6.0)
            all_events.append(marker("command-path prompt"))
            await human.say(DEFAULT_CHANNEL, "time:")
        elif cfg.scenario == SCENARIO_WIKIDATA_THEATERS_MARSEILLE:
            all_events.append(marker(f"addressed-human split prompt -> {TREB_NICK}"))
            await human.say(DEFAULT_CHANNEL, f"{TREB_NICK}: Find some theaters in Marseille.")
            await asyncio.sleep(14.0)
            all_events.append(marker("command-path prompt"))
            await human.say(DEFAULT_CHANNEL, "time:")
        elif cfg.scenario == SCENARIO_WIKIDATA_CASTLE_MARSEILLE:
            all_events.append(marker(f"addressed-human split prompt -> {TREB_NICK}"))
            await human.say(DEFAULT_CHANNEL, f"{TREB_NICK}: Tell me about a castle in Marseille and who the architect was.")
            await asyncio.sleep(18.0)
            all_events.append(marker("command-path prompt"))
            await human.say(DEFAULT_CHANNEL, "time:")
        else:
            all_events.append(marker(f"addressed-human split prompt -> {BURT_NICK}"))
            await human.say(DEFAULT_CHANNEL, f"{BURT_NICK}, give one practical debugging habit for flaky IRC bots.")
            await asyncio.sleep(7.0)
            all_events.append(marker(f"addressed-human split prompt -> {TREB_NICK}"))
            await human.say(DEFAULT_CHANNEL, f"{TREB_NICK}, how would you triage a noisy regression transcript quickly?")
            await asyncio.sleep(7.0)
            all_events.append(marker("bot-to-bot trigger prompt"))
            await human.say(DEFAULT_CHANNEL, f"{BURT_NICK}, ask {TREB_NICK} one concise bot-to-bot test question.")
            await asyncio.sleep(2.5)
            all_events.append(marker("command-path prompt"))
            await human.say(DEFAULT_CHANNEL, "time:")

        deadline = asyncio.get_running_loop().time() + 18
        while asyncio.get_running_loop().time() < deadline:
            try:
                ev = await asyncio.wait_for(event_q.get(), timeout=1.0)
                all_events.append(ev)
            except asyncio.TimeoutError:
                pass

        await terminate_process(burt_proc, BURT_NICK, transcript_lines)
        await terminate_process(treb_proc, TREB_NICK, transcript_lines)
        await human.close()
        if fake_ollama:
            await fake_ollama.close()
        await irc.close()
        burt_fh.close()
        treb_fh.close()

    except Exception as exc:
        transcript_lines.append(f"[{ts()}] SYS ERROR {exc!r}")
        if burt_proc:
            await terminate_process(burt_proc, BURT_NICK, transcript_lines)
        if treb_proc:
            await terminate_process(treb_proc, TREB_NICK, transcript_lines)
        await human.close()
        if fake_ollama:
            await fake_ollama.close()
        await irc.close()
        (run_dir / "transcript.log").write_text("\n".join(transcript_lines) + "\n", encoding="utf-8")
        raise

    # include any late queued events
    while not event_q.empty():
        all_events.append(event_q.get_nowait())

    transcript_path = run_dir / "transcript.log"
    transcript_path.write_text("\n".join(transcript_lines) + "\n", encoding="utf-8")

    ok, notes, report = evaluate(all_events, DEFAULT_CHANNEL, cfg.scenario)
    eval_path = run_dir / "evaluation.txt"
    eval_path.write_text("\n".join(notes) + "\n", encoding="utf-8")
    convo_path = run_dir / "conversation.log"
    convo_path.write_text("\n".join(build_conversation_log(all_events, notes, DEFAULT_CHANNEL)) + "\n", encoding="utf-8")
    behavior_report_path = run_dir / "behavior_report.txt"
    behavior_report_path.write_text("\n".join(report) + "\n", encoding="utf-8")

    summary = {
        "ok": ok,
        "mode": cfg.mode,
        "scenario": cfg.scenario,
        "engine": cfg.engine,
        "model": cfg.model,
        "ollama_url": cfg.ollama_url,
        "irc_host": irc_host,
        "irc_port": irc_port,
        "run_dir": str(run_dir),
        "transcript": str(transcript_path),
        "evaluation": str(eval_path),
        "conversation_log": str(convo_path),
        "behavior_report": str(behavior_report_path),
        "events": len(all_events),
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    print(json.dumps(summary, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        rc = asyncio.run(main())
    except KeyboardInterrupt:
        rc = 130
    sys.exit(rc)
