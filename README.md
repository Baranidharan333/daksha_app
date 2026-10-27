# Daksha

Daksha is a Linux desktop app for the Daksha robot bringup web UI. It opens the dashboard
(by default `http://s1.local:8100/`) in its own window, opens the dashboard's log pages in tabs,
and lets you connect to another robot by host name or IP address.

The source code is in [`flutter/flutter_linux_browser/`](flutter/flutter_linux_browser/). It is built with Flutter
and WPE WebKit.

## 1. Install the requirements (Debian / Kali / Ubuntu)

```bash
sudo apt update
sudo apt install -y libgtk-3-dev libepoxy-dev pkg-config cmake ninja-build \
  build-essential libwpewebkit-2.0-dev libwpe-1.0-dev libsecret-1-dev fakeroot
```

Install Flutter (see https://docs.flutter.dev/get-started/install/linux), then enable Linux desktop
support:

```bash
flutter config --enable-linux-desktop
flutter doctor
```

## 2. Run the app

### For development

```bash
cd flutter/flutter_linux_browser
flutter pub get
flutter run -d linux
```

### As a release build

```bash
cd flutter/flutter_linux_browser
flutter build linux --release
./build/linux/x64/release/bundle/daksha
```

### Install it as a system app (.deb)

```bash
cd flutter/flutter_linux_browser
./packaging/build_deb.sh
sudo apt install ./build/deb/daksha_1.0.0_amd64.deb
```

Then start **daksha** from the app menu, or run `daksha` in a terminal.

To uninstall:

```bash
sudo apt remove daksha
```

## 3. Use the app

| Control | What it does |
| --- | --- |
| **Home** (house icon) | Goes back to the dashboard |
| **Navigation** | Opens the robot base's navigation page (`http://base.local:8000/`) |
| **Server button** (shows e.g. `s1.local`) | Opens **Connect to server** |
| **Back / Forward / Reload** | Navigate the current tab |
| **Keyboard icon** or **F1** | Shows the keyboard shortcuts |

**Connecting to a robot:** click the server button, type the address, and press **Connect** or Enter.
These forms are accepted:

- `s1`: a robot name. `.local` is added for you, so this connects to `s1.local` on port 8100.
- `s1.local`: the same, written in full.
- `192.168.1.20`: an IP address. Port 8100 is used.
- `192.168.1.20:9000`: an address with a different port.

The app remembers the last server in `~/.config/daksha/server` and connects to it at the next
launch.

The **Navigation** button opens `http://base.local:8000/` by default. To use another address,
put the full URL in `~/.config/daksha/navigation` (for example `http://groot.local:8000/`) or
set `DAKSHA_NAVIGATION_URL`.

If the server can't be reached, the app shows an error page with **Retry** and
**Connect to another server** buttons.

### Keyboard shortcuts

| Keys | Action |
| --- | --- |
| Ctrl+R / F5 | Reload (Ctrl+Shift+R bypasses the cache) |
| Esc | Stop loading |
| Alt+← / Alt+→ | Back / Forward |
| Alt+Home | Go to the dashboard |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |
| Ctrl+1…8 / Ctrl+9 | Go to tab N / last tab |
| Ctrl+W | Close the tab |
| Ctrl++ / Ctrl+- / Ctrl+0 | Zoom in / out / reset |
| F11 | Toggle fullscreen |

## 4. Troubleshooting

- **"Unable to reach the application":** check that the robot's server is running and that this
  computer is on the same network. If `s1.local` doesn't resolve, connect using the robot's IP
  address.
- **The page is black:** the app already uses software rendering to avoid this. To try GPU
  rendering instead, run `LIBGL_ALWAYS_SOFTWARE=0 daksha`.
- **The build fails with "Permission denied" installing to `/usr/local`:** delete
  `flutter/flutter_linux_browser/build/linux` and build again.
- **Mouse or drag problems:** run with `WEBUI_DEBUG_INPUT=1` to log pointer events to the terminal.

## App-only access (gateway)

A robot's web UI can be set so it opens only from this app. You can build the
[Daksha gate](webpage/README.md) into a Python web UI, or run the
[Daksha gateway](gateway/README.md) in front of any web UI. A normal browser gets an empty page, and API calls without a
session get `401`. The app reads its launch key from `~/.config/daksha/app_key` (or
`DAKSHA_APP_KEY`), gets a one-time ticket from the robot, and signs in again by itself when
the session runs out. It also only opens pages on the connected robot, the navigation
base and the leader arms (`leader*.local`). Robots without a gateway still work as before.

## Security note

The app turns off WebKit's sandbox, because the sandbox crashes at startup on Kali. Use it only
with trusted servers such as your own robots, not for general web browsing.
# daksha_app
