package com.birjuvachhani.flutter_local_timezone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

/**
 * Tells Dart that the device timezone changed, and nothing else.
 *
 * This is a doorbell, not a data source. The event carries no payload: it does
 * not report the new zone, does not read `persist.sys.timezone`, and knows
 * nothing about IANA names, aliases or CLDR. Dart resolves the zone itself
 * through `package:local_timezone`, which already does that work, has the tests
 * for it, and produces the identical answer on every platform.
 *
 * Reporting the zone from here would mean five platforms sending five different
 * string formats across the channel, and the whole canonicalization layer would
 * have to be rebuilt on this side of it, in five languages. Sending nothing
 * keeps this file the size it is.
 */
class FlutterLocalTimezonePlugin : FlutterPlugin, EventChannel.StreamHandler {

    private companion object {
        /**
         * Must match `_channelName` in `lib/src/timezone_signal.dart`.
         */
        const val CHANNEL = "com.birjuvachhani.flutter_local_timezone/changes"
    }

    private var channel: EventChannel? = null
    private var context: Context? = null
    private var receiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // The application context, not an activity's. The receiver outlives any
        // one activity, and holding an activity context in a field registered
        // for the engine's lifetime would leak it across a rotation.
        context = binding.applicationContext
        channel = EventChannel(binding.binaryMessenger, CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopWatching()
        channel?.setStreamHandler(null)
        channel = null
        context = null
    }

    /**
     * Registers the receiver when Dart starts listening.
     *
     * Deliberately bound to the subscription rather than to the engine, so that
     * an app which never adds a listener never registers a receiver. That maps
     * one to one onto `addListener` and `removeListener` on the Dart side.
     */
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        val context = this.context
        if (events == null || context == null || receiver != null) return

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                // `registerReceiver` without a Handler dispatches on the main
                // thread, which is also the platform thread, which is the only
                // thread an EventSink may be touched from. No hop needed.
                events.success(null)
            }
        }
        this.receiver = receiver

        // No RECEIVER_EXPORTED or RECEIVER_NOT_EXPORTED flag, on purpose.
        //
        // Android 13 requires one of those flags, and Android 14 makes their
        // absence fatal, but only for a receiver that is not registered
        // exclusively for system broadcasts. This filter holds exactly one
        // action and it is a protected broadcast, so the requirement does not
        // apply.
        //
        // Passing a flag anyway is not the harmless belt-and-braces it looks
        // like. AndroidX Media shipped RECEIVER_NOT_EXPORTED here and reverted
        // it, because marking a protected system broadcast as not exported
        // breaks sticky broadcast delivery in some cases.
        //
        // The consequence for anyone editing this: adding a second action to
        // the filter that is *not* a protected broadcast silently moves this
        // call into the flag-required bucket, and it will crash on Android 14
        // rather than fail to compile.
        context.registerReceiver(
            receiver,
            IntentFilter(Intent.ACTION_TIMEZONE_CHANGED),
        )
    }

    override fun onCancel(arguments: Any?) {
        stopWatching()
    }

    private fun stopWatching() {
        val receiver = this.receiver ?: return
        this.receiver = null
        context?.unregisterReceiver(receiver)
    }
}
