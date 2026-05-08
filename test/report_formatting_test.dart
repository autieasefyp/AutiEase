import 'package:autiease/services/report_formatting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReportFormatter', () {
    test(
      'builds structured therapist share message with all required sections',
      () {
        final content = ReportFormatter.build(
          ReportFormattingInput(
            title: 'Weekly Progress Report',
            periodLabel: 'Apr 1 - Apr 7, 2026',
            childName: 'Noah',
            generatedAt: DateTime(2026, 5, 8, 14, 30),
            summary: 'Steady progress with consistent daily activity.',
            sections: const [
              ReportFormattingSectionInput(
                title: 'Move & Play',
                percentLabel: '70%',
                statusLabel: 'On Track',
                explanation: 'Completed gross motor exercises.',
              ),
              ReportFormattingSectionInput(
                title: 'Talk & Express',
                percentLabel: '60%',
                statusLabel: 'Improving',
                explanation: 'Needs guided repetition for pronunciation.',
              ),
            ],
            recommendations: const [
              'Continue daily speech practice.',
              'Increase guided play sessions.',
            ],
          ),
        );

        final message = content.toShareMessage();

        expect(message, contains('Shared Progress Report'));
        expect(message, contains('Report Title: Weekly Progress Report'));
        expect(message, contains('Report Period: Apr 1 - Apr 7, 2026'));
        expect(message, contains('Child: Noah'));
        expect(message, contains('Generated At: 2026-05-08 14:30'));
        expect(message, contains('Summary'));
        expect(message, contains('Progress by Section'));
        expect(message, contains('1. Move & Play'));
        expect(message, contains('Progress: 70%'));
        expect(message, contains('Status: On Track'));
        expect(message, contains('Notes: Completed gross motor exercises.'));
        expect(message, contains('Recommendations'));
        expect(message, contains('1. Continue daily speech practice.'));
        expect(message, contains('2. Increase guided play sessions.'));
      },
    );
  });
}
