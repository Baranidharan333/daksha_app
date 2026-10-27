/* Daksha page settings. Load this before daksha-session.js:
 *
 *   <script src="/static/daksha-config.js"></script>
 *   <script src="/static/daksha-session.js"></script>
 *
 * Every field is optional; these are the defaults.
 */
window.DAKSHA_CONFIG = {
  // Where the gate's routes live; matches GATE in daksha_gate.py / gateway/app.py.
  gatePath: '/_gate',

  // How often an idle page asks whether its session is still valid (0 = never).
  sessionCheckSeconds: 300,

  // Outside the Daksha app there is no session to renew. 'none' leaves the page
  // as it is; 'reload' reloads it, which shows the gate's empty page.
  whenExpiredOutsideApp: 'none',

  // Log session events to the browser console.
  debug: false
};
