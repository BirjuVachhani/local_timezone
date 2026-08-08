#include "include/flutter_local_timezone/flutter_local_timezone_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#include <gtk/gtk.h>

// Must match `timezoneSignalChannelName` in `lib/src/timezone_signal.dart`.
#define CHANNEL_NAME "com.birjuvachhani.flutter_local_timezone/changes"

// The directory to watch, and the two children in it that name a timezone.
//
// The watch is on the directory, not on the files, and that is the single most
// important line in this file. `timedatectl set-timezone` does not edit
// /etc/localtime, it replaces it: systemd's write_data_timezone() calls
// symlink_atomic(), which creates a randomly named temporary symlink in /etc
// and renames it over the target. The original inode is never touched, so a
// monitor on /etc/localtime itself would never fire. Only the parent directory
// sees the rename.
#define WATCHED_DIRECTORY "/etc"
#define LOCALTIME_NAME "localtime"
#define TIMEZONE_NAME "timezone"

#define FLUTTER_LOCAL_TIMEZONE_PLUGIN(obj)                                   \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_local_timezone_plugin_get_type(), \
                              FlutterLocalTimezonePlugin))

// Tells Dart that the device timezone changed, and nothing else.
//
// A doorbell, not a data source. The event carries no payload: it does not read
// the symlink, resolve a zone name or know what tzdb is. Dart re-resolves
// through package:local_timezone, which already handles the four shapes
// /etc/localtime turns up in and the paths that are not zones at all.
//
// Linux is the one platform with no timezone change notification of any kind.
// There is no signal to subscribe to, so this infers one: the kernel reports a
// directory entry changing and we take that as a hint worth re-reading on.
// D-Bus is not a better answer. org.freedesktop.timedate1 exposes a Timezone
// property, but timedated reads it once at startup and does not watch the file,
// so it can report a stale zone while the symlink is already correct.
struct _FlutterLocalTimezonePlugin {
  GObject parent_instance;

  // Owned. See the note in the registrar function about the reference cycle.
  FlEventChannel* channel;

  // Non-null only while Dart is listening.
  GFileMonitor* monitor;
};

G_DEFINE_TYPE(FlutterLocalTimezonePlugin, flutter_local_timezone_plugin,
              g_object_get_type())

// Whether a reported path is one of the two that name a timezone.
//
// Needed because /etc is a busy directory, and because the atomic replace above
// also reports the randomly named temporary that only exists for one syscall.
static gboolean names_a_timezone(GFile* file) {
  if (file == nullptr) {
    return FALSE;
  }
  g_autofree gchar* name = g_file_get_basename(file);
  return g_strcmp0(name, LOCALTIME_NAME) == 0 ||
         g_strcmp0(name, TIMEZONE_NAME) == 0;
}

static void directory_changed_cb(GFileMonitor* monitor, GFile* file,
                                 GFile* other_file,
                                 GFileMonitorEvent event_type,
                                 gpointer user_data) {
  FlutterLocalTimezonePlugin* self = FLUTTER_LOCAL_TIMEZONE_PLUGIN(user_data);

  // Both, because a rename reports the old name in `file` and the new one in
  // `other_file`, and which of the two is `localtime` depends on the direction.
  if (!names_a_timezone(file) && !names_a_timezone(other_file)) {
    return;
  }

  // Every event type is treated the same, including DELETED. The zone becoming
  // unresolvable is a change like any other, and Dart reports it as one.
  //
  // One `set-timezone` produces several of these: a CREATE for the temporary
  // and a RENAMED for the replacement, at least. They are not coalesced here.
  // Dart compares the resolved zone against the last one, so the second and
  // subsequent events cost one lookup each and dispatch nothing.
  g_autoptr(FlValue) nothing = fl_value_new_null();
  fl_event_channel_send(self->channel, nothing, nullptr, nullptr);
}

static void stop_watching(FlutterLocalTimezonePlugin* self) {
  if (self->monitor == nullptr) {
    return;
  }
  g_signal_handlers_disconnect_by_data(self->monitor, self);
  g_file_monitor_cancel(self->monitor);
  g_clear_object(&self->monitor);
}

// Starts watching when Dart starts listening.
//
// Deliberately bound to the subscription rather than to registration, so that
// an app which never adds a listener never holds an inotify watch. That maps
// one to one onto `addListener` and `removeListener` on the Dart side.
static FlMethodErrorResponse* listen_cb(FlEventChannel* channel, FlValue* args,
                                        gpointer user_data) {
  FlutterLocalTimezonePlugin* self = FLUTTER_LOCAL_TIMEZONE_PLUGIN(user_data);
  if (self->monitor != nullptr) {
    return nullptr;
  }

  g_autoptr(GFile) directory = g_file_new_for_path(WATCHED_DIRECTORY);
  g_autoptr(GError) error = nullptr;

  // G_FILE_MONITOR_WATCH_MOVES is what turns the create-then-rename above into
  // a RENAMED event carrying both names. Without it the same replacement
  // arrives as an unrelated DELETED and CREATED pair, which still works but
  // reports the temporary file as if it mattered.
  self->monitor = g_file_monitor_directory(
      directory, G_FILE_MONITOR_WATCH_MOVES, nullptr, &error);

  if (self->monitor == nullptr) {
    // Reaching here means the zone can still be read, just not watched. A
    // read-only or overlay-mounted /etc is the realistic cause, which is a
    // container rather than a desktop. The Dart side keeps its app lifecycle
    // leg either way, so this degrades rather than breaks.
    return fl_method_error_response_new(
        "watch-failed",
        error != nullptr ? error->message : "could not watch " WATCHED_DIRECTORY,
        nullptr);
  }

  // The `changed` signal is emitted in the thread-default main context of the
  // thread that created the monitor. This runs on the platform thread, where
  // GTK's main loop is, which is also the only thread an FlEventChannel may be
  // sent on. Creating the monitor anywhere else would break that.
  g_signal_connect(self->monitor, "changed", G_CALLBACK(directory_changed_cb),
                   self);
  return nullptr;
}

static FlMethodErrorResponse* cancel_cb(FlEventChannel* channel, FlValue* args,
                                        gpointer user_data) {
  stop_watching(FLUTTER_LOCAL_TIMEZONE_PLUGIN(user_data));
  return nullptr;
}

static void flutter_local_timezone_plugin_dispose(GObject* object) {
  FlutterLocalTimezonePlugin* self = FLUTTER_LOCAL_TIMEZONE_PLUGIN(object);
  stop_watching(self);
  g_clear_object(&self->channel);
  G_OBJECT_CLASS(flutter_local_timezone_plugin_parent_class)->dispose(object);
}

static void flutter_local_timezone_plugin_class_init(
    FlutterLocalTimezonePluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_local_timezone_plugin_dispose;
}

static void flutter_local_timezone_plugin_init(
    FlutterLocalTimezonePlugin* self) {}

void flutter_local_timezone_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  FlutterLocalTimezonePlugin* plugin = FLUTTER_LOCAL_TIMEZONE_PLUGIN(
      g_object_new(flutter_local_timezone_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel =
      fl_event_channel_new(fl_plugin_registrar_get_messenger(registrar),
                           CHANNEL_NAME, FL_METHOD_CODEC(codec));

  // This creates a reference cycle on purpose: the plugin owns the channel, and
  // the channel's stream handlers own a reference back to the plugin. Neither
  // is ever collected, so `dispose` above does not in practice run.
  //
  // The alternative is a non-owning pointer to the channel, which trades a
  // bounded leak for a dangling pointer if the messenger ever drops it first.
  // One plugin object per engine, for the life of the engine, is the cheaper
  // mistake of the two.
  fl_event_channel_set_stream_handlers(plugin->channel, listen_cb, cancel_cb,
                                       g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
