/* Daksha session helper for pages served through the Daksha gate.
 *
 * When the session expires, the page's API calls start getting 401 and its
 * WebSockets are refused. This notices that and asks the Daksha app to sign in
 * again: the app gets a fresh ticket and reloads the current page.
 *
 * Settings come from window.DAKSHA_CONFIG (see daksha-config.js). Pages can also
 * use window.Daksha:
 *   Daksha.inApp            true inside the Daksha app
 *   Daksha.checkSession()   Promise<boolean>: is the session still valid?
 *   Daksha.logout()         ends the session (the app signs in again on Reload)
 *   Daksha.onExpired(fn)    calls fn() when the session is found to be gone
 */
(function () {
  if (window.Daksha) return;

  var config = Object.assign({
    gatePath: '/_gate',
    sessionCheckSeconds: 300,
    whenExpiredOutsideApp: 'none',
    debug: false
  }, window.DAKSHA_CONFIG || {});

  var inApp = !!window.flutter_inappwebview;
  var expired = false;
  var listeners = [];

  function debug(msg) {
    if (config.debug) console.log('[daksha] ' + msg);
  }

  function sameOrigin(url) {
    try { return new URL(url, location.href).origin === location.origin; } catch (e) { return false; }
  }

  function onSessionGone() {
    if (expired) return;
    expired = true;
    debug('session expired');
    listeners.forEach(function (fn) { try { fn(); } catch (e) { console.error(e); } });
    if (inApp && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('reauth', location.pathname + location.search);
    } else if (config.whenExpiredOutsideApp === 'reload') {
      location.reload();
    }
  }

  var fetch_ = window.fetch;

  function checkSession() {
    return fetch_.call(window, config.gatePath + '/session', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (res) {
        if (res.status === 401) onSessionGone();
        return res.status === 204;
      })
      .catch(function () { return false; });  // network trouble isn't expiry
  }

  // Any 401 from this site means the session is gone.
  window.fetch = function (input, init) {
    return fetch_.apply(this, arguments).then(function (res) {
      var url = typeof input === 'string' ? input : (input && input.url) || '';
      if (res.status === 401 && sameOrigin(url)) onSessionGone();
      return res;
    });
  };

  var open_ = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.addEventListener('load', function () {
      if (this.status === 401 && sameOrigin(url)) onSessionGone();
    });
    return open_.apply(this, arguments);
  };

  // A refused WebSocket looks like any dropped connection, so ask the gate.
  var WebSocket_ = window.WebSocket;
  window.WebSocket = function (url, protocols) {
    var ws = protocols === undefined ? new WebSocket_(url) : new WebSocket_(url, protocols);
    if (sameOrigin(String(url).replace(/^ws/, 'http'))) ws.addEventListener('close', checkSession);
    return ws;
  };
  window.WebSocket.prototype = WebSocket_.prototype;
  ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (k) { window.WebSocket[k] = WebSocket_[k]; });

  if (config.sessionCheckSeconds > 0) setInterval(checkSession, config.sessionCheckSeconds * 1000);

  window.Daksha = {
    inApp: inApp,
    checkSession: checkSession,
    logout: function () {
      return fetch_.call(window, config.gatePath + '/logout', { method: 'POST', credentials: 'same-origin' });
    },
    onExpired: function (fn) { listeners.push(fn); }
  };
  debug('ready' + (inApp ? ' (in app)' : ''));
})();
