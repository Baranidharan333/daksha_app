import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// The web UI this app shows until the user connects to another server.
const String appUrl = 'http://s1.local:8100/';

/// The robot base's navigation UI, pinned behind its own toolbar button.
const String navigationUrl = 'http://base.local:8000/';
const String navigationName = 'Navigation';
const int defaultPort = 8100;
const String appName = 'daksha';

File _configFile(String name) {
  final env = Platform.environment;
  final config = Platform.isWindows
      ? env['APPDATA'] ?? '.'
      : env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? '.'}/.config';
  return File('$config/daksha/$name');
}

/// Where the last server the user connected to is remembered.
File get _serverFile => _configFile('server');

/// Robot web UIs sit behind the Daksha gateway (see gateway/README.md). The app
/// trades its launch key for a one-time ticket, and opening the gateway's entry
/// page with it gives the web view a session cookie.
const String _gatePath = '/_gate';

/// The launch key sent to the gateway: ~/.config/daksha/app_key (on Windows
/// %APPDATA%\daksha\app_key), else
/// DAKSHA_APP_KEY from the environment or from --dart-define at build time.
/// Anyone with this machine can read it; the gateway does the real checking.
final String _appKey = () {
  try {
    final key = _configFile('app_key').readAsStringSync().trim();
    if (key.isNotEmpty) return key;
  } catch (_) {}
  return Platform.environment['DAKSHA_APP_KEY'] ?? const String.fromEnvironment('DAKSHA_APP_KEY');
}();

/// The gateway refused the launch key (HTTP [status]).
class _GateDenied implements Exception {
  _GateDenied(this.status);

  final int status;
}

/// The URL that opens [url] through its server's gateway: asks for a launch
/// ticket and returns the entry page that redirects to [url]. A server without
/// a gateway gets [url] unchanged. Throws [_GateDenied] if the key is refused,
/// or an I/O error if the server can't be reached.
Future<String> _gatedUrl(String url) async {
  final uri = Uri.parse(url);
  final origin = Uri(scheme: uri.scheme, host: uri.host, port: uri.port);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.postUrl(origin.replace(path: '$_gatePath/ticket'));
    request.headers.set('X-App-Key', _appKey);
    final response = await request.close().timeout(const Duration(seconds: 5));
    final body = await response.transform(utf8.decoder).join();
    if (const [401, 403, 429].contains(response.statusCode)) {
      throw _GateDenied(response.statusCode);
    }
    String? ticket;
    try {
      ticket = (jsonDecode(body) as Map)['ticket'] as String?;
    } catch (_) {}
    if (response.statusCode != 200 || ticket == null) return url;
    return origin.replace(path: '$_gatePath/entry', queryParameters: {
      'ticket': ticket,
      'next': uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path,
    }).toString();
  } finally {
    client.close();
  }
}

String _loadServerUrl() {
  try {
    final saved = _serverFile.readAsStringSync().trim();
    if (_parseServer(saved) != null) return saved;
  } catch (_) {}
  return appUrl;
}

void _saveServerUrl(String url) {
  try {
    _serverFile
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(url);
  } catch (e) {
    debugPrint('[webui] could not save server: $e');
  }
}

/// Turns "s1", "s1.local", "192.168.1.20", "host:9000" or a full URL into the
/// dashboard URL, defaulting to http and [defaultPort]. A bare name such as
/// "s1" gets ".local" added. Null if invalid.
String? _parseServer(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final bare = !uri.host.contains('.') && !uri.host.contains(':') && uri.host != 'localhost';
  return uri
      .replace(
        host: bare ? '${uri.host}.local' : uri.host,
        port: uri.hasPort ? uri.port : defaultPort,
        path: uri.path.isEmpty ? '/' : uri.path,
      )
      .toString();
}

/// The text shown for a server: the host without ".local" (which [_parseServer]
/// adds back), plus the port if it isn't the default.
String _serverLabel(String url) {
  final uri = Uri.parse(url);
  final host = uri.host.endsWith('.local')
      ? uri.host.substring(0, uri.host.length - '.local'.length)
      : uri.host;
  return uri.port == defaultPort ? host : '$host:${uri.port}';
}

const _bg = Color(0xFF0B1020);
const _tabSelected = Color(0xFF202941);
const _tabBorder = Color(0xFF394767);

/// Sends new-window links (target="_blank", middle-click, window.open) to the
/// app instead of letting WebKit create a "related" view. Related views share
/// the parent's script store, which breaks the plugin's JS bridge (wrong
/// secret token warnings) and makes tabs flicker or fail to load.
const _newTabScript = r'''
(function () {
  function openTab(url) {
    try { url = new URL(url, location.href).href; } catch (e) {}
    if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler('openTab', url);
  }
  function linkFor(e) {
    var el = e.target;
    return el && el.closest ? el.closest('a[href]') : null;
  }
  document.addEventListener('click', function (e) {
    var a = linkFor(e);
    if (!a) return;
    var t = (a.getAttribute('target') || '').toLowerCase();
    if (!t || t === '_self' || t === '_parent' || t === '_top') return;
    e.preventDefault();
    e.stopPropagation();
    openTab(a.href);
  }, true);
  document.addEventListener('auxclick', function (e) {
    var a = linkFor(e);
    if (!a || e.button !== 1) return;
    e.preventDefault();
    openTab(a.href);
  }, true);
  window.open = function (url) {
    if (url) openTab(url);
    return null;
  };
})();
''';

/// Reports uploads to the app ('uploadProgress'), since WebKit doesn't: wraps
/// XMLHttpRequest.send and, for same-origin requests that send a file, reports
/// the percentage sent. A form with chunk_index/total_chunks (the file manager's
/// chunked uploads) counts toward the whole file, grouped by its upload_id.
/// Cross-origin requests are left alone: an upload listener would make them
/// need a CORS preflight the server may not answer.
const _uploadProgressScript = r'''
(function () {
  if (window.__uploadProgress) return;
  window.__uploadProgress = true;
  var nextId = 1;
  function report(info) {
    if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler('uploadProgress', info);
  }
  function describe(body) {
    if (body instanceof FormData) {
      var file = null;
      body.forEach(function (v) { if (!file && v instanceof Blob) file = v; });
      if (!file) return null;
      var index = parseInt(body.get('chunk_index'), 10);
      var chunks = parseInt(body.get('total_chunks'), 10);
      var chunked = index >= 0 && chunks > 0;
      var named = body.get('filename');
      return {
        key: body.get('upload_id'),
        name: typeof named === 'string' && named ? named : (file.name || 'file'),
        index: chunked ? index : 0,
        chunks: chunked ? chunks : 1
      };
    }
    if (body instanceof Blob) return { key: null, name: body.name || 'file', index: 0, chunks: 1 };
    return null;
  }
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    try { this.__sameOrigin = new URL(url, location.href).origin === location.origin; }
    catch (e) { this.__sameOrigin = false; }
    return open.apply(this, arguments);
  };
  var send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function (body) {
    var d = null;
    try { if (this.__sameOrigin) d = describe(body); } catch (e) {}
    if (d) {
      var xhr = this, id = d.key || 'xhr' + nextId++, last = 0;
      var percent = function (fraction) { return Math.floor((d.index + fraction) / d.chunks * 100); };
      xhr.upload.addEventListener('progress', function (e) {
        var now = Date.now();
        if (!e.lengthComputable || now - last < 200) return;
        last = now;
        report({ id: id, name: d.name, percent: percent(e.loaded / e.total) });
      });
      xhr.addEventListener('loadend', function () {
        if (xhr.status < 200 || xhr.status >= 300) {
          report({ id: id, name: d.name, error: xhr.status ? 'HTTP ' + xhr.status : 'upload stopped' });
        } else {
          report({ id: id, name: d.name, percent: percent(1), done: d.index + 1 >= d.chunks });
        }
      });
    }
    return send.apply(this, arguments);
  };
})();
''';

/// WPE WebKit's offscreen mode has no native drag-and-drop, so elements with
/// draggable="true" never fire dragstart/dragover/drop. This rebuilds those
/// events from pointer events (pointer-based drags such as sliders are untouched),
/// and, like a browser, shows a faded copy of the dragged element under the
/// pointer with a cursor that tells whether the spot below accepts the drop.
/// Pages often accept drops only on a small box inside a larger card or row;
/// when the pointer is over a part that doesn't accept, the drag goes to the one
/// drop target close by (same card or row), never when there are several.
const _dragDropScript = r'''
(function () {
  if (window.__dndShim) return;
  window.__dndShim = true;
  var src = null, sx = 0, sy = 0, dragging = false, dt = null, over = null, accepted = false;
  var lastHit = null;
  var ghost = null, gx = 0, gy = 0, cursorStyle = null;

  // A faded copy of [el] that follows the pointer. Images become snapshots of
  // their current frame, so a live stream isn't opened a second time.
  function showGhost(el, e) {
    var r = el.getBoundingClientRect();
    gx = e.clientX - r.left; gy = e.clientY - r.top;
    ghost = el.cloneNode(true);
    ghost.removeAttribute('id');
    var from = el.querySelectorAll('img'), to = ghost.querySelectorAll('img');
    for (var i = 0; i < to.length; i++) {
      var c = document.createElement('canvas');
      c.width = from[i].clientWidth; c.height = from[i].clientHeight;
      c.className = to[i].className;
      c.style.cssText = to[i].style.cssText;
      try { c.getContext('2d').drawImage(from[i], 0, 0, c.width, c.height); } catch (err) {}
      to[i].replaceWith(c);
    }
    var s = ghost.style;
    s.position = 'fixed'; s.left = '0'; s.top = '0'; s.margin = '0'; s.boxSizing = 'border-box';
    s.width = r.width + 'px'; s.height = r.height + 'px';
    s.opacity = '0.7'; s.pointerEvents = 'none'; s.zIndex = '2147483647'; s.transition = 'none';
    s.boxShadow = '0 12px 32px rgba(0,0,0,0.35)';
    moveGhost(e);
    document.body.appendChild(ghost);
    cursorStyle = document.createElement('style');
    document.head.appendChild(cursorStyle);
  }
  function moveGhost(e) {
    if (ghost) ghost.style.transform = 'translate(' + (e.clientX - gx) + 'px,' + (e.clientY - gy) + 'px)';
  }
  function setCursor(ok) {
    if (cursorStyle) cursorStyle.textContent = '* { cursor: ' + (ok ? 'copy' : 'no-drop') + ' !important; }';
  }
  function hideGhost() {
    if (ghost) ghost.remove();
    if (cursorStyle) cursorStyle.remove();
    ghost = null; cursorStyle = null;
  }

  function makeDataTransfer() {
    try { return new DataTransfer(); } catch (e) {}
    var data = {};
    return {
      dropEffect: 'move', effectAllowed: 'all', types: [], files: [], items: [],
      setData: function (k, v) { data[k] = String(v); if (this.types.indexOf(k) < 0) this.types.push(k); },
      getData: function (k) { return data[k] || ''; },
      clearData: function () { data = {}; this.types = []; },
      setDragImage: function () {}
    };
  }
  function fire(type, target, e) {
    var init = { bubbles: true, cancelable: true, clientX: e.clientX, clientY: e.clientY,
                 screenX: e.screenX, screenY: e.screenY, dataTransfer: dt };
    var ev;
    try { ev = new DragEvent(type, init); } catch (err) { ev = new MouseEvent(type, init); }
    if (!ev.dataTransfer) { try { Object.defineProperty(ev, 'dataTransfer', { value: dt }); } catch (err) {} }
    return target.dispatchEvent(ev);  // false when a handler called preventDefault()
  }
  function reset() {
    hideGhost();
    src = null; dragging = false; dt = null; over = null; accepted = false; lastHit = null;
  }

  // Elements inside [box] (other than [hit] and its ancestors) that accept a
  // drop, stopping at two. Probing fires dragover, so each is told dragleave.
  // Children of an accepting element accept too (dragover bubbles to it), so
  // they count as part of it, not as more targets.
  function acceptingWithin(box, hit, e) {
    var found = [], els = box.querySelectorAll('*');
    if (els.length > 300) return found;
    for (var i = 0; i < els.length && found.length < 2; i++) {
      var el = els[i];
      if (el.contains(hit) || src.contains(el) || (ghost && ghost.contains(el))) continue;
      if (found.length && found[0].contains(el)) continue;
      if (!fire('dragover', el, e)) found.push(el);
    }
    found.forEach(function (el) { fire('dragleave', el, e); });
    return found;
  }

  // The element that gets the drag at [hit]: [hit] itself if it accepts drops,
  // else the single drop target within a few levels around it.
  function dropZoneFor(hit, e) {
    fire('dragenter', hit, e);
    if (!fire('dragover', hit, e)) return hit;
    fire('dragleave', hit, e);
    // Start with [hit] itself: the pointer may be on a row's padding, with
    // the row's own drop box inside it.
    for (var box = hit, depth = 0; box && box !== document.body && depth < 5;
         box = box.parentElement, depth++) {
      var found = acceptingWithin(box, hit, e);
      if (found.length > 1) return null;  // several targets close by: don't guess
      if (found.length === 1) { fire('dragenter', found[0], e); return found[0]; }
    }
    return null;
  }

  // Swallow any native drag attempt; we drive the drag ourselves.
  window.addEventListener('dragstart', function (e) {
    if (e.isTrusted) { e.preventDefault(); e.stopImmediatePropagation(); }
  }, true);

  window.addEventListener('pointerdown', function (e) {
    if (e.button !== 0 || !e.target.closest) return;
    var el = e.target.closest('[draggable="true"]');
    if (!el) return;
    src = el; sx = e.clientX; sy = e.clientY;
  }, true);

  window.addEventListener('pointermove', function (e) {
    if (!src) return;
    if (!dragging) {
      if (Math.abs(e.clientX - sx) + Math.abs(e.clientY - sy) < 6) return;
      dt = makeDataTransfer();
      dragging = true;
      if (!fire('dragstart', src, e)) { reset(); return; }
      var sel = window.getSelection && window.getSelection();
      if (sel) sel.removeAllRanges();
      showGhost(src, e);
    }
    e.preventDefault();
    moveGhost(e);
    var hit = document.elementFromPoint(e.clientX, e.clientY);
    if (hit !== lastHit) {
      lastHit = hit;
      if (over) fire('dragleave', over, e);
      over = hit ? dropZoneFor(hit, e) : null;
    }
    accepted = over ? !fire('dragover', over, e) : false;
    setCursor(accepted);
    fire('drag', src, e);
  }, true);

  function finish(e, drop) {
    if (!src) return;
    if (dragging) {
      if (drop && over && accepted) fire('drop', over, e);
      fire('dragend', src, e);
      // The click that follows a drag must not activate anything.
      window.addEventListener('click', function (c) { c.stopPropagation(); c.preventDefault(); },
                              { capture: true, once: true });
    }
    reset();
  }
  window.addEventListener('pointerup', function (e) { finish(e, true); }, true);
  window.addEventListener('pointercancel', function (e) { finish(e, false); }, true);
})();
''';

/// Logs what the page receives (WEBUI_DEBUG_INPUT=1) to compare with native input.
const _inputTraceScript = r'''
(function () {
  var moves = 0;
  function d(e) {
    return e.type + ' type=' + e.pointerType + ' button=' + e.button + ' buttons=' + e.buttons +
      ' target=' + (e.target && (e.target.id || e.target.tagName));
  }
  ['pointerdown', 'pointerup', 'pointercancel', 'lostpointercapture', 'mousedown', 'mouseup', 'click',
   'dragstart', 'drop', 'dragend']
    .forEach(function (t) { window.addEventListener(t, function (e) { console.log('[page] ' + d(e)); }, true); });
  window.addEventListener('pointermove', function (e) {
    if (e.buttons && moves++ % 15 === 0) console.log('[page] ' + d(e));
  }, true);
  window.addEventListener('wheel', function (e) { console.log('[page] wheel dy=' + e.deltaY); }, true);
})();
''';

final bool _traceInput = Platform.environment.containsKey('WEBUI_DEBUG_INPUT');

const _windowChannel = MethodChannel('app/window');

/// Downloads the web views save to ~/Downloads, reported by the patched plugin:
/// "saving", "saved" and "failed", each with the file's path.
const _downloadsChannel = MethodChannel('daksha/downloads');

/// Keyboard shortcuts shown in the help dialog (F1).
const _shortcutHelp = [
  ('Ctrl + R  /  F5', 'Reload page'),
  ('Ctrl + Shift + R', 'Reload, bypassing cache'),
  ('Esc', 'Stop loading'),
  ('Alt + ←  /  Alt + →', 'Back / Forward'),
  ('Alt + Home', 'Go to dashboard'),
  ('Ctrl + Tab  /  Ctrl + Shift + Tab', 'Next / previous tab'),
  ('Ctrl + 1 … 8  /  Ctrl + 9', 'Go to tab N / last tab'),
  ('Ctrl + W', 'Close tab'),
  ('Ctrl + +  /  Ctrl + −  /  Ctrl + 0', 'Zoom in / out / reset'),
  ('F11', 'Toggle fullscreen'),
  ('F1', 'Show these shortcuts'),
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WebUiApp());
}

class WebUiApp extends StatelessWidget {
  const WebUiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: appName,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C5CFF),
          brightness: Brightness.dark,
        ),
      ),
      home: const _AppRoot(),
    );
  }
}

/// The main window with the splash screen on top until it finishes. The web
/// views are built underneath straight away, so pages load during the splash.
class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  bool _splash = true;
  bool _fading = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const WebUiHome(),
        if (_splash)
          AnimatedOpacity(
            opacity: _fading ? 0 : 1,
            duration: const Duration(milliseconds: 450),
            onEnd: () => setState(() => _splash = false),
            // Material gives the splash text a style; without it, Flutter draws
            // text with a yellow double underline.
            child: Material(
              type: MaterialType.transparency,
              child: SplashScreen(onDone: () => setState(() => _fading = true)),
            ),
          ),
      ],
    );
  }
}

/// Opening sequence: the iHub Robotics logo, then the Daksha robot with a
/// pulsing eye glow and a loading bar. Calls [onDone] when finished.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late final _logo = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));
  late final _robot =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await _logo.forward();
    if (!mounted) return;
    setState(() {}); // switch to the robot stage
    await _robot.forward();
    if (mounted) widget.onDone();
  }

  @override
  void dispose() {
    _logo.dispose();
    _robot.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _logo.isCompleted ? _buildRobot() : _buildLogo();
  }

  /// iHub Robotics stage: a circuit trace with nodes draws itself in the logo's
  /// blue, the logo is revealed left to right, and the trace ends on the red dot.
  Widget _buildLogo() {
    final trace =
        CurvedAnimation(parent: _logo, curve: const Interval(0, 0.55, curve: Curves.easeInOut));
    final reveal = CurvedAnimation(
        parent: _logo, curve: const Interval(0.15, 0.6, curve: Curves.easeOutCubic));
    final settle =
        CurvedAnimation(parent: _logo, curve: const Interval(0.15, 0.7, curve: Curves.easeOutBack));
    final fadeOut =
        CurvedAnimation(parent: _logo, curve: const Interval(0.85, 1, curve: Curves.easeIn));
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: AnimatedBuilder(
          animation: _logo,
          builder: (context, _) => Opacity(
            opacity: (1 - fadeOut.value).clamp(0.0, 1.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.scale(
                  scale: 0.92 + 0.08 * settle.value,
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) {
                      final edge = reveal.value * 1.2;
                      return LinearGradient(
                        colors: const [Colors.white, Colors.white, Colors.transparent],
                        stops: [0, (edge - 0.2).clamp(0.0, 1.0), edge.clamp(0.0, 1.0)],
                      ).createShader(rect);
                    },
                    child: Image.asset('assets/ihub-robotics-logo.jpg', width: 460),
                  ),
                ),
                const SizedBox(height: 18),
                CustomPaint(
                  size: const Size(460, 40),
                  painter: _CircuitPainter(trace.value),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRobot() {
    final appear =
        CurvedAnimation(parent: _robot, curve: const Interval(0, 0.4, curve: Curves.easeOutBack));
    final fade =
        CurvedAnimation(parent: _robot, curve: const Interval(0, 0.3, curve: Curves.easeOut));
    final title =
        CurvedAnimation(parent: _robot, curve: const Interval(0.25, 0.65, curve: Curves.easeOut));
    return ColoredBox(
      color: _bg,
      child: Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([_robot, _pulse]),
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: fade.value.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.6 + 0.4 * appear.value,
                  child: Container(
                    width: 230,
                    height: 230,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF3FA9FF), width: 2),
                      boxShadow: [
                        BoxShadow(
                          color:
                              const Color(0xFF3FA9FF).withValues(alpha: 0.25 + 0.35 * _pulse.value),
                          blurRadius: 30 + 30 * _pulse.value,
                          spreadRadius: 2 + 8 * _pulse.value,
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: Image.asset('assets/daksha-head.png', fit: BoxFit.cover),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 36),
              Opacity(
                opacity: title.value.clamp(0.0, 1.0),
                child: Text(
                  'DAKSHA',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 4 + 10 * title.value,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Opacity(
                opacity: title.value.clamp(0.0, 1.0),
                child: const Text('by iHub Robotics',
                    style: TextStyle(fontSize: 13, color: Colors.white54, letterSpacing: 1.5)),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: 180,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _robot.value,
                    minHeight: 4,
                    backgroundColor: Colors.white12,
                    color: const Color(0xFF3FA9FF),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text('Loading…', style: TextStyle(fontSize: 12, color: Colors.white38)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A circuit trace in the iHub Robotics blue that draws itself as [progress]
/// goes from 0 to 1; nodes light up as the trace reaches them and the trace
/// ends on the logo's red dot.
class _CircuitPainter extends CustomPainter {
  _CircuitPainter(this.progress);

  final double progress;

  static const _blue = Color(0xFF3FA9FF);
  static const _ink = Color(0xFF1A1A1A);
  static const _red = Color(0xFFE31E24);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, mid = size.height / 2;
    final points = [
      Offset(0, mid),
      Offset(w * 0.22, mid),
      Offset(w * 0.32, mid - 14),
      Offset(w * 0.46, mid + 14),
      Offset(w * 0.60, mid - 14),
      Offset(w * 0.70, mid),
      Offset(w, mid),
    ];
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    final metric = path.computeMetrics().first;
    final drawn = metric.length * progress;
    canvas.drawPath(
      metric.extractPath(0, drawn),
      Paint()
        ..color = _blue
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    // Light each inner node once the trace has passed it.
    var travelled = 0.0;
    for (var i = 1; i < points.length; i++) {
      travelled += (points[i] - points[i - 1]).distance;
      if (i == points.length - 1 || drawn < travelled) continue;
      canvas.drawCircle(points[i], 5.5, Paint()..color = Colors.white);
      canvas.drawCircle(
        points[i],
        5.5,
        Paint()
          ..color = _ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // The moving head of the trace, then the red dot at the end.
    if (progress > 0 && progress < 1) {
      final head = metric.getTangentForOffset(drawn)!.position;
      canvas.drawCircle(head, 7, Paint()..color = _blue.withValues(alpha: 0.25));
      canvas.drawCircle(head, 3.5, Paint()..color = _blue);
    } else if (progress >= 1) {
      canvas.drawRect(
        Rect.fromCenter(center: points.last, width: 10, height: 10),
        Paint()..color = _red,
      );
    }
  }

  @override
  bool shouldRepaint(_CircuitPainter old) => old.progress != progress;
}

/// A download or upload, shown in the transfers bar under the page.
class _Transfer {
  _Transfer({required this.upload, required this.name});

  final bool upload;
  String name;

  /// A download's destination file; null for uploads.
  String? path;

  /// 0–1; null while the size is unknown.
  double? progress;
  String? error;
  bool done = false;
}

/// One open page. The first tab is the dashboard and cannot be closed;
/// the others are created when the page opens a link in a new window.
class WebTab {
  WebTab({required this.id, required this.url, this.title = 'Loading…'});

  final int id;
  final String url;
  String title;
  InAppWebViewController? controller;
  double progress = 0;
  bool loading = true;
  bool canGoBack = false;
  bool canGoForward = false;
  String? error;

  /// Signing in and loading the first page after [_WebUiHomeState._open];
  /// covers the empty web view until the page or an error appears.
  bool connecting = false;

  /// The gateway refused this app's launch key.
  bool denied = false;

  /// Counts [_WebUiHomeState._open] calls, so a slow one can't load over a newer one.
  int openSeq = 0;

  /// When the tab last signed in again after its session ran out.
  DateTime reauthAt = DateTime.fromMillisecondsSinceEpoch(0);
}

class WebUiHome extends StatefulWidget {
  const WebUiHome({super.key});

  @override
  State<WebUiHome> createState() => _WebUiHomeState();
}

class _WebUiHomeState extends State<WebUiHome> {
  String _serverUrl = _loadServerUrl();

  /// Tabs 0 (dashboard) and 1 (navigation) are pinned: they have toolbar
  /// buttons instead of entries in the tab strip, and cannot be closed.
  static const _pinned = 2;
  late final List<WebTab> _tabs = [
    WebTab(id: 0, url: _serverUrl, title: appName),
    WebTab(id: 1, url: navigationUrl, title: navigationName),
  ];
  late final _serverField = TextEditingController(text: _serverLabel(_serverUrl));
  int _active = 0;
  int _nextId = _pinned;

  /// Transfers in the bar under the page, in the order they started.
  final _transfers = <String, _Transfer>{};

  /// Developer mode is unlocked by tapping the DAKSHA title [_unlockTaps]
  /// times and entering [_developerPassword]. It always starts off; both
  /// modes currently offer the same features.
  static const _unlockTaps = 5;
  static const _developerPassword = 'ihub1234';
  bool _developerMode = false;
  int _titleTaps = 0;
  DateTime _lastTitleTap = DateTime.fromMillisecondsSinceEpoch(0);

  WebTab get _tab => _tabs[_active];

  @override
  void initState() {
    super.initState();
    // A global handler, because the focused web view consumes key events.
    HardwareKeyboard.instance.addHandler(_onKey);
    _downloadsChannel.setMethodCallHandler(_onDownload);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _downloadsChannel.setMethodCallHandler(null);
    _serverField.dispose();
    super.dispose();
  }

  /// Asks for a server address and connects to it.
  Future<void> _showConnectDialog() async {
    _serverField.text = _serverLabel(_serverUrl);
    _serverField.selection = TextSelection(baseOffset: 0, extentOffset: _serverField.text.length);
    String? error;
    final url = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final url = _parseServer(_serverField.text);
            if (url == null) {
              setDialogState(() => error = 'Enter a host name or IP address');
            } else {
              Navigator.pop(context, url);
            }
          }

          return AlertDialog(
            icon: const Icon(Icons.dns_outlined),
            title: const Text('Connect to robot'),
            content: SizedBox(
              width: 380,
              child: TextField(
                controller: _serverField,
                autofocus: true,
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  labelText: 'Host name or IP address',
                  hintText: 's1 or 192.168.1.20',
                  errorText: error,
                  prefixIcon: const Icon(Icons.lan_outlined),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton.icon(
                onPressed: submit,
                icon: const Icon(Icons.link, size: 18),
                label: const Text('Connect'),
              ),
            ],
          );
        },
      ),
    );
    if (url != null) await _connect(url);
  }

  /// Shows a page's alert(), confirm() or prompt() dialog, titled with the
  /// page's host. Returns null for Cancel, else the text entered (prompt) or ''.
  Future<String?> _showPageDialog(WebUri? url, String message,
      {bool canCancel = false, String? promptText}) {
    final field = promptText == null ? null : TextEditingController(text: promptText);
    final origin = url == null || url.host.isEmpty
        ? appName
        : (url.hasPort ? '${url.host}:${url.port}' : url.host);
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        void ok() => Navigator.pop(context, field?.text ?? '');
        // Escape cancels (an alert has only OK); Enter confirms. Neither button
        // takes focus, so a stray key can't press OK.
        void cancel() => canCancel ? Navigator.pop(context) : ok();
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter): ok,
            const SingleActivator(LogicalKeyboardKey.numpadEnter): ok,
            const SingleActivator(LogicalKeyboardKey.escape): cancel,
          },
          child: Focus(
            autofocus: field == null,
            child: AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.language, size: 20),
                  const SizedBox(width: 8),
                  Flexible(child: Text(origin, style: const TextStyle(fontSize: 16))),
                ],
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.isNotEmpty) SelectableText(message),
                    if (field != null) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: field,
                        autofocus: true,
                        onSubmitted: (_) => ok(),
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                if (canCancel) TextButton(onPressed: cancel, child: const Text('Cancel')),
                FilledButton(onPressed: ok, child: const Text('OK')),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() => field?.dispose());
  }

  /// Points the dashboard at [url]. Tabs opened from the previous server are
  /// closed, since they belong to it; the navigation page is kept.
  Future<void> _connect(String url) async {
    _saveServerUrl(url);
    setState(() {
      _serverUrl = url;
      _tabs.removeRange(_pinned, _tabs.length);
      _active = 0;
      _tabs[0].title = appName;
    });
    await _open(_tabs[0], url);
  }

  /// Loads [url] in [tab], signing in to the server's gateway first.
  Future<void> _open(WebTab tab, String url) async {
    final seq = ++tab.openSeq;
    setState(() {
      tab
        ..error = null
        ..denied = false
        ..connecting = true
        ..loading = true
        ..progress = 0;
    });
    try {
      final target = await _gatedUrl(url);
      if (!mounted || seq != tab.openSeq) return;
      await tab.controller?.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
    } catch (e) {
      if (!mounted || seq != tab.openSeq) return;
      debugPrint('[webui] could not sign in to ${Uri.parse(url).host}: $e');
      setState(() {
        tab
          ..connecting = false
          ..loading = false
          ..denied = e is _GateDenied
          ..error = '$e';
      });
    }
  }

  /// The tab's session ran out (the gateway answered with an empty page or a
  /// 401): sign in again and reopen [url]. At most once every 15 seconds, so a
  /// gateway that keeps refusing shows the error page instead of looping.
  void _reauth(WebTab tab, String url) {
    final now = DateTime.now();
    if (now.difference(tab.reauthAt) < const Duration(seconds: 15)) {
      setState(() {
        tab
          ..loading = false
          ..denied = true
          ..error = 'session refused';
      });
      return;
    }
    tab.reauthAt = now;
    final uri = Uri.parse(url);
    // A refused /_gate/entry page: go where it was meant to lead.
    _open(
        tab,
        uri.path.startsWith(_gatePath)
            ? uri.resolve(uri.queryParameters['next'] ?? '/').toString()
            : url);
  }

  /// Hosts the web views may open: the connected robot, the navigation base and
  /// the leader arms' portals (leader*.local). The gateways enforce access; this
  /// only keeps the app on the robot's pages.
  bool _allowedUrl(Uri? uri) {
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return true;
    final host = uri.host.toLowerCase();
    return host == Uri.parse(_serverUrl).host ||
        host == Uri.parse(navigationUrl).host ||
        (host.startsWith('leader') && host.endsWith('.local'));
  }

  /// True for pages served by one of the pinned servers, which may be gated.
  bool _isGated(Uri? uri) {
    if (uri == null) return false;
    return [_serverUrl, navigationUrl].any((u) {
      final pinned = Uri.parse(u);
      return pinned.host == uri.host && pinned.port == uri.port;
    });
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed;
    final shift = kb.isShiftPressed;
    final alt = kb.isAltPressed;
    final key = event.logicalKey;
    final repeat = event is KeyRepeatEvent;
    final c = _tab.controller;

    if (repeat) {
      // Only zoom keys make sense held down.
      if (ctrl &&
          (key == LogicalKeyboardKey.equal ||
              key == LogicalKeyboardKey.add ||
              key == LogicalKeyboardKey.numpadAdd)) {
        _zoom(1.1);
        return true;
      }
      if (ctrl && (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract)) {
        _zoom(1 / 1.1);
        return true;
      }
      return false;
    }

    if (key == LogicalKeyboardKey.f5 || (ctrl && key == LogicalKeyboardKey.keyR)) {
      if (shift) {
        c?.reloadFromOrigin();
      } else {
        _reload();
      }
    } else if (key == LogicalKeyboardKey.escape && _tab.loading) {
      c?.stopLoading();
    } else if (alt && key == LogicalKeyboardKey.arrowLeft) {
      if (_tab.canGoBack) c?.goBack();
    } else if (alt && key == LogicalKeyboardKey.arrowRight) {
      if (_tab.canGoForward) c?.goForward();
    } else if (alt && key == LogicalKeyboardKey.home) {
      _home();
    } else if (ctrl &&
        (key == LogicalKeyboardKey.tab ||
            key == LogicalKeyboardKey.pageDown ||
            key == LogicalKeyboardKey.pageUp)) {
      final back = key == LogicalKeyboardKey.pageUp || (key == LogicalKeyboardKey.tab && shift);
      setState(() => _active = (_active + (back ? -1 : 1)) % _tabs.length);
    } else if (ctrl && key == LogicalKeyboardKey.keyW) {
      _closeTab(_active);
    } else if (ctrl && _digit(key) != null) {
      final n = _digit(key)!;
      setState(() => _active = n == 9 ? _tabs.length - 1 : (n - 1).clamp(0, _tabs.length - 1));
    } else if (ctrl &&
        (key == LogicalKeyboardKey.equal ||
            key == LogicalKeyboardKey.add ||
            key == LogicalKeyboardKey.numpadAdd)) {
      _zoom(1.1);
    } else if (ctrl &&
        (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract)) {
      _zoom(1 / 1.1);
    } else if (ctrl && (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0)) {
      _zoom(null);
    } else if (key == LogicalKeyboardKey.f11) {
      _windowChannel.invokeMethod('toggleFullscreen');
    } else if (key == LogicalKeyboardKey.f1) {
      _showShortcuts();
    } else {
      return false;
    }
    return true;
  }

  static int? _digit(LogicalKeyboardKey key) {
    const keys = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    final i = keys.indexOf(key);
    return i < 0 ? null : i + 1;
  }

  /// Multiplies the zoom by [factor], or resets it to 100% when null.
  Future<void> _zoom(double? factor) async {
    final c = _tab.controller;
    if (c == null) return;
    final current = await c.getZoomScale() ?? 1.0;
    final target = factor == null ? 1.0 : (current * factor).clamp(0.3, 3.0);
    await c.zoomBy(zoomFactor: target / current);
  }

  void _showShortcuts() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keyboard shortcuts'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (keys, action) in _shortcutHelp)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 230,
                        child: Text(keys,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 13, color: Color(0xFFB8ACFF))),
                      ),
                      Expanded(child: Text(action, style: const TextStyle(fontSize: 13))),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  void _openTab(String url) {
    if (!_allowedUrl(Uri.tryParse(url))) {
      _showMessage('Blocked a link to ${Uri.parse(url).host}');
      return;
    }
    setState(() {
      _tabs.add(WebTab(id: _nextId++, url: url));
      _active = _tabs.length - 1;
    });
  }

  void _closeTab(int index) {
    if (index < _pinned) return;
    setState(() {
      _tabs.removeAt(index);
      if (_active > index || _active >= _tabs.length) _active--;
    });
  }

  Future<void> _updateHistory(WebTab tab) async {
    final c = tab.controller;
    if (c == null) return;
    final back = await c.canGoBack();
    final forward = await c.canGoForward();
    if (!mounted) return;
    setState(() {
      tab.canGoBack = back;
      tab.canGoForward = forward;
    });
  }

  /// The start page of pinned tab [index].
  String _pinnedUrl(int index) => index == 0 ? _serverUrl : navigationUrl;

  /// The pinned pages live behind toolbar buttons rather than in the tab strip.
  /// From another tab the button switches back without reloading; on the page
  /// itself it returns to that page's start URL.
  Future<void> _goPinned(int index) async {
    if (_active != index) {
      setState(() => _active = index);
      return;
    }
    await _open(_tabs[index], _pinnedUrl(index));
  }

  Future<void> _home() => _goPinned(0);

  Future<void> _reload() async {
    final tab = _tab;
    // After a failed load there is no page to reload, so load the start page.
    if (tab.error != null && _active < _pinned) return _goPinned(_active);
    setState(() => tab.error = null);
    await tab.controller?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final tab = _tab;
    return Scaffold(
      body: Column(
        children: [
          _buildToolbar(tab),
          SizedBox(
            height: 2,
            child: tab.loading
                ? LinearProgressIndicator(
                    value: (tab.progress / 100).clamp(0.0, 1.0),
                    backgroundColor: Colors.transparent,
                  )
                : null,
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                IndexedStack(
                  index: _active,
                  sizing: StackFit.expand,
                  children: [
                    for (final t in _tabs)
                      Stack(
                        key: ValueKey(t.id),
                        fit: StackFit.expand,
                        children: [
                          _buildWebView(t),
                          if (t.connecting && t.error == null) _buildConnecting(t),
                          if (t.error != null) _buildErrorPage(t),
                        ],
                      ),
                  ],
                ),
                if (_transfers.isNotEmpty)
                  Positioned(right: 12, bottom: 12, child: _buildTransfers()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  /// Applies [change] to transfer [key], adding it if new. Finished and failed
  /// transfers leave the bar after a while (downloads stay longer, for their
  /// Open folder button).
  void _updateTransfer(String key, bool upload, String name, void Function(_Transfer) change) {
    if (!mounted) return;
    final transfer = _transfers[key] ?? _Transfer(upload: upload, name: name);
    setState(() {
      _transfers[key] = transfer..name = name;
      change(transfer);
    });
    if (transfer.done || transfer.error != null) {
      final linger = transfer.upload && transfer.error == null ? 4 : 10;
      Future.delayed(Duration(seconds: linger), () {
        if (mounted && identical(_transfers[key], transfer)) setState(() => _transfers.remove(key));
      });
    }
  }

  /// A download's progress from the plugin (see [_downloadsChannel]).
  Future<void> _onDownload(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map);
    final path = args['path'] as String? ?? '';
    final received = args['received'] as num? ?? 0;
    final total = args['total'] as num? ?? 0;
    _updateTransfer('download-${args['id']}', false, path.isEmpty ? 'file' : path.split('/').last,
        (t) {
      if (path.isNotEmpty) t.path = path;
      if (total > 0) t.progress = (received / total).clamp(0.0, 1.0);
      if (call.method == 'saved') {
        t.done = true;
        t.progress = 1;
      } else if (call.method == 'failed') {
        t.error = '${args['error']}';
      }
    });
  }

  /// An upload's progress, from [_uploadProgressScript] in [tab].
  void _onUploadProgress(WebTab tab, Map args) {
    _updateTransfer('upload-${tab.id}-${args['id']}', true, '${args['name'] ?? 'file'}', (t) {
      final percent = args['percent'];
      if (percent is num) t.progress = (percent / 100).clamp(0.0, 1.0);
      if (args['error'] != null) t.error = '${args['error']}';
      if (args['done'] == true) t.done = true;
    });
  }

  /// [path] with the home folder shown as ~.
  static String _shortPath(String path) {
    final home = Platform.environment['HOME'];
    return home != null && path.startsWith(home) ? '~${path.substring(home.length)}' : path;
  }

  /// A small card over the page's bottom-right corner listing transfers (at
  /// most three; the newest last).
  Widget _buildTransfers() {
    final shown = _transfers.values.toList();
    final hidden = shown.length > 3 ? shown.length - 3 : 0;
    return Material(
      color: _tabSelected,
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 260,
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _tabBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hidden > 0)
              Text('+$hidden more', style: const TextStyle(color: Colors.white54, fontSize: 11)),
            for (final t in shown.skip(hidden)) _buildTransfer(t),
          ],
        ),
      ),
    );
  }

  /// One line per transfer; its full status (where a download is saved, or why
  /// it failed) is in the tooltip.
  Widget _buildTransfer(_Transfer t) {
    final percent = t.progress == null ? null : (t.progress! * 100).floor();
    final folder = t.path == null ? null : _shortPath(File(t.path!).parent.path);
    final String status;
    if (t.error != null) {
      status = '${t.upload ? 'Upload' : 'Download'} failed: ${t.error}';
    } else if (t.done) {
      status = t.upload ? 'Uploaded' : 'Saved to $folder';
    } else {
      status = t.upload ? 'Uploading' : 'Downloading${folder == null ? '' : ' to $folder'}';
    }
    final color = t.error != null
        ? const Color(0xFFFF8A80)
        : t.done
            ? const Color(0xFF81C784)
            : const Color(0xFF3FA9FF);
    return Tooltip(
      message: '$status\n${t.name}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  t.error != null
                      ? Icons.error_outline
                      : t.done
                          ? Icons.check_circle_outline
                          : t.upload
                              ? Icons.arrow_upward
                              : Icons.arrow_downward,
                  size: 14,
                  color: color,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(t.name.split('/').last,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                ),
                Text(t.error != null ? 'Failed' : percent == null ? '' : '$percent%',
                    style: TextStyle(color: color, fontSize: 11)),
                SizedBox(
                  width: 24,
                  height: 20,
                  child: !t.upload && t.done && t.path != null
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 15,
                          tooltip: 'Open folder',
                          icon: const Icon(Icons.folder_open, color: Colors.white70),
                          onPressed: () => Process.run('xdg-open', [File(t.path!).parent.path]),
                        )
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 3),
            Padding(
              padding: const EdgeInsets.only(right: 24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: t.error != null ? 1 : t.progress,
                  minHeight: 3,
                  color: color,
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Counts quick taps on the title; the fifth asks for the developer password,
  /// or, in developer mode, switches back to user mode.
  void _onTitleTap() {
    final now = DateTime.now();
    if (now.difference(_lastTitleTap) > const Duration(seconds: 2)) _titleTaps = 0;
    _lastTitleTap = now;
    _titleTaps++;
    final left = _unlockTaps - _titleTaps;
    if (left > 0) {
      if (_titleTaps >= 3) {
        _showMessage(_developerMode
            ? '$left more ${left == 1 ? 'tap' : 'taps'} to switch to user mode'
            : '$left more ${left == 1 ? 'tap' : 'taps'} for developer mode');
      }
      return;
    }
    _titleTaps = 0;
    if (_developerMode) {
      setState(() => _developerMode = false);
      _showMessage('Switched to user mode');
    } else {
      _askDeveloperPassword();
    }
  }

  Future<void> _askDeveloperPassword() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final field = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            if (field.text == _developerPassword) {
              Navigator.pop(context, true);
            } else {
              setDialogState(() => error = 'Wrong password');
              field.clear();
            }
          }

          return AlertDialog(
            icon: const Icon(Icons.developer_mode),
            title: const Text('Developer mode'),
            content: SizedBox(
              width: 340,
              child: TextField(
                controller: field,
                autofocus: true,
                obscureText: true,
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  errorText: error,
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(onPressed: submit, child: const Text('Unlock')),
            ],
          );
        },
      ),
    );
    field.dispose();
    if (ok == true && mounted) {
      setState(() => _developerMode = true);
      _showMessage('Developer mode on');
    }
  }

  Widget _buildTitle() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: _onTitleTap,
          borderRadius: BorderRadius.circular(8),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
              'DAKSHA',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
                color: Colors.white,
              ),
            ),
          ),
        ),
        if (_developerMode)
          Container(
            margin: const EdgeInsets.only(left: 2, right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0x33E31E24),
              border: Border.all(color: const Color(0xFFE31E24)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'DEVELOPER',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: Color(0xFFFF6B70),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildToolbar(WebTab tab) {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: _bg,
      child: Row(
        children: [
          _buildTitle(),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Back',
            onPressed: tab.canGoBack ? () => tab.controller?.goBack() : null,
            icon: const Icon(Icons.arrow_back, size: 20),
          ),
          IconButton(
            tooltip: 'Forward',
            onPressed: tab.canGoForward ? () => tab.controller?.goForward() : null,
            icon: const Icon(Icons.arrow_forward, size: 20),
          ),
          IconButton(
            tooltip: 'Reload',
            onPressed: _reload,
            icon: const Icon(Icons.refresh, size: 20),
          ),
          IconButton(
            tooltip: appName,
            onPressed: _home,
            isSelected: _active == 0,
            selectedIcon: const Icon(Icons.home, size: 20),
            icon: const Icon(Icons.home_outlined, size: 20),
            style: IconButton.styleFrom(
              backgroundColor: _active == 0 ? _tabSelected : null,
              foregroundColor: _active == 0 ? const Color(0xFFB8ACFF) : null,
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            height: 34,
            child: TextButton.icon(
              onPressed: () => _goPinned(1),
              icon: Icon(_active == 1 ? Icons.navigation : Icons.navigation_outlined, size: 18),
              label: const Text(navigationName, style: TextStyle(fontSize: 13)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                backgroundColor: _active == 1 ? _tabSelected : null,
                foregroundColor: _active == 1 ? const Color(0xFFB8ACFF) : Colors.white70,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: _buildTabStrip()),
          const SizedBox(width: 8),
          _buildConnectButton(),
          IconButton(
            tooltip: 'Keyboard shortcuts (F1)',
            onPressed: _showShortcuts,
            icon: const Icon(Icons.keyboard_outlined, size: 20),
          ),
        ],
      ),
    );
  }

  /// Shows which server the dashboard is connected to; opens the connect dialog.
  Widget _buildConnectButton() {
    return SizedBox(
      height: 34,
      child: Tooltip(
        message: 'Connect to another robot',
        child: FilledButton.tonalIcon(
          onPressed: _showConnectDialog,
          icon: const Icon(Icons.dns_outlined, size: 16),
          label: Text(_serverLabel(_serverUrl), style: const TextStyle(fontSize: 13)),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
    );
  }

  Widget _buildTabStrip() {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _tabs.length - _pinned,
      separatorBuilder: (_, __) => const SizedBox(width: 6),
      itemBuilder: (context, i) {
        final index = i + _pinned;
        final t = _tabs[index];
        final selected = index == _active;
        return Listener(
          // Middle-click closes a tab, like in a regular browser.
          onPointerDown: (e) {
            if (e.buttons == kMiddleMouseButton) _closeTab(index);
          },
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _active = index),
            child: Container(
              width: 210,
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: BoxDecoration(
                color: selected ? _tabSelected : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: selected ? _tabBorder : Colors.transparent),
              ),
              child: Row(
                children: [
                  Icon(Icons.article_outlined,
                      size: 16, color: selected ? const Color(0xFFB8ACFF) : Colors.white54),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected ? Colors.white : Colors.white60,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close tab',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 26, height: 26),
                    onPressed: () => _closeTab(index),
                    icon: const Icon(Icons.close, size: 15),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWebView(WebTab tab) {
    final pinned = _tabs.indexOf(tab) < _pinned;
    return InAppWebView(
      // Pinned pages sign in to their gateway first (see onWebViewCreated);
      // other tabs share the session cookie the pinned pages got.
      initialUrlRequest: pinned ? null : URLRequest(url: WebUri(tab.url)),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: _newTabScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: _dragDropScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: _uploadProgressScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        if (_traceInput)
          UserScript(
            source: _inputTraceScript,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
      ]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        // Keep WebKit from creating related views; _newTabScript handles new tabs.
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false,
        supportZoom: true,
        transparentBackground: false,
        useShouldOverrideUrlLoading: true,
      ),
      shouldOverrideUrlLoading: (controller, action) async {
        final uri = action.request.url;
        if (action.isForMainFrame && !_allowedUrl(uri)) {
          _showMessage('Blocked a link to ${uri!.host}');
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
      // The page's alert/confirm/prompt; without these they'd silently cancel.
      onJsAlert: (controller, request) async {
        await _showPageDialog(request.url, request.message ?? '');
        return JsAlertResponse();
      },
      onJsConfirm: (controller, request) async {
        final ok = await _showPageDialog(request.url, request.message ?? '', canCancel: true);
        return JsConfirmResponse(
            action: ok != null ? JsConfirmResponseAction.CONFIRM : JsConfirmResponseAction.CANCEL);
      },
      onJsPrompt: (controller, request) async {
        final text = await _showPageDialog(request.url, request.message ?? '',
            canCancel: true, promptText: request.defaultValue ?? '');
        return JsPromptResponse(
            value: text,
            action: text != null ? JsPromptResponseAction.CONFIRM : JsPromptResponseAction.CANCEL);
      },
      onConsoleMessage: _traceInput
          ? (controller, msg) {
              if (msg.message.startsWith('[page]')) debugPrint(msg.message);
            }
          : null,
      onWebViewCreated: (controller) {
        tab.controller = controller;
        controller.addJavaScriptHandler(
          handlerName: 'openTab',
          callback: (args) {
            if (args.isNotEmpty && args.first is String && mounted) _openTab(args.first as String);
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'uploadProgress',
          callback: (args) {
            if (args.isNotEmpty && args.first is Map) _onUploadProgress(tab, args.first as Map);
          },
        );
        // Called by the page's daksha-session.js when the gateway answers 401.
        controller.addJavaScriptHandler(
          handlerName: 'reauth',
          callback: (args) async {
            final url = await controller.getUrl();
            if (mounted && _isGated(url)) _reauth(tab, url.toString());
          },
        );
        if (pinned) _open(tab, tab.url);
      },
      onCloseWindow: (controller) {
        final index = _tabs.indexOf(tab);
        if (index >= _pinned) _closeTab(index);
      },
      onLoadStart: (controller, url) {
        if (!mounted) return;
        setState(() {
          tab.loading = true;
          tab.error = null;
        });
      },
      onTitleChanged: (controller, title) {
        if (!mounted || title == null || title.isEmpty) return;
        setState(() => tab.title = title);
      },
      onProgressChanged: (controller, progress) {
        if (!mounted) return;
        setState(() => tab.progress = progress.toDouble());
      },
      onLoadStop: (controller, url) async {
        final title = await controller.getTitle();
        if (!mounted) return;
        setState(() {
          tab
            ..loading = false
            ..connecting = false;
          if (title != null && title.isNotEmpty) tab.title = title;
        });
        await _updateHistory(tab);
        // A gateway without a session sends an empty page (this plugin doesn't
        // report HTTP status codes on Linux), so an empty page means sign in again.
        if (_isGated(url)) {
          final blank = await controller.evaluateJavascript(
              source: '!document.body || (document.body.children.length === 0 && '
                  "document.body.textContent.trim() === '')");
          if (blank == true && mounted) _reauth(tab, url.toString());
        }
      },
      onUpdateVisitedHistory: (controller, url, isReload) => _updateHistory(tab),
      onReceivedError: (controller, request, error) {
        // Cancelled loads (e.g. in-page #anchor jumps) are not real failures,
        // and a load interrupted by policy change is a link that became a download.
        if (!mounted ||
            request.isForMainFrame == false ||
            error.type == WebResourceErrorType.CANCELLED ||
            error.type == WebResourceErrorType.FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE) {
          return;
        }
        debugPrint('[webui] load error: ${error.type} ${error.description}');
        setState(() {
          tab.loading = false;
          tab.connecting = false;
          tab.error = error.description;
        });
      },
    );
  }

  /// Shown while [_open] signs in and loads, so the wait isn't a blank page.
  Widget _buildConnecting(WebTab tab) {
    final label = _serverLabel(tab.id == 0 ? _serverUrl : tab.url);
    return ColoredBox(
      color: _bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF3FA9FF)),
            ),
            const SizedBox(height: 20),
            Text('Connecting to $label…',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('Waiting for the robot to answer',
                style: TextStyle(fontSize: 13, color: Colors.white54)),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorPage(WebTab tab) {
    // Shown as a popup card over a dimmed backdrop.
    return Container(
      color: const Color(0xE60B1020),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Material(
          color: const Color(0xFF141B2D),
          elevation: 12,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset('assets/daksha-mini.jpg', height: 280, fit: BoxFit.contain),
                ),
                const SizedBox(height: 20),
                Text(tab.denied ? 'This app is not authorized' : 'Robot is not available',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                    tab.denied
                        ? 'The robot at ${_serverLabel(tab.id == 0 ? _serverUrl : tab.url)} '
                            'did not accept this app\'s launch key.\n'
                            'Put the key from the robot\'s gateway in ~/.config/daksha/app_key, '
                            'then press Retry.'
                        : 'Turn on the robot, then press Retry.\n'
                            'Could not connect to the robot at ${_serverLabel(tab.id == 0 ? _serverUrl : tab.url)}. '
                            'Make sure it is on the same network.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white60)),
                const SizedBox(height: 24),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                    if (tab.id == 0) ...[
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _showConnectDialog,
                        icon: const Icon(Icons.dns_outlined),
                        label: const Text('Connect to robot'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
