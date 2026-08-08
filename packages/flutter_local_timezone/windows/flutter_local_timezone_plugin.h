#ifndef FLUTTER_PLUGIN_FLUTTER_LOCAL_TIMEZONE_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_LOCAL_TIMEZONE_PLUGIN_H_

#include <windows.h>

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>

namespace flutter_local_timezone {

// Tells Dart that the device timezone changed, and nothing else.
//
// A doorbell, not a data source. The event carries no payload: Dart re-resolves
// through package:local_timezone, which owns the CLDR table that turns a
// Windows zone key into an IANA name. Sending the key across the channel would
// mean rebuilding that mapping on this side of it.
class FlutterLocalTimezonePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit FlutterLocalTimezonePlugin(
      flutter::PluginRegistrarWindows* registrar);

  virtual ~FlutterLocalTimezonePlugin();

  // Disallow copy and assign.
  FlutterLocalTimezonePlugin(const FlutterLocalTimezonePlugin&) = delete;
  FlutterLocalTimezonePlugin& operator=(const FlutterLocalTimezonePlugin&) =
      delete;

 private:
  void OnListen(
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events);
  void OnCancel();

  // Returns std::nullopt for every message, including the one it acts on. This
  // observes the window procedure rather than implementing it, and returning a
  // value would consume the message before Flutter's own handler and the other
  // registered delegates saw it.
  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::optional<int> window_proc_id_;
};

}  // namespace flutter_local_timezone

#endif  // FLUTTER_PLUGIN_FLUTTER_LOCAL_TIMEZONE_PLUGIN_H_
