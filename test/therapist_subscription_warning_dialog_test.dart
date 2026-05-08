import 'package:autiease/widgets/therapist_subscription_warning_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('showTherapistVerificationWarningDialog', () {
    testWidgets('returns false when user cancels', (tester) async {
      final result = ValueNotifier<bool?>(null);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () async {
                    result.value = await showTherapistVerificationWarningDialog(
                      context,
                    );
                  },
                  child: const Text('Open Warning'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Warning'));
      await tester.pumpAndSettle();

      expect(find.text('Important Notice'), findsOneWidget);
      expect(
        find.textContaining(
          'AutiEase does not verify or guarantee therapist credentials',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result.value, isFalse);
    });

    testWidgets('returns true when user confirms', (tester) async {
      final result = ValueNotifier<bool?>(null);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () async {
                    result.value = await showTherapistVerificationWarningDialog(
                      context,
                    );
                  },
                  child: const Text('Open Warning'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Warning'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('I Understand, Continue'));
      await tester.pumpAndSettle();

      expect(result.value, isTrue);
    });
  });
}
