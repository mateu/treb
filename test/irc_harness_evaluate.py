#!/usr/bin/env python3
import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MOD_PATH = ROOT / "script" / "irc_harness.py"
spec = importlib.util.spec_from_file_location("irc_harness", MOD_PATH)
irc_harness = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules["irc_harness"] = irc_harness
spec.loader.exec_module(irc_harness)

IRCEvent = irc_harness.IRCEvent
evaluate = irc_harness.evaluate
marker = irc_harness.marker
BURT_NICK = irc_harness.BURT_NICK
TREB_NICK = irc_harness.TREB_NICK
ALICE_NICK = irc_harness.ALICE_NICK

CHANNEL = "#lab"
PROMPT_BURT = f"{BURT_NICK}, give one practical debugging habit for flaky IRC bots."
PROMPT_TREB = f"{TREB_NICK}, how would you triage a noisy regression transcript quickly?"


def base_prefix_events():
    return [
        IRCEvent(kind="join", raw="", nick=BURT_NICK, target=CHANNEL),
        IRCEvent(kind="join", raw="", nick=TREB_NICK, target=CHANNEL),
        IRCEvent(kind="privmsg", raw="", nick=BURT_NICK, target=CHANNEL, text=f"Hey {TREB_NICK} — welcome aboard."),
    ]


def base_suffix_events():
    return [
        marker("command-path prompt"),
        IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text="time:"),
        IRCEvent(kind="privmsg", raw="", nick=BURT_NICK, target=CHANNEL, text="Current local time: 2026-03-31 20:00 MDT"),
    ]


class EvaluateAddressedScenarioTests(unittest.TestCase):
    def test_window_runs_until_next_scenario_marker(self):
        events = base_prefix_events() + [
            marker(f"addressed-human split prompt -> {BURT_NICK}"),
            IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text=PROMPT_BURT),
            IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text="(noise) I also have logs to upload"),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text=f"Brief interjection while {BURT_NICK} answers."),
            IRCEvent(kind="privmsg", raw="", nick=BURT_NICK, target=CHANNEL, text="Use one deterministic transcript and diff it first."),
            marker(f"addressed-human split prompt -> {TREB_NICK}"),
            IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text=PROMPT_TREB),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="I scan for first failure and map it to scenario markers."),
        ] + base_suffix_events()

        ok, notes, _ = evaluate(events, CHANNEL)
        self.assertTrue(ok, "Expected scenario window to include addressed reply after extra human line")
        self.assertTrue(any(f"{BURT_NICK} replied substantively" in n for n in notes), notes)

    def test_allows_up_to_two_non_addressed_interjections(self):
        events = base_prefix_events() + [
            marker(f"addressed-human split prompt -> {BURT_NICK}"),
            IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text=PROMPT_BURT),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="First short interjection."),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="Second short interjection."),
            IRCEvent(kind="privmsg", raw="", nick=BURT_NICK, target=CHANNEL, text="Pin one transcript, one seed, and one expected output."),
            marker(f"addressed-human split prompt -> {TREB_NICK}"),
            IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text=PROMPT_TREB),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="I rank anomalies by impact and recency."),
        ] + base_suffix_events()

        ok, notes, _ = evaluate(events, CHANNEL)
        self.assertTrue(ok, notes)
        self.assertFalse(any("piled on" in n and n.startswith("FAIL") for n in notes), notes)

    def test_fails_when_other_bot_piles_on_more_than_two(self):
        events = base_prefix_events() + [
            marker(f"addressed-human split prompt -> {BURT_NICK}"),
            IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text=PROMPT_BURT),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="Interjection one."),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="Interjection two."),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="Interjection three."),
            IRCEvent(kind="privmsg", raw="", nick=BURT_NICK, target=CHANNEL, text="Answer with a deterministic seed and fixture set."),
            marker(f"addressed-human split prompt -> {TREB_NICK}"),
            IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text=PROMPT_TREB),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="I bucket issues by parser, policy, and transport."),
        ] + base_suffix_events()

        ok, notes, _ = evaluate(events, CHANNEL)
        self.assertFalse(ok)
        self.assertTrue(any(f"FAIL addressed prompt: {TREB_NICK} piled on (3)" == n for n in notes), notes)

    def test_bot_to_bot_alternation_ignores_command_path_phase(self):
        events = base_prefix_events() + [
            marker(f"addressed-human split prompt -> {BURT_NICK}"),
            IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text=PROMPT_BURT),
            IRCEvent(kind="privmsg", raw="", nick=BURT_NICK, target=CHANNEL, text="Use one fixed transcript and one expected outcome."),
            marker(f"addressed-human split prompt -> {TREB_NICK}"),
            IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text=PROMPT_TREB),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="Start with the first divergence and map it to one lane."),
            marker("bot-to-bot trigger prompt"),
            IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text=f"{BURT_NICK}, ask {TREB_NICK} one concise bot-to-bot test question."),
            IRCEvent(kind="privmsg", raw="", nick=BURT_NICK, target=CHANNEL, text=f"{TREB_NICK}, which deterministic regression check do you trust most?"),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="A small deterministic harness with readable transcripts."),
            marker("command-path prompt"),
            IRCEvent(kind="privmsg", raw="", nick=ALICE_NICK, target=CHANNEL, text="time:"),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="Current local time: 2026-03-31 20:00 MDT"),
            IRCEvent(kind="privmsg", raw="", nick=BURT_NICK, target=CHANNEL, text="Current local time: 2026-03-31 20:00 MDT"),
            IRCEvent(kind="privmsg", raw="", nick=TREB_NICK, target=CHANNEL, text="Current local time: 2026-03-31 20:00 MDT"),
            IRCEvent(kind="privmsg", raw="", nick=BURT_NICK, target=CHANNEL, text="Current local time: 2026-03-31 20:00 MDT"),
        ]

        ok, notes, _ = evaluate(events, CHANNEL)
        self.assertTrue(ok, notes)
        self.assertTrue(any("PASS bounded bot-to-bot exchange (1 alternations)" == n for n in notes), notes)


if __name__ == "__main__":
    unittest.main()
