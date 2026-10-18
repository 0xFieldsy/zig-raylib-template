"""Display, input, logging, and process lifecycle for Zetris smoke tests."""

import os
from pathlib import Path
import platform
import select
import subprocess
import time


def default_binary():
    """Locate the native Linux build using Zig's architecture names."""
    machine = platform.machine().lower()
    arch = {
        "amd64": "x86_64",
        "arm64": "aarch64",
        "i386": "x86",
        "i686": "x86",
        "armv6l": "arm",
        "armv7l": "arm",
    }.get(machine, machine)
    return (
        Path(__file__).resolve().parents[2] / "zig-out" / "bin" / f"zetris-linux-{arch}"
    )


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


class Session:
    def __init__(self, binary, directory, timeout):
        self.directory = directory
        self.timeout = timeout
        self.env = os.environ.copy()
        self.env["LIBGL_ALWAYS_SOFTWARE"] = "1"
        self.env.pop("XAUTHORITY", None)
        self.server = self.app = None
        self.window = None
        self.logs = []
        self.binary = binary

    def start(self):
        read_fd, write_fd = os.pipe()
        try:
            log = self.open_log("xvfb.log")
            self.server = subprocess.Popen(
                [
                    "Xvfb",
                    "-displayfd",
                    str(write_fd),
                    "-screen",
                    "0",
                    "1024x900x24",
                    "-nolisten",
                    "tcp",
                    "-ac",
                ],
                pass_fds=(write_fd,),
                stdout=log,
                stderr=log,
            )
            os.close(write_fd)
            write_fd = None
            deadline = time.monotonic() + self.timeout
            display_bytes = bytearray()
            while not display_bytes.endswith(b"\n"):
                remaining = deadline - time.monotonic()
                require(
                    remaining > 0 and select.select([read_fd], [], [], remaining)[0],
                    "Xvfb did not become ready",
                )
                chunk = os.read(read_fd, 64)
                require(chunk, "Xvfb closed its readiness pipe")
                display_bytes.extend(chunk)
            display = display_bytes.decode().strip()
            require(display.isdecimal(), "Xvfb failed to allocate a display")
            self.env["DISPLAY"] = f":{display}"
        finally:
            os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)
        log = self.open_log("zetris.log")
        self.app = subprocess.Popen(
            [str(self.binary)], env=self.env, stdout=log, stderr=log
        )
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            self.alive()
            found = self.command(
                "xdotool", "search", "--onlyvisible", "--name", "^Zetris$", check=False
            )
            if found.returncode == 0 and found.stdout.strip():
                self.window = found.stdout.splitlines()[0].decode()
                break
            time.sleep(0.05)
        require(self.window is not None, "visible Zetris window was not found")
        self.command("xdotool", "windowfocus", "--sync", self.window)
        self.key("r")  # Reset any automatic pause before focus was acquired.

    def open_log(self, name):
        log = (self.directory / name).open("wb")
        self.logs.append(log)
        return log

    def command(self, *args, check=True):
        return subprocess.run(
            args,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
            timeout=self.timeout,
        )

    def alive(self):
        if self.app is None:
            raise RuntimeError("Zetris has not been started")
        if self.server is None:
            raise RuntimeError("Xvfb has not been started")
        require(
            self.app.poll() is None,
            f"Zetris exited unexpectedly ({self.app.returncode})",
        )
        require(self.server.poll() is None, "Xvfb exited unexpectedly")

    def key(self, key):
        self.alive()
        # XTEST events to the focused window, with a hold long enough for 60 FPS.
        self.command("xdotool", "keydown", key)
        try:
            time.sleep(0.06)
        finally:
            self.command("xdotool", "keyup", key)

    def click(self, x, y):
        self.alive()
        # Move first and hold the button across frames; raygui acts on release.
        self.command("xdotool", "mousemove", "--window", self.window, str(x), str(y))
        time.sleep(0.06)
        self.command("xdotool", "mousedown", "1")
        try:
            time.sleep(0.06)
        finally:
            self.command("xdotool", "mouseup", "1")

    def close(self):
        stop(self.app)
        stop(self.server)
        for log in self.logs:
            log.close()
