#include "flutter_local_timezone_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <utility>

namespace flutter_local_timezone {

namespace {

// Must match `timezoneSignalChannelName` in `lib/src/timezone_signal.dart`.
constexpr char kChannelName[] =
    "com.birjuvachhani.flutter_local_timezone/changes";

}  // namespace

// static
void FlutterLocalTimezonePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<FlutterLocalTimezonePlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

FlutterLocalTimezonePlugin::FlutterLocalTimezonePlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  auto handler = std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [this](const flutter::EncodableValue* arguments,
             std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                 events)
          -> std::unique_ptr<
              flutter::StreamHandlerError<flutter::EncodableValue>> {
        OnListen(std::move(events));
        return nullptr;
      },
      [this](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<
              flutter::StreamHandlerError<flutter::EncodableValue>> {
        OnCancel();
        return nullptr;
      });

  channel_->SetStreamHandler(std::move(handler));
}

FlutterLocalTimezonePlugin::~FlutterLocalTimezonePlugin() { OnCancel(); }

// Starts observing when Dart starts listening.
//
// Deliberately bound to the subscription rather than to registration, so that
// an app which never adds a listener never installs a window procedure
// delegate. That maps one to one onto `addListener` and `removeListener` on the
// Dart side.
void FlutterLocalTimezonePlugin::OnListen(
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  event_sink_ = std::move(events);
  if (window_proc_id_.has_value()) {
    return;
  }
  window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam,
             LPARAM lparam) -> std::optional<LRESULT> {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
}

void FlutterLocalTimezonePlugin::OnCancel() {
  if (window_proc_id_.has_value()) {
    registrar_->UnregisterTopLevelWindowProcDelegate(*window_proc_id_);
    window_proc_id_ = std::nullopt;
  }
  event_sink_ = nullptr;
}

std::optional<LRESULT> FlutterLocalTimezonePlugin::HandleWindowProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  // WM_TIMECHANGE, and only WM_TIMECHANGE.
  //
  // The system broadcasts it to every top-level window when the system clock or
  // the time zone moves, which is what `SystemEvents.TimeChanged` wraps in .NET
  // and what everything from `tzutil /s` to the Settings app ends up producing,
  // since they all route through `SetDynamicTimeZoneInformation`. A clock
  // change with no zone change also lands here, and the Dart side absorbs it:
  // the resolved zone is unchanged, so no event is dispatched.
  //
  // WM_SETTINGCHANGE is deliberately not handled. Microsoft's guidance names it
  // for the app *performing* a change to notify Explorer, not for the system to
  // announce one, and it fires for locale, policy and environment edits that
  // have nothing to do with time. Handling it would add frequent redundant
  // lookups to catch a case WM_TIMECHANGE already covers.
  //
  // This delegate sees every message the window receives, so keep the test
  // ahead of any work.
  if (message == WM_TIMECHANGE && event_sink_) {
    event_sink_->Success();
  }

  // Never consume. See the header.
  return std::nullopt;
}

}  // namespace flutter_local_timezone
