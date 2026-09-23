import 'package:flutter_test/flutter_test.dart';

import 'package:bags/main.dart';

void main() {
  testWidgets('MainApp renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MainApp());
    expect(find.text('Hello World!'), findsOneWidget);
  });
}
