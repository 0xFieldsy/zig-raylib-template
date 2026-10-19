# AGENTS.md / CLAUDE.md

This is a reusable Zig and raylib template. Zetris, a falling-block game, is the demo.

## Architecture

- Keep application logic independent of raylib and platform I/O in `src/root.zig`. This lets logic tests run without a display or audio device. `src/main.zig` owns the window, input, drawing, and audio synthesis, and calls raylib directly through `@import("raylib")` and raygui through `@import("raygui")`.
- When building a different app, replace the Zetris logic, UI, tests, and documentation to match that app. Preserve the reusable build support unless the task calls for changing it.
- The demo executable names use `zetris-<arch>-<os>-<abi>` in `build.zig`; the module/import and package name remain `zetris`. Keep the module name and its import in `src/main.zig` in sync when renaming them. A package rename in `build.zig.zon` also requires updating its fingerprint to the value suggested by Zig's validation.
- Update `scripts/smoke-ui.py` when replacing the demo or changing its UI. Its binary path, window title, dimensions, palette, board coordinates, key sequences, and assertions are specific to Zetris. `--binary` only changes the executable path; it does not adapt the checks to another app.
- Adapt `scripts/smoke-audio.py` when replacing the demo or changing audio behavior. Its inputs, initialization logs, and signal thresholds are specific to Zetris.
- Keep shared smoke-test display, keyboard and mouse input, logging, and process helpers in `scripts/lib/`. Click coordinates for raygui widgets are window-relative and specific to Zetris. Both scripts import the `lib` package (`scripts/lib/__init__.py`); adapt its binary name, window search, and startup reset when replacing the demo, and run both smoke tests when changing shared helpers.
- Update this file and [README.md](README.md) when commands or architecture change. Keep instructions portable across project folder names.

## Building

- Use Zig 0.16.0 and the raylib-zig dependency pinned in `build.zig.zon`.
- Run `zig fmt` on changed Zig files and `zig build` for source or build changes. Run `zig build test` for application logic changes; it runs the tests in `src/root.zig` without initializing the GUI or audio.
- All targets install to `zig-out/bin` with names `zetris-{aarch64,x86_64}-{linux,macos,windows}-{gnu,msvc,musl,none}` (`.exe` on Windows). macOS uses `none` for the ABI. `msvc` can only be compiled on Windows. Smoke tests default to the native Linux build; pass `--binary` for another path.
- `zig build` defaults to the host OS and architecture. Select cross-build targets with `-Dtarget`.

## Boundaries

- Keep baseline CPU targeting for distributable binaries. Native CPU features can cause illegal-instruction failures when copying binaries between machines.
- raylib is declared lazy. Keep `build.zig` handling the null result `lazyDependency` returns before Zig has fetched the package.
- raygui's C code is compiled into raylib-zig's raylib archive; `build.zig` only adds the `raygui` Zig module, which imports the same raylib module. Keep the two modules from one `raylib_zig` dependency.
- Preserve the Linux system-library forwarding and macOS framework/library-path forwarding in `build.zig` when refactoring the build. They handle Zig 0.16/raylib linking behavior.
- Keep `build.zig.zon`'s `.paths` list in sync when adding files needed by the packaged project.
- Don't cross-compile compile binaries unless explicitly asked to.
