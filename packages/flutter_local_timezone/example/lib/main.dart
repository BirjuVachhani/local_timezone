// An app that shows the device's timezone and logs every change to it.
//
// Change the zone in the device's own settings while this is running. The
// heading updates, the listenable rebuilds, and a row is appended to the log.
// Nothing here polls, and nothing is awaited: reading is synchronous on every
// platform, so `build` can call it directly.

import 'package:flutter/material.dart';
import 'package:flutter_local_timezone/flutter_local_timezone.dart';

void main() {
  // A listener can also be registered here, before `runApp`, which is what an
  // app that reacts to the zone globally rather than in one widget should do:
  //
  //     LocalTimezoneWatcher.addListener(applyZone);
  //
  // `addListener` initializes the binding itself if nothing else has.
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'flutter_local_timezone',
    theme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.light,
    ),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Newest first, so the interesting end of the log is the visible one.
  final List<_LoggedEvent> _events = [];

  @override
  void initState() {
    super.initState();
    // Starting the watcher does not call the listener. The first resolve is the
    // baseline to compare against, and reporting the zone the device is already
    // in as a change would be a lie. So the heading below reads the zone
    // itself rather than waiting for an event that is not coming.
    LocalTimezoneWatcher.addListener(_onTimezoneEvent);
  }

  @override
  void dispose() {
    // The watcher is static and holds platform resources: a channel
    // subscription, a broadcast receiver on Android, a lifecycle observer. All
    // of it is released when the last listener goes, and this is the only place
    // that can happen for this listener.
    LocalTimezoneWatcher.removeListener(_onTimezoneEvent);
    super.dispose();
  }

  void _onTimezoneEvent(LocalTimezoneEvent event) {
    setState(() {
      _events.insert(0, _LoggedEvent(event, DateTime.now()));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('flutter_local_timezone'),
        actions: [
          IconButton(
            tooltip: 'Read the platform again',
            icon: const Icon(Icons.refresh),
            // Nothing is cached, so re-reading is all a refresh needs to be.
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _Section(
            title: 'Current timezone',
            subtitle: 'LocalTimezone.getTimeZone(), read during build',
            child: _CurrentTimezone(),
          ),
          const SizedBox(height: 16),
          const _Section(
            title: 'As a listenable',
            subtitle:
                'LocalTimezoneWatcher.listenable, for widgets that '
                'should rebuild on a change',
            child: _WatchedTimezone(),
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Change events',
            subtitle: _events.isEmpty
                ? 'Change the timezone in the device settings to see one'
                : '${_events.length} so far, newest first',
            child: _EventLog(events: _events),
          ),
        ],
      ),
    );
  }
}

/// Reads the zone and shows all three identifier layers.
///
/// The switch is over a sealed type, so both shapes a platform can report are
/// handled with no default branch and no chance of forgetting one.
class _CurrentTimezone extends StatelessWidget {
  const _CurrentTimezone();

  @override
  Widget build(BuildContext context) {
    try {
      return switch (LocalTimezone.getTimeZone()) {
        // `canonicalized` is the current primary IANA spelling and the field to
        // hand to a timezone database. `name` is the platform's own spelling,
        // parsed but not corrected, and `raw` is exactly what it said: a
        // registry key on Windows, a symlink path on Linux.
        NamedLocalTimezone(:final raw, :final name, :final canonicalized) =>
          _Fields({'canonicalized': canonicalized, 'name': name, 'raw': raw}),
        // No IANA zone is configured, so there are no daylight saving rules
        // available. Correct right now, not safe for arithmetic across a DST
        // boundary.
        OffsetLocalTimezone(:final raw, :final iso8601, :final offset) =>
          _Fields({
            'fixed offset': iso8601,
            'as a Duration': '$offset',
            'raw': raw,
          }),
      };
    } on LocalTimezoneException catch (error) {
      // Failure is an exception rather than a silent fallback to UTC, because a
      // quietly wrong timezone surfaces much later as corrupted timestamps.
      return _Fields({
        'error': switch (error) {
          LocalTimezoneUnavailableException(:final platform, :final reason) =>
            'no timezone on $platform: $reason',
          // Unreachable from `getTimeZone`, which returns the offset instead of
          // throwing. Only `getTimeZoneName` can produce this.
          LocalTimezoneNotNamedException(:final resolved) =>
            'only an offset available: ${resolved.iso8601}',
        },
      });
    }
  }
}

/// Rebuilds itself whenever the device moves to a different zone.
///
/// Attaching to `listenable` starts the watcher exactly as `addListener` does,
/// so a widget tree that only ever uses this never touches `addListener`.
class _WatchedTimezone extends StatelessWidget {
  const _WatchedTimezone();

  @override
  Widget build(BuildContext context) {
    final listenable = LocalTimezoneWatcher.listenable;
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) => _Fields({
        'value': switch (listenable.value) {
          NamedLocalTimezone(:final canonicalized) => canonicalized,
          OffsetLocalTimezone(:final iso8601) => iso8601,
          // Either nothing is watching yet or no zone could be resolved. Which
          // one is told apart by whether anything is listening.
          null => 'unresolved',
        },
      }),
    );
  }
}

class _EventLog extends StatelessWidget {
  const _EventLog({required this.events});

  final List<_LoggedEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Text(
        'A daylight saving transition is deliberately not an event: it changes '
        'the offset in effect but no field of the zone. Spurious platform '
        'signals are absorbed the same way, by comparing the resolved value.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final logged in events)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _Fields({
              _formatTime(logged.at): switch (logged.event) {
                LocalTimezoneChanged(:final timezone) => switch (timezone) {
                  NamedLocalTimezone(:final canonicalized) => canonicalized,
                  OffsetLocalTimezone(:final iso8601) => iso8601,
                },
                // A re-resolve that used to succeed now throws. Sent only on
                // the transition into that state.
                LocalTimezoneUnavailable(:final exception) => exception.message,
              },
            }),
          ),
      ],
    );
  }

  static String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}

class _LoggedEvent {
  const _LoggedEvent(this.event, this.at);

  final LocalTimezoneEvent event;
  final DateTime at;
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 20),
            child,
          ],
        ),
      ),
    );
  }
}

/// A label and value per row, monospaced, so identifiers line up.
class _Fields extends StatelessWidget {
  const _Fields(this.values);

  final Map<String, String> values;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final MapEntry(key: label, value: value) in values.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    value,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Menlo', 'Courier New'],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
