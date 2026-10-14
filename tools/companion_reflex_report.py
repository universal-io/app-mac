#!/usr/bin/env python3
"""Reads the companion's DEBUG session records and reports what the reflex
(build 37 experiment) did: how early the ear heard words, when the reflex
fired, how often the guide's look claimed the speculative read, and how
long the user waited after they stopped talking.

Usage: python3 tools/companion_reflex_report.py [N]   (newest N sessions, default 10)
"""
import glob
import json
import os
import statistics
import sys


def load(path):
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def turns(events):
    """Splits the record into the user's turns (userStarted .. next userStarted)."""
    out = []
    i = 0
    while i < len(events):
        if events[i].get("kind") != "userStarted":
            i += 1
            continue
        turn = {"start": events[i]["t"], "stop": None, "text": "", "partials": [],
                "reflex": [], "spec": None, "hit": None, "unused": [], "look": None,
                "answer": None, "served": None, "bridge": None, "noise": None}
        j = i + 1
        while j < len(events) and events[j].get("kind") != "userStarted":
            e = events[j]
            kind = e.get("kind")
            if kind == "userStopped" and turn["stop"] is None:
                turn["stop"] = e["t"]
            elif kind == "user":
                turn["text"] += e.get("text", "").replace(" ", "")
            elif kind == "partial":
                turn["partials"].append(e)
            elif kind == "reflex":
                turn["reflex"].append(e)
            elif kind == "reflex.spec" and turn["spec"] is None:
                turn["spec"] = e
            elif kind == "reflex.bridge":
                turn["bridge"] = e
            elif kind == "noise.rejected":
                turn["noise"] = e
            elif kind == "reflex.hit":
                turn["hit"] = e
            elif kind == "reflex.unused":
                turn["unused"].append(e)
            elif kind == "look" and turn["look"] is None:
                turn["look"] = e
            elif kind == "reflex.served":
                turn["served"] = e
            elif kind == "answer" and turn["answer"] is None:
                turn["answer"] = e
            j += 1
        if turn["text"] or turn["partials"]:
            out.append(turn)
        i = j
    return out


def median(values):
    return round(statistics.median(values), 2) if values else None


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    root = os.path.expanduser("~/Library/Application Support/UniversalIO/CompanionSessions")
    sessions = sorted(glob.glob(os.path.join(root, "*", "conversation.jsonl")))[-count:]
    all_turns = []
    for path in sessions:
        name = os.path.basename(os.path.dirname(path))
        for turn in turns(load(path)):
            turn["session"] = name
            all_turns.append(turn)
    if not all_turns:
        print("no turns found")
        return

    with_words = [t for t in all_turns if t["text"]]
    first_partial = [t["partials"][0]["ms"] for t in with_words if t["partials"]]
    fired = [t for t in all_turns if t["spec"]]
    hits = [t for t in fired if t["hit"]]
    looks = [t for t in all_turns if t["look"] and t["answer"] and t["stop"] is not None]
    wait_hit = [t["answer"]["t"] - t["stop"] for t in looks if t["hit"]]
    wait_plain = [t["answer"]["t"] - t["stop"] for t in looks if not t["hit"]]
    head_start = [t["hit"]["headStartMs"] / 1000 for t in hits]
    fire_at = [t["spec"]["sinceTurnMs"] / 1000 for t in fired]
    reflex_ms = [e["ms"] for t in all_turns for e in t["reflex"] if "ms" in e]

    print(f"sessions {len(sessions)}, turns with words {len(with_words)}")
    print(f"ear: turns with partials {len(first_partial)}/{len(with_words)}, first partial after start (s) median {median([v / 1000 for v in first_partial])}")
    print(f"reflex calls {len(reflex_ms)}, round trip (ms) median {median(reflex_ms)}")
    print(f"speculative looks {len(fired)}: fired at (s after turn start) median {median(fire_at)}; "
          f"claimed by the guide {len(hits)}, unused {len(fired) - len(hits)}")
    print(f"head start when claimed (s) median {median(head_start)}")
    bridge_after_stop = [t["bridge"]["t"] - t["stop"] for t in all_turns if t.get("bridge") and t["stop"] is not None]
    print(f"clip 「確認しますね」 after the user stopped (s) median {median(bridge_after_stop)} (n={len(bridge_after_stop)}); noises rejected {sum(1 for t in all_turns if t.get('noise'))}")
    print(f"wait after the user stopped until the answer (s): with reflex median {median(wait_hit)} (n={len(wait_hit)}), "
          f"without median {median(wait_plain)} (n={len(wait_plain)})")
    screen = [t for t in all_turns if t["look"]]
    missed = [t for t in screen if not t["spec"] and t["reflex"]]
    print(f"looks the guide made without a speculative read: {len(missed)}/{len(screen)}")
    print()
    print("turn, session, utterance s, text, fired at s, hit/unused, wait s")
    for t in all_turns:
        dur = round((t["stop"] or t["start"]) - t["start"], 1)
        fired_at = round(t["spec"]["sinceTurnMs"] / 1000, 1) if t["spec"] else "-"
        status = "hit" if t["hit"] else ("unused:" + ",".join(u.get("reason", "?") for u in t["unused"]) if t["unused"] else ("-" if not t["spec"] else "open"))
        wait = round(t["answer"]["t"] - t["stop"], 1) if t["answer"] and t["stop"] is not None else "-"
        best = max((e.get("pScreen", 0) for e in t["reflex"]), default=None)
        print(f"  {t['session']} {dur:>5} {t['text'][:28]:<28} p={best if best is None else round(best, 2)} fire={fired_at} {status} wait={wait}")


if __name__ == "__main__":
    main()
