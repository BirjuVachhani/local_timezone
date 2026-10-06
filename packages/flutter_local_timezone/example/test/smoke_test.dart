import 'package:flutter_local_timezone/flutter_local_timezone.dart';
import 'package:flutter_local_timezone_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the resolved zone', (tester) async {
    LocalTimezone.setMockValue(
      const NamedLocalTimezone(
        name: 'Asia/Calcutta',
        canonicalized: 'Asia/Kolkata',
        raw: 'India Standard Time',
      ),
    );
    addTearDown(LocalTimezone.clearMock);
    addTearDown(LocalTimezoneWatcher.debugReset);

    await tester.pumpWidget(const ExampleApp());

    expect(find.text('Asia/Kolkata'), findsNWidgets(2));
    expect(find.text('Asia/Calcutta'), findsOneWidget);
    expect(find.text('India Standard Time'), findsOneWidget);
  });
}
