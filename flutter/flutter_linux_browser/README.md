# Daksha — Flutter for Linux

A desktop window for the Daksha bringup web UI, built with Flutter and `flutter_inappwebview` 6.2.0-beta (WPE WebKit on Linux).

## Features

- Multiple tabs
- Back, forward, reload, and home controls
- URL navigation and Google search for plain text
- Loading progress and page titles
- Dark Material 3 interface
- Quick links to Google, YouTube, Wikipedia, and GitHub

## Linux prerequisites (Debian/Kali/Ubuntu)

```bash
sudo apt update
sudo apt install -y libgtk-3-dev libepoxy-dev pkg-config cmake ninja-build \
  build-essential libwpewebkit-2.0-dev libwpe-1.0-dev libsecret-1-dev
```

> Stable `flutter_inappwebview` 6.1.x has no Linux support; this project uses
> `6.2.0-beta.3`, whose Linux backend renders through WPE WebKit.

Install Flutter if needed, then enable Linux desktop:

```bash
flutter doctor
flutter config --enable-linux-desktop
```

## Run

From the project folder:

```bash
flutter pub get
flutter run -d linux
```

## Build a release

```bash
flutter build linux --release
```

The executable is usually created under:

`build/linux/x64/release/bundle/`

## Debian package

```bash
./packaging/build_deb.sh                    # builds build/deb/*.deb
sudo apt install ./build/deb/daksha_1.0.0_amd64.deb  # install
daksha                                      # run (or use the app menu)
sudo apt remove daksha                      # uninstall
```

The app installs to `/opt/daksha`, with a launcher in `/usr/bin` and a menu entry.
It uses the system WPE WebKit (declared as a dependency) instead of a bundled copy.

## Keyboard shortcuts

| Keys | Action |
| --- | --- |
| Ctrl+R / F5 | Reload (Ctrl+Shift+R bypasses cache) |
| Esc | Stop loading |
| Alt+← / Alt+→ | Back / Forward |
| Alt+Home | Go to dashboard |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |
| Ctrl+1…8 / Ctrl+9 | Go to tab N / last tab |
| Ctrl+W | Close tab |
| Ctrl++ / Ctrl+- / Ctrl+0 | Zoom in / out / reset |
| F11 | Toggle fullscreen |
| F1 | Show shortcuts |

## Notes

- `third_party/flutter_inappwebview_linux` is a local copy of the plugin, patched to compile
  against WPE WebKit 2.54 (`WPE_SETTING_DISABLE_ANIMATIONS` was renamed to `WPE_SETTING_REDUCED_MOTION`).
- `linux/runner/main.cc` sets `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`, because WebKit's sandbox
  aborts at startup on Kali (xdg-dbus-proxy is killed by seccomp). Web pages therefore run unsandboxed.
- On multi-GPU laptops `main.cc` pins WebKit to the GPU driving the display (`WPE_DRM_DEVICE`);
  otherwise the page can render black.
- WebKit renders in software (`FLUTTER_INAPPWEBVIEW_LINUX_DISABLE_GL=1` in `main.cc`, and
  `LIBGL_ALWAYS_SOFTWARE=1` in `my_application.cc`) because the GPU frame path shows a black page.
  `LIBGL_ALWAYS_SOFTWARE` is set only after the Flutter view is realized, so it reaches the web
  processes but not Flutter itself: set before startup, it put the whole window on Mesa's software
  renderer, which flickered constantly on Wayland. Setting it yourself before launch brings that back.
- WPE's offscreen mode has no native HTML5 drag-and-drop; `lib/main.dart` injects a script that
  rebuilds `dragstart`/`dragover`/`drop` from pointer events. The plugin's `zoomBy` is also patched.
- The plugin's mouse handling is patched (`custom_platform_view.dart`, `in_app_webview.cc`) so a
  release during the focus hand-off or a cancelled press can't leave the button "held"
  (which made plain mouse movement drag/pan the page).
- WPE WebKit 2.54 reads a button-release's modifiers as "buttons still held", so the patched
  plugin clears the button bit before sending the release (otherwise hovering kept panning).
- Mouse-wheel notches are sent to WebKit as discrete steps, not precise (touchpad) deltas. With
  precise deltas WebKit scrolled before the page could cancel the wheel, so scrolling over the
  navigation map also scrolled the panel around it.
- `WEBUI_DEBUG_INPUT=1` logs native (`[input]`) and in-page (`[page]`) pointer events.
- If a build fails with "Permission denied" installing to `/usr/local`, delete `build/linux` and rebuild.
- The embedded web renderer depends on WPE WebKit and the Linux support provided by `flutter_inappwebview`.
- Some websites may block embedded browsers or behave differently than in Chrome/Firefox.
- This is a starter browser, not a hardened privacy/security browser. It does not yet include bookmarks, download management, password storage, private browsing, or profile isolation.
