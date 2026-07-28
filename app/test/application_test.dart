import 'package:adele_desktop/application.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the Phase 0 desktop shell', (WidgetTester tester) async {
    await tester.pumpWidget(const AdeleApplication());

    expect(find.text('ADELE'), findsOneWidget);
    expect(find.text('No workspace is open'), findsOneWidget);
    expect(find.text('No plugins are loaded'), findsOneWidget);
  });
}
