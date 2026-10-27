#include <cstdlib>
#include <cstring>
#include <string>

#include "my_application.h"

namespace {

// On multi-GPU machines (e.g. AMD iGPU + NVIDIA dGPU) WPE WebKit may pick a
// different GPU than the one driving the display, and the shared frame then
// shows up black. Point WPE at the boot VGA device (the one the desktop uses).
void PinWebKitToDisplayGpu() {
  if (g_getenv("WPE_DRM_DEVICE") != nullptr) return;

  GDir* dir = g_dir_open("/sys/class/drm", 0, nullptr);
  if (dir == nullptr) return;

  std::string card;
  std::string render_node;
  const gchar* name;
  while ((name = g_dir_read_name(dir)) != nullptr) {
    if (!g_str_has_prefix(name, "card") || strchr(name, '-') != nullptr) continue;
    std::string device = std::string("/sys/class/drm/") + name + "/device";
    gchar* boot_vga = nullptr;
    if (!g_file_get_contents((device + "/boot_vga").c_str(), &boot_vga, nullptr, nullptr)) continue;
    bool is_boot = boot_vga[0] == '1';
    g_free(boot_vga);
    if (!is_boot) continue;

    card = std::string("/dev/dri/") + name;
    // Find the render node belonging to the same PCI device.
    GDir* drm = g_dir_open((device + "/drm").c_str(), 0, nullptr);
    if (drm != nullptr) {
      const gchar* node;
      while ((node = g_dir_read_name(drm)) != nullptr) {
        if (g_str_has_prefix(node, "renderD")) render_node = std::string("/dev/dri/") + node;
      }
      g_dir_close(drm);
    }
    break;
  }
  g_dir_close(dir);

  if (!card.empty()) setenv("WPE_DRM_DEVICE", card.c_str(), 0);
  if (!render_node.empty()) setenv("WEBKIT_WEB_RENDER_DEVICE_FILE", render_node.c_str(), 0);
}

}  // namespace

int main(int argc, char** argv) {
  // WPE WebKit 2.54 on Kali aborts at startup: its bubblewrap sandbox kills
  // xdg-dbus-proxy (exit 159, seccomp). Disable the web-process sandbox unless
  // the user has set the variable themselves.
  setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1", 0);
  PinWebKitToDisplayGpu();

  // The zero-copy GPU (DMA-BUF) path delivers frames that display black here,
  // so the web view uses SHM buffers and a pixel texture. WebKit itself is put
  // in software mode in my_application.cc, once Flutter has its GPU context.
  setenv("FLUTTER_INAPPWEBVIEW_LINUX_DISABLE_GL", "1", 0);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
