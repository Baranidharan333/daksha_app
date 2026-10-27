# Robot patches

Fixes for web apps that run on the robot (`s1`), not in this repo. Apply them in the app's
source folder on the robot, then restart the app.

## Camera Setup (`s1.local:8120`)

The four page patches change the app's `static/js/app.js`. Apply them in this order:

```bash
cd <camera setup app folder>          # the folder that holds static/js/app.js
cp static/js/app.js static/js/app.js.bak
patch -p1 < camera_setup_streams.patch
patch -p1 < camera_setup_drop.patch
patch -p1 < camera_setup_saved.patch
patch -p1 < camera_setup_rescan.patch   # needs camera_ui_ros_preview.patch on the server
```

Then restart Camera Setup from the dashboard's Applications list and reload the page.

**Status on `s1`:** all four page patches are installed (2026-10-22) in both
`src/camera/camera_launch/camera_launch/static/js/app.js` and its `install/` copy, with
`app.js.bak` backups of the originals.

### camera_setup_streams.patch: slow Rescan and Save

**Problem:** the page opened one live MJPEG stream for each camera tile and another for each
role thumbnail. That's 6 streams, and they never end, even for busy or offline cameras.
Browsers (including the Daksha app's WebKit) keep at most 6 connections per server, so those
6 streams used them all. Every Rescan, assign and Save request then waited in a queue.

**Fix:**
- Only live cameras stream, once each. Busy or offline tiles show their status as text.
- Role thumbnails copy frames from the camera's tile instead of opening a second stream.

| | Scan with busy cameras | Streams open (busy / all live) |
| --- | --- | --- |
| Before | timed out (over 8 s) | 6 / 5 |
| After | under 3 ms | 0 / 3 |

These numbers come from WebKit against a mock of the app with never-ending streams. The
robot's real scan answers in about 0.15 s once it isn't queued.

### camera_setup_drop.patch: drop anywhere on a role row

**Problem:** only the small thumbnail box of a role row accepted a dropped camera, not the
label or serial text next to it.

**Fix:** the whole row accepts the drop and highlights its box.

The Daksha app already makes drops on the row work without this patch. The patch makes
the same thing work in an ordinary browser.

### camera_setup_saved.patch: labels that don't match cameras.yaml

**Problem:** the role slots show the app's unsaved draft (`assignments` in `/api/scan`). They
never show what `cameras.yaml` holds (`saved`), even though `/api/scan` returns both. After
the app restarts, the draft can differ from the file. The slots then show old or swapped
serials although an earlier Save wrote the right ones.

**Fix:** a role whose draft differs from `cameras.yaml` shows, in orange, "cameras.yaml has
`<serial>`: press Save to write this change". After Save the page scans again, so the note
disappears once the file matches.

The server-side cause is fixed by `camera_ui_ros_preview.patch` below: the draft was seeded
from built-in default serials, not from `cameras.yaml`.

### camera_ui_ros_preview.patch: live view while the bringup runs (server)

Changes `camera_launch/camera_ui.py`. Apply it in the package folder
(`src/camera/camera_launch`), and copy the result over the installed
`install/camera_launch/lib/python3.10/site-packages/camera_launch/camera_ui.py`:

```bash
cd ~/uni/daksha/src/camera/camera_launch
patch -p1 < camera_ui_ros_preview.patch
cp camera_launch/camera_ui.py ~/uni/daksha/install/camera_launch/lib/python3.10/site-packages/camera_launch/
```

**Problem 1:** a RealSense camera can be opened by only one program. While the bringup runs,
it holds all three, so Camera Setup could only show "device busy".

**Fix 1:** for a busy camera, the server shows the bringup's own picture of it, from
`/<namespace>/<name>/color/image_raw/compressed` (the JPEG topic `start_all_cameras.launch.py`
publishes). It matches topics to cameras by asking each running RealSense node for its
`serial_no` parameter, so the picture is right even if `cameras.yaml` changed after the
bringup started. Those cameras report `live` with `source: "ros"` in `/api/scan`. Free
cameras still stream directly.

**Problem 2:** at startup the slots were filled from `DEFAULT_SERIALS` in the code (World
`313522301897`, Right `260322274109`), not from `cameras.yaml`. After every restart the page
showed those stale serials, even after a Save.

**Fix 2:** the slots start from `cameras.yaml`. A `<role>_serial` parameter set at launch
still takes priority.

**Problem 3:** a camera that was busy stayed "busy" after the bringup stopped, until Camera
Setup was restarted. It was never tried again.

**Fix 3:** **Rescan hardware** (`/api/scan?rescan=1`, added by `camera_setup_rescan.patch`)
tries busy cameras again. The automatic 5-second refresh does not. Otherwise Camera Setup
could take a camera that a bringup started afterwards needs.

This was tested on `s1` in an isolated ROS domain, with a fake bringup publishing labelled
frames and two cameras held open:
- the two busy cameras streamed the bringup frames (320x240, 10 fps);
- the free camera streamed directly (640x480, ~30 fps);
- the slots matched `cameras.yaml`.

**Status on `s1`:** installed on 2026-10-22 in both `src/` and `install/`, with `.bak`
backups of the originals next to each file.

### Lab test on s1 (2026-10-22)

I tested with the real camera nodes (`start_all_cameras.launch.py` only, no full bringup) in
ROS domain 77, and the real Camera Setup page with the Daksha app's drag script:

| Check | Result |
| --- | --- |
| Slots at startup | match `cameras.yaml` |
| D455 held by its node | live from `/camera/world`, 640×480; thumbnail mirrored |
| D405s held by their nodes (no frames, see below) | "device busy", no stream opened |
| Scan with the page open | 114–162 ms |
| Drops on row text, three rows | each lit only its own row and assigned it |
| Rescan while cameras held | retries, fails harmlessly, World keeps streaming |
| Camera nodes stopped, normal refresh | stays busy (by design) |
| Camera nodes stopped, Rescan | D455 live directly from the camera |

## Robot issue found: D405 wrist cameras give no frames in the camera bringup

When `start_all_cameras.launch.py` starts the two D405s, their nodes keep logging "Frames
didn't arrive within 5 seconds" and publish nothing. Afterwards the D405s give 0 frames even
when opened directly, until they get a hardware reset (or are replugged). After a
`hardware_reset()` both delivered ~25 fps again. The D455 is not affected.

Both D405s sit on the same USB 3 hub (`2-3.4.1`, `2-3.4.3`). Their nodes open color from
the depth module at 848×480@30 (a D405 has no separate RGB sensor, so
`rgb_camera.color_profile` from the launch file doesn't apply). The `left` republisher also
crashed (exit -11) when its node stopped.

Things to try, not done yet:
- add `initial_reset: true` to the D405 nodes' parameters;
- set `depth_module.color_profile` explicitly for the D405s;
- test one D405 per USB port.
