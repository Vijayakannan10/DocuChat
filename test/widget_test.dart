import 'package:flutter_test/flutter_test.dart';
import 'package:docuchat/main.dart';

void main() {
  testWidgets('DocuChat splash screen loads', (WidgetTester tester) async {
    await tester.pumpWidget(const DocuChatApp());

    // Check the initial splash screen.
    expect(find.text('DocuChat'), findsOneWidget);
    expect(find.text('Talk to Any PDF'), findsOneWidget);

    // Complete the splash timer so no pending timer remains.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
  });
}
