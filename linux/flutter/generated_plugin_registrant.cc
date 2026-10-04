//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <camera_desktop/camera_desktop_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) camera_desktop_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "CameraDesktopPlugin");
  camera_desktop_plugin_register_with_registrar(camera_desktop_registrar);
}
