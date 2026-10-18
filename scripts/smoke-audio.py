#!/usr/bin/env python3
"""Smoke-test Zetris audio on Linux without a sound card.

Uses a private PulseAudio null sink, Xvfb, and xdotool. Python needs only its
standard library. Logs and WAV captures are retained on failure.
"""

import argparse
import array
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time
import wave

from lib import Session as SmokeSession, default_binary, require, stop


RATE = 22050


class Session(SmokeSession):
    def __init__(self, binary, directory, timeout):
        super().__init__(binary, directory, timeout)
        self.pulse = self.recorder = None
        self.measurements = {}

    def start(self):
        runtime = self.directory / "pulse"
        runtime.mkdir(mode=0o700)
        socket = runtime / "native"
        self.env.update(
            PULSE_SERVER=f"unix:{socket}",
            PULSE_SINK="zetris_smoke",
            PULSE_SOURCE="zetris_smoke.monitor",
            PULSE_RUNTIME_PATH=str(runtime),
        )
        config = self.directory / "pulse.pa"
        config.write_text(
            "load-module module-native-protocol-unix "
            f"socket={socket} auth-anonymous=1\n"
            "load-module module-null-sink sink_name=zetris_smoke "
            f"rate={RATE} channels=1 format=s16le\n"
            "set-default-sink zetris_smoke\n"
            "set-default-source zetris_smoke.monitor\n"
        )
        log = self.open_log("pulse.log")
        self.pulse = subprocess.Popen(
            [
                "pulseaudio",
                "--daemonize=no",
                "--use-pid-file=no",
                "--exit-idle-time=-1",
                "--disable-shm=yes",
                "--disallow-exit=yes",
                "-n",
                "--file",
                str(config),
            ],
            env=self.env,
            stdout=log,
            stderr=log,
        )
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            require(self.pulse.poll() is None, "private PulseAudio server exited")
            if socket.exists():
                result = self.command("pactl", "info", check=False)
                if result.returncode == 0:
                    break
            time.sleep(0.05)
        else:
            raise RuntimeError("private PulseAudio server did not become ready")

        self.recorder = subprocess.Popen(
            [
                "parec",
                "--device=zetris_smoke.monitor",
                "--raw",
                "--format=s16le",
                f"--rate={RATE}",
                "--channels=1",
                "--latency-msec=20",
            ],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=self.open_log("parec.log"),
        )
        super().start()
        self.wait_log("AUDIO: Loaded 4/4 effects")
        # A newly started null sink can initially buffer about two seconds,
        # even with a small requested capture latency. Wait for real PCM before
        # starting the timed checks rather than assuming the recorder is ready.
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if self.read_audio(min(0.1, deadline - time.monotonic())):
                break
        else:
            raise RuntimeError("audio recorder did not deliver samples")

    def alive(self):
        super().alive()
        if self.pulse is None:
            raise RuntimeError("private PulseAudio server has not been started")
        if self.recorder is None:
            raise RuntimeError("audio recorder has not been started")
        require(self.pulse.poll() is None, "private PulseAudio server exited")
        require(self.recorder.poll() is None, "audio recorder exited")

    def wait_log(self, text):
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            self.alive()
            if text in (self.directory / "zetris.log").read_text(errors="replace"):
                return
            time.sleep(0.05)
        raise RuntimeError(f"timed out waiting for {text!r}")

    def read_audio(self, duration):
        if self.recorder is None or self.recorder.stdout is None:
            raise RuntimeError("audio recorder is not ready")
        stream = self.recorder.stdout
        deadline = time.monotonic() + duration
        chunks = []
        while time.monotonic() < deadline:
            self.alive()
            remaining = max(0, deadline - time.monotonic())
            if select.select([stream], [], [], remaining)[0]:
                chunk = os.read(stream.fileno(), 65536)
                require(chunk, "audio recorder closed its output")
                chunks.append(chunk)
        return b"".join(chunks)

    def capture_audio(self, name, action=None, audible=False):
        # Drain previous effects and buffered recording before triggering input.
        self.read_audio(0.5)
        if self.recorder is None or self.recorder.stdout is None:
            raise RuntimeError("audio recorder is not ready")
        stream = self.recorder.stdout
        while select.select([stream], [], [], 0)[0]:
            require(
                os.read(stream.fileno(), 65536),
                "audio recorder closed its output",
            )
        if action is not None:
            action()
        pcm = self.read_audio(0.8)
        require(len(pcm) % 2 == 0, "incomplete 16-bit audio sample")
        with wave.open(str(self.directory / f"{name}.wav"), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(RATE)
            output.writeframes(pcm)
        # A dead recorder must not be mistaken for a successful silence check.
        require(len(pcm) >= RATE, f"{name}: less than half a second of audio captured")
        samples = array.array("h")
        samples.frombytes(pcm)
        if sys.byteorder != "little":
            samples.byteswap()
        peak = max(abs(sample) for sample in samples)
        active = sum(abs(sample) > 128 for sample in samples)
        self.measurements[name] = {
            "samples": len(samples),
            "peak": peak,
            "active_samples": active,
        }
        (self.directory / "measurements.json").write_text(
            json.dumps(self.measurements, indent=2) + "\n"
        )
        if audible:
            require(
                peak >= 1000 and active >= 1000,
                f"{name}: expected an effect, got peak={peak}, active_samples={active}",
            )
        else:
            require(peak <= 32, f"{name}: expected silence, got peak={peak}")

    def close(self):
        # Stop clients before their servers, including partially started runs.
        stop(self.app)
        stop(self.recorder)
        if self.recorder is not None and self.recorder.stdout is not None:
            self.recorder.stdout.close()
        stop(self.pulse)
        super().close()


def run(session):
    session.start()
    session.key("p")  # Prevent gravity from locking a piece during the idle check.
    session.capture_audio("idle")
    session.key("r")
    session.capture_audio("rotation", lambda: session.key("x"), audible=True)
    session.key("r")
    session.capture_audio("lock", lambda: session.key("space"), audible=True)
    session.key("r")

    # The raygui SOUND checkbox and volume bar sit below the board.
    def muted_input():
        session.click(329, 800)
        session.wait_log("AUDIO: muted")
        session.key("x")
        session.key("space")

    session.capture_audio("muted-input", muted_input)
    session.capture_audio("re-enabled", lambda: session.click(329, 800), audible=True)
    session.wait_log("AUDIO: enabled")
    session.key("r")
    session.capture_audio(
        "rotation-after-enable", lambda: session.key("x"), audible=True
    )
    session.click(442, 800)  # The bar's left edge sets 0%.
    session.key("r")
    session.capture_audio("zero-volume", lambda: session.key("x"))
    session.click(577, 800)  # Near the right edge restores about 99%.
    session.key("r")
    session.capture_audio("volume-restored", lambda: session.key("x"), audible=True)
    session.key("Escape")
    code = session.app.wait(timeout=session.timeout)
    require(code == 0, f"Escape produced exit code {code}")
    return [
        "four effects loaded",
        "idle silence",
        "rotation playback",
        "piece-lock playback",
        "checkbox mute silences input",
        "checkbox re-enables sound",
        "playback after re-enable",
        "volume bar silence and restore",
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
    missing = [
        name
        for name in ("Xvfb", "xdotool", "pulseaudio", "pactl", "parec")
        if not shutil.which(name)
    ]
    if missing:
        parser.error(
            f"missing tools: {', '.join(missing)}; "
            "install xvfb, xdotool, pulseaudio, pulseaudio-utils"
        )
    directory = Path(tempfile.mkdtemp(prefix="zetris-audio-"))
    session = Session(binary, directory, args.timeout)
    try:
        checks = run(session)
    except (
        OSError,
        RuntimeError,
        subprocess.SubprocessError,
        KeyboardInterrupt,
    ) as error:
        print(f"FAIL: {error}\nLogs and WAV captures: {directory}", file=sys.stderr)
        return 1
    finally:
        session.close()
    shutil.rmtree(directory)
    print(
        json.dumps(
            {"status": "pass", "checks": checks, "measurements": session.measurements}
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
