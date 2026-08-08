#include "include/flutter_local_timezone/flutter_local_timezone_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_local_timezone_plugin.h"

void FlutterLocalTimezonePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_local_timezone::FlutterLocalTimezonePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
