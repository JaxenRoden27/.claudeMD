import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:claude_md_final/main.dart';

void main() {
  testWidgets('launch screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
