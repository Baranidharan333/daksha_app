#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_FILE_INPUT_JS_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_FILE_INPUT_JS_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "../types/plugin_script.h"
#include "javascript_bridge_js.h"

namespace flutter_inappwebview_plugin {

/**
 * JavaScript that tells native code which kind of file input was clicked.
 *
 * WPE's WebKitFileChooserRequest doesn't say whether the page asked for a
 * folder (<input type="file" webkitdirectory>), so the native chooser would
 * always pick files. This reports it just before WebKit asks for the chooser:
 * the click handler runs before the input's default action, and both messages
 * reach native code in order.
 */
class FileInputJS {
 public:
  inline static const std::string FILE_INPUT_JS_PLUGIN_SCRIPT_GROUP_NAME =
      "IN_APP_WEBVIEW_FILE_INPUT_JS_PLUGIN_SCRIPT";

  static std::string FILE_INPUT_JS_SOURCE() {
    return R"JS(
(function() {
  if (window._flutterFileInputInstalled) return;
  window._flutterFileInputInstalled = true;

  // Capture on window, so the page's own handlers can't stop it first. Clicks on
  // a <label> and input.click() both end in a click event on the input itself.
  window.addEventListener('click', function(e) {
    var el = e.target;
    if (!el || el.tagName !== 'INPUT' || (el.type || '').toLowerCase() !== 'file') return;
    try {
      window.)JS" +
           JavaScriptBridgeJS::get_JAVASCRIPT_BRIDGE_NAME() +
           R"JS(.callHandler('_fileInputClicked', !!el.webkitdirectory);
    } catch(_) {}
  }, true);
})();
)JS";
  }

  static std::unique_ptr<PluginScript> FILE_INPUT_JS_PLUGIN_SCRIPT(
      const std::optional<std::vector<std::string>>& allowedOriginRules,
      bool forMainFrameOnly) {
    return std::make_unique<PluginScript>(
        FILE_INPUT_JS_PLUGIN_SCRIPT_GROUP_NAME,
        FILE_INPUT_JS_SOURCE(),
        UserScriptInjectionTime::atDocumentStart,
        forMainFrameOnly,
        allowedOriginRules,
        nullptr,                    // contentWorld
        true,                       // requiredInAllContentWorlds
        std::vector<std::string>{}  // no additional message handlers needed
    );
  }
};

}  // namespace flutter_inappwebview_plugin

#endif  // FLUTTER_INAPPWEBVIEW_PLUGIN_FILE_INPUT_JS_H_
