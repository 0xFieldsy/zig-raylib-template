#!/usr/bin/env python3
"""Smoke-test Zetris on Linux using Xvfb, xdotool, and ImageMagick import.

Uses Mesa software OpenGL. Python needs only its standard library. Screenshots
are PPM files; logs and screenshots are retained in a temporary directory on
failure.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from lib import Session as SmokeSession, default_binary, require


WIDTH, HEIGHT = 944, 850
PALETTE = {
    (58, 207, 227),
    (247, 205, 75),
    (174, 114, 238),
    (99, 211, 134),
    (240, 105, 119),
    (88, 137, 240),
    (246, 166, 78),
}


def pixel(frame, x, y):
    offset = (y * WIDTH + x) * 3
    return tuple(frame[offset : offset + 3])


def cells(frame, start=0, end=20):
    return {
        (x, y)
        for y in range(start, end)
        for x in range(10)
        if pixel(frame, 322 + x * 30 + 15, 132 + y * 30 + 15) in PALETTE
    }


def shape(positions):
    if not positions:
        return set()
    left = min(x for x, _ in positions)
    top = min(y for _, y in positions)
    return {(x - left, y - top) for x, y in positions}


def region(frame, x, y, width, height):
    return b"".join(
        frame[((y + row) * WIDTH + x) * 3 : ((y + row) * WIDTH + x + width) * 3]
        for row in range(height)
    )


class Session(SmokeSession):
    def capture(self, name):
        self.alive()
        frame = self.command(
            "import", "-window", self.window, "-depth", "8", "rgb:-"
        ).stdout
        require(
            len(frame) == WIDTH * HEIGHT * 3,
            "unexpected window dimensions or screenshot format",
        )
        (self.directory / f"{name}.ppm").write_bytes(
            f"P6\n{WIDTH} {HEIGHT}\n255\n".encode() + frame
        )
        return frame

    def wait_frame(self, name, predicate):
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            frame = self.capture(name)
            if predicate(frame):
                return frame
            time.sleep(0.05)
        raise RuntimeError(f"timed out checking {name}")


def run(session):
    session.start()
    initial = session.wait_frame("startup", lambda f: len(cells(f, 0, 16)) >= 2)
    require(pixel(initial, 10, 10) == (13, 17, 27), "background was not rendered")
    initial_score = region(initial, 112, 337, 150, 32)
    session.key("Down")
    session.wait_frame("visible-piece", lambda f: len(cells(f, 0, 16)) == 4)

    session.key("p")
    paused = session.wait_frame("paused", lambda f: not cells(f))
    session.key("Left")
    session.key("space")
    time.sleep(0.2)
    frozen = session.capture("paused-input")
    require(
        region(paused, 322, 132, 300, 600) == region(frozen, 322, 132, 300, 600),
        "board changed while paused",
    )
    session.key("p")
    session.wait_frame("resumed", lambda f: len(cells(f, 0, 16)) == 4)
    session.key("p")
    session.wait_frame("paused-again", lambda f: not cells(f))
    session.click(472, 467)  # raygui RESUME button on the pause overlay.
    resumed = session.wait_frame("resume-button", lambda f: len(cells(f, 0, 16)) == 4)

    before = cells(resumed, 0, 16)
    session.key("Left")
    session.wait_frame(
        "movement",
        lambda f: {x for x, _ in cells(f, 0, 16)} == {x - 1 for x, _ in before},
    )

    # O does not visibly rotate. Holding it selects a different bag member.
    current = session.capture("before-rotation")
    if shape(cells(current, 0, 16)) == {(0, 0), (1, 0), (0, 1), (1, 1)}:
        session.key("Shift_L")
        session.key("Down")
        current = session.wait_frame("held", lambda f: len(cells(f, 0, 16)) == 4)
    before_shape = shape(cells(current, 0, 16))
    session.key("x")
    session.wait_frame(
        "rotation",
        lambda f: len(cells(f, 0, 16)) == 4 and shape(cells(f, 0, 16)) != before_shape,
    )

    session.key("space")
    dropped = session.wait_frame("hard-drop", lambda f: len(cells(f, 16, 20)) == 4)
    require(
        region(dropped, 112, 337, 150, 32) != initial_score,
        "hard drop did not update the score display",
    )
    session.key("r")

    def restarted(f):
        return not cells(f, 16, 20) and region(f, 112, 337, 150, 32) == initial_score

    session.wait_frame("restart", restarted)
    session.key("space")
    session.wait_frame("second-drop", lambda f: len(cells(f, 16, 20)) == 4)
    session.key("p")
    session.wait_frame("paused-for-restart", lambda f: not cells(f))
    session.click(472, 513)  # raygui RESTART button on the pause overlay.
    session.wait_frame(
        "restart-button", lambda f: restarted(f) and len(cells(f, 0, 16)) == 4
    )

    session.key("Escape")
    code = session.app.wait(timeout=session.timeout)
    require(code == 0, f"Escape produced exit code {code}")
    return [
        "startup and rendering",
        "pause and resume",
        "resume button",
        "movement",
        "rotation",
        "hard drop and score",
        "restart",
        "restart button",
        "clean Escape shutdown",
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--binary",
        type=Path,
        default=default_binary(),
        help="executable path (default: native build in zig-out/bin)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=10,
        help="timeout per operation in seconds (default: 10)",
    )
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        parser.error("this smoke test requires Linux")
    if not 0 < args.timeout <= 60:
        parser.error("--timeout must be greater than 0 and at most 60")
    binary = args.binary.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error(f"executable not found: {binary}; build first with zig build")
    missing = [name for name in ("Xvfb", "xdotool", "import") if not shutil.which(name)]
    if missing:
        parser.error(
            f"missing tools: {', '.join(missing)}; install xvfb, xdotool, imagemagick"
        )
    directory = Path(tempfile.mkdtemp(prefix="zetris-gui-"))
    session = Session(binary, directory, args.timeout)
    try:
        checks = run(session)
    except (
        OSError,
        RuntimeError,
        subprocess.SubprocessError,
        KeyboardInterrupt,
    ) as error:
        print(f"FAIL: {error}\nLogs and screenshots: {directory}", file=sys.stderr)
        return 1
    finally:
        session.close()
    shutil.rmtree(directory)
    print(json.dumps({"status": "pass", "checks": checks}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
