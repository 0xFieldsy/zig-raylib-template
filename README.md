# Zig Raylib Template

A template for desktop games and graphical applications using Zig [0.16.0](https://codeberg.org/ziglang/zig/src/tag/0.16.0) and [raylib-zig](https://github.com/raylib-zig/raylib-zig) with [raygui](https://github.com/raysan5/raygui).

Zetris, a falling-block game, is the demo application.

## Usage

```sh
gh repo clone 0xFieldsy/zig-gui-template your-app
cd your-app
zig build
```

On Ubuntu, install the [build dependencies](#ubuntu) prior to building. The build downloads raylib as pinned in [build.zig.zon](build.zig.zon); you don't need a separate raylib installation.

`zig build` installs the demo executable to `zig-out/bin/zetris-<arch>-<os>-<abi>`. For example, the default build on x86_64 Linux produces `zig-out/bin/zetris-x86_64-linux-gnu`. Architecture, OS, and ABI names follow Zig's target names. macOS has no ABI, so its binaries use `none`.

`zig build run` opens the game window and needs a working desktop display and graphics drivers. Builds and logic tests can run on a headless machine using the [UI smoke test](#ui-smoke-test) and [audio smoke test](#audio-smoke-test).

The build defaults to the baseline CPU for the target architecture. This avoids requiring the destination machine to support the build machine's AVX instructions. Keep that default for binaries you distribute; the `-Dcpu=native` target is for binaries that will only run on the build machine.

### Windows

Build for x86_64 Windows:

```bash
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
```

The output is `zig-out/bin/zetris-x86_64-windows-gnu.exe`. This target uses baseline x86_64 with the GNU ABI. Zig supplies the toolchain, so a separate MinGW installation isn't required.

### macOS

Build for ARM64 Macs with macOS 13 (Ventura) or later:

```bash
zig build -Dtarget=aarch64-macos-none -Doptimize=ReleaseSafe
```

The output is `zig-out/bin/zetris-aarch64-macos-none`. The target uses baseline ARM64 and runs without Rosetta. The pinned raylib dependency downloads macOS framework headers and link stubs on the first build, allowing cross-compilation from Linux without a local Xcode installation.

App bundles, signing, and notarization require additional packaging work. macOS may require approval for an unsigned executable.

### Ubuntu

On 24.04 Noble:

```bash
sudo apt-get update
sudo apt-get install -y \
libgl1-mesa-dev \
libx11-dev \
libxrandr-dev \
libxinerama-dev \
libxcursor-dev \
libxi-dev
```

These packages provide OpenGL and the development libraries for raylib's X11 window backend. If linking fails with `unable to find dynamic system library 'GL'`, check that `libgl1-mesa-dev` is installed.

## Testing

Format changed Zig files and run the logic tests:

```bash
zig fmt build.zig build.zig.zon src
zig build test
```

### UI Smoke Test

On Linux, the smoke script launches the demo on a private Xvfb display with Mesa software rendering. It checks rendering, pause/resume by key and by the RESUME button, movement, rotation, hard drop and scoring, restart by key and by the RESTART button, and clean shutdown with Escape:

```bash
sudo apt-get install -y xvfb xdotool imagemagick libgl1-mesa-dri
zig build
python3 scripts/smoke-ui.py
```

The default executable path selects the native Linux build in `zig-out/bin`.

The script prints a JSON result on success and removes temporary files. On failure it returns a nonzero exit code and prints the directory containing logs and PPM screenshots.

Use `--binary PATH` to check a different Linux build of the demo or `--timeout SECONDS` to change the timeout per operation (default: 10 seconds).

### Audio Smoke Test

On Linux, the audio script starts a private PulseAudio server with a null sink and records its monitor while driving the demo on a private Xvfb display. It works in a headless VM without a sound card and doesn't change your desktop audio:

```bash
sudo apt-get install -y xvfb xdotool libgl1-mesa-dri pulseaudio pulseaudio-utils
zig build
python3 scripts/smoke-audio.py
```

The default executable path selects the native Linux build in `zig-out/bin`.

The test checks that all four synthesized effects load, idle output is silent, rotation and piece locking produce audio samples, inputs stay silent after clearing the SOUND checkbox, sound resumes after checking it again, a 0% volume bar setting is silent, and Escape exits cleanly. Playback assertions measure recorded PCM, so initialization logs alone can't produce a pass.

Success prints JSON with checks and sample measurements and removes temporary files. Failure returns a nonzero exit code and retains server/application logs, WAV captures, and `measurements.json`. Use `--binary PATH` for another Linux build of Zetris, or `--timeout SECONDS` for the timeout per operation (default: 10 seconds).

## Zetris Demo

Zetris uses a 10-column, 20-row playfield, seven-piece bags, SRS wall kicks, a landing ghost, five next-piece previews, and hold. Clearing lines raises the level and increases gravity. Scoring includes T-spins, combos, back-to-back clears, perfect clears, and drop points. The best score lasts for the current session.

| Key | Action |
| --- | --- |
| Left / Right | Move horizontally |
| Down | Soft drop |
| X | Rotate clockwise |
| Z | Rotate counterclockwise |
| Space | Hard drop |
| Shift | Hold once per piece |
| P | Pause / resume |
| R | Restart |
| Escape | Quit |

Losing window focus pauses the game. Press <kbd>P</kbd> or click RESUME after returning to resume. The pause and game-over overlays also have a RESTART button. Below the board, the SOUND checkbox toggles sound and the bar sets the master volume. Audio is optional, so the game continues without an audio device and shows SOUND UNAVAILABLE in place of these controls.
