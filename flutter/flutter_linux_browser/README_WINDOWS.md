# Daksha — Windows 10 / 11

Daksha is a desktop app for the Daksha robot bringup web UI. It opens the dashboard
(by default `http://s1.local:8100/`) in its own window, opens the dashboard's log pages in tabs,
and lets you connect to another robot by host name or IP address.

On Windows the web pages are shown with Microsoft Edge WebView2.

- **To install the app**, you only need the setup file; go to [section 1](#1-install-the-app).
- **To build the setup file yourself**, go to [section 2](#2-build-the-app-from-source).

## 1. Install the app

### Requirements

- Windows 10 (64-bit, version 1809 or later) or Windows 11.
- **Microsoft Edge WebView2 Runtime.** It is already installed on Windows 11 and on up-to-date
  Windows 10. If the app opens with a blank window, install the "Evergreen Bootstrapper" from
  https://developer.microsoft.com/microsoft-edge/webview2/.

### Using the installer

1. Run `daksha_1.0.0_setup.exe`.
2. If Windows SmartScreen shows "Windows protected your PC", click **More info**, then
   **Run anyway**. The installer is not code-signed, so Windows shows this warning.
3. Follow the steps. You can tick **Create a desktop shortcut**.
4. Start **daksha** from the Start menu or the desktop shortcut.

The app installs to `C:\Program Files\daksha`.

To uninstall: **Settings → Apps → daksha → Uninstall**.

### Using the portable folder (no installer)

1. Unzip the `Release` folder anywhere, for example `C:\daksha`.
2. Double-click `daksha.exe`.

Keep `daksha.exe` together with the `.dll` files and the `data` folder next to it. It won't start
on its own.

## 2. Build the app from source

The Windows app has to be built on Windows. It can't be built on Linux.

### Install the build tools

1. **Git:** https://git-scm.com/download/win
2. **Visual Studio 2022** (Community edition is fine): https://visualstudio.microsoft.com/.
   In the installer, select the **Desktop development with C++** workload.
   This is Visual Studio, not Visual Studio Code.
3. **Flutter:** follow https://docs.flutter.dev/get-started/install/windows/desktop and add
   `flutter\bin` to your `PATH`.
4. **Inno Setup 6** (optional, needed only for the setup .exe): https://jrsoftware.org/isdl.php

Then open a new PowerShell window and check that everything is found:

```powershell
flutter config --enable-windows-desktop
flutter doctor
```

`flutter doctor` must show a green tick for **Visual Studio - develop Windows apps**.

### Get the code

Copy the `flutter\flutter_linux_browser` folder to the Windows machine, for example to
`C:\daksha-src`. Leave out its `build` folder, which holds Linux build files.

### Build

In PowerShell, from the project folder:

```powershell
cd C:\daksha-src
powershell -ExecutionPolicy Bypass -File packaging\build_windows.ps1
```

This creates:

| File | What it is |
| --- | --- |
| `build\windows\x64\runner\Release\daksha.exe` | The app. It needs the rest of the `Release` folder. Zip that whole folder to share a portable copy. |
| `build\windows-installer\daksha_1.0.0_setup.exe` | The installer. It's created only if Inno Setup is installed. |

### Run for development

```powershell
flutter pub get
flutter run -d windows
```

## 3. Settings files

Settings are stored in `%APPDATA%\daksha\` (usually `C:\Users\<you>\AppData\Roaming\daksha\`):

| File | Contents |
| --- | --- |
| `server` | The last server you connected to. The app reconnects to it at the next launch. |
| `app_key` | The launch key for robots behind the Daksha gateway. You can set the `DAKSHA_APP_KEY` environment variable instead. |

To set the launch key from PowerShell:

```powershell
New-Item -ItemType Directory -Force "$env:APPDATA\daksha" | Out-Null
Set-Content "$env:APPDATA\daksha\app_key" "YOUR-KEY-HERE"
```

## 4. Using the app

The controls and keyboard shortcuts are the same as on Linux. See the main
[README](../../README.md#3-use-the-app).

## 5. Troubleshooting

- **"Unable to reach the application" / `s1.local` doesn't connect:** check that the robot's
  server is running and that the PC is on the same network. Windows 10 doesn't always resolve
  `.local` names. If it doesn't, connect using the robot's IP address (for example
  `192.168.1.20`), or install Apple's Bonjour Print Services, which adds `.local` support.
- **Windows Firewall asks for permission at first launch:** allow access on **Private networks**
  so the app can reach the robot.
- **Blank or white window:** install or repair the WebView2 Runtime (see
  [Requirements](#requirements)).
- **The build fails with "Unable to find suitable Visual Studio toolchain":** run the Visual Studio
  Installer and add the **Desktop development with C++** workload, then run `flutter doctor` again.
- **The build fails while downloading `nuget`:** the WebView2 plugin downloads NuGet during the
  first build. Check your internet connection or proxy and build again.
