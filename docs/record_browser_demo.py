#!/usr/bin/env python3.12
"""Record the terminal-browser demo cast for the documentation.

Drives ``run_browser(offline = true)`` through a pseudo-terminal with pexpect and
writes an asciinema v2 cast to ``docs/assets/browser-demo.cast``. Render it to the
committed GIF with `agg <https://github.com/asciinema/agg>`_::

    agg --font-size 13 --fps-cap 12 --speed 1.15 --last-frame-duration 3 \
        --theme asciinema docs/assets/browser-demo.cast docs/src/assets/browser-demo.gif

The walk-through exercises the features shown in the docs: moving the selection,
paging (``PgDn``), the details pane (``d``), a string query (``s``), and the
column-visibility picker (``c``).

Re-record whenever the column set in ``src/browse.jl`` or the key bindings change.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time

import pexpect

# Tachikoma probes for terminal features (Kitty graphics APC strings, synchronized
# output, the alternate screen buffer, mouse tracking, …). Simple cast renderers such as
# `agg` desync on some of those, so the captured stream is reduced to the plain
# positioning + SGR + text that a GIF actually needs — matching the committed cast.
_STRIP = re.compile(
    rb"\x1b_[^\x1b]*\x1b\\"          # APC (Kitty graphics)
    rb"|\x1bP[^\x1b]*\x1b\\"         # DCS
    rb"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC
    rb"|\x1b\[\?[0-9;]*[hl]"         # DEC private modes (alt screen, mouse, sync, …)
    rb"|\x1b\[>[0-9;]*[a-zA-Z]"      # secondary DA / XTVERSION style queries
    rb"|\x1b\[=[0-9;]*[a-zA-Z]"
)


def _sanitize(data: bytes) -> bytes:
    return _STRIP.sub(b"", data)

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CAST = os.path.join(HERE, "assets", "browser-demo.cast")

COLS, ROWS = 150, 40

# The step delay is applied *after* the payload is sent, so each state lingers in the
# cast. ``None`` payload = a pure pause. Text fields get the whole string in one write
# (byte-at-a-time sends are dropped by the app's input loop under a pty).
SCRIPT: list[tuple[float, "bytes | None"]] = [
    (4.0, None),
    (3.0, b"g"),                                                 # goto-page prompt
    (2.5, b"40"),
    (4.5, b"\r"),                                                # jump to page 40
    (4.5, b"g"), (2.5, b"1"),
    (4.5, b"\r"),                                                # back to page 1
    (3.0, b"d"),                                                 # open the details pane
    (7.0, b"d"),                                                 # close it
    (3.0, b"s"),                                                 # open the search overlay
    (2.5, b"dataset=ocmr AND R!=nothing"),
    (6.0, b"\r"),                                                # apply the query
    (5.0, b"c"),                                                 # open the column picker
    (3.0, b" "),                                                 # toggle the highlighted column
    (3.5, b" "),                                                 # toggle it back on
    (5.0, b"\r"),                                                # apply
    (5.0, b"q"),                                                 # quit
    (2.0, None),
]

JULIA = os.environ.get("JULIA", "julia")
BOOT = (
    "using MRITestData, Preferences; "
    'MRITestData.set_download_path!(:cache); '
    # start from the default (all) columns so the recording is reproducible
    'set_preferences!(MRITestData, "browser_columns" => nothing; force = true); '
    "run_browser(offline = true)"
)


def main() -> int:
    env = dict(os.environ, TERM="xterm-256color", LINES=str(ROWS), COLUMNS=str(COLS))
    child = pexpect.spawn(
        JULIA, ["--project=.", "--color=yes", "-e", BOOT],
        cwd=REPO, env=env, dimensions=(ROWS, COLS), encoding=None, timeout=120,
    )

    chunks: list[tuple[float, bytes]] = []  # (wall time, raw bytes) for the whole session
    t0 = time.time()

    def drain(budget: float) -> None:
        deadline = time.time() + budget
        while time.time() < deadline:
            try:
                chunk = child.read_nonblocking(size=65536, timeout=0.1)
            except pexpect.TIMEOUT:
                continue
            except pexpect.EOF:
                return
            if chunk:
                chunks.append((time.time() - t0, chunk))

    # Capture from spawn (polling — `expect` would consume the first paint, and the TUI
    # renders differentially so there is no later full repaint to re-sync on). Wait up to
    # 5 min for the first header paint; the first run precompiles.
    deadline = time.time() + 300
    while time.time() < deadline:
        drain(0.5)
        if b"MRI Datasets" in b"".join(c for _, c in chunks):
            break
    time.sleep(2.0)
    drain(SCRIPT[0][0])
    q_time = 0.0
    for delay, payload in SCRIPT[1:]:
        if payload is not None:
            child.send(payload)
        if payload == b"q":
            q_time = time.time() - t0
        drain(delay)

    try:
        child.expect(pexpect.EOF, timeout=10)
    except pexpect.TIMEOUT:
        child.terminate(force=True)

    # Sanitize every chunk (carrying a trailing partial escape to the next), then flatten.
    clean: list[tuple[float, bytes]] = []
    pending = b""
    for t, c in chunks:
        buf = pending + c
        m = re.search(rb"\x1b[^a-zA-Z]*$", buf)
        pending = buf[m.start():] if m else b""
        buf = buf[: m.start()] if m else buf
        clean.append((t, _sanitize(buf)))
    if pending:
        clean.append((clean[-1][0] if clean else 0.0, _sanitize(pending)))

    blob = b"".join(c for _, c in clean)

    # Trim the precompile stdout: cut at the ESC[2J of the browser's first full paint.
    cut = blob.rfind(b"\x1b[2J", 0, blob.find(b"MRI Datasets"))
    if cut < 0:
        cut = max(0, blob.find(b"\x1b[2J"))

    # Trim the teardown: the first ESC[2J after `q` was pressed.
    end = len(blob)
    epos = 0
    for t, c in clean:
        if t >= q_time + 0.25 and b"\x1b[2J" in c:
            end = epos + c.index(b"\x1b[2J")
            break
        epos += len(c)

    kept: list[tuple[float, bytes]] = []
    pos = 0
    t_cut = None
    for t, c in clean:
        lo, hi = pos, pos + len(c)
        pos = hi
        if hi <= cut or lo >= end:
            continue
        c = c[max(cut, lo) - lo: min(end, hi) - lo]
        if not c:
            continue
        if t_cut is None:
            t_cut = t
        kept.append((t, c))
    if t_cut is None:
        t_cut = 0.0

    events: list[list] = []
    for t, c in kept:
        events.append([round(max(0.0, t - t_cut), 4), "o", c.decode("utf-8", "replace")])

    header = {"version": 2, "width": COLS, "height": ROWS,
              "env": {"TERM": "xterm-256color", "SHELL": "/bin/bash"}}
    with open(CAST, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(header) + "\n")
        for ev in events:
            fh.write(json.dumps(ev) + "\n")

    print(f"wrote {CAST} ({len(events)} output events, "
          f"{events[-1][0] if events else 0:.1f}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
