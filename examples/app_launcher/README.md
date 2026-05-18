# App Launcher Example

Terminal smoke test for Ramiel's desktop app-runner helpers.

It scans XDG `.desktop` files, uses the built-in fuzzy matcher, and prints sanitized `Exec` commands without launching them.

```sh
zig build run-app-launcher -- firefox
zig build run-app-launcher -- --dir /usr/share/applications terminal
zig build run-app-launcher -- --limit 5 browser
```

This example is intentionally CLI-only so the desktop entry parser, app index, and fuzzy matcher can be tested before wiring the resident graphical launcher UI.
