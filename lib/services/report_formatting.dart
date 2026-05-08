class ReportFormattingInput {
  const ReportFormattingInput({
    required this.title,
    required this.periodLabel,
    required this.childName,
    required this.generatedAt,
    required this.summary,
    required this.sections,
    required this.recommendations,
  });

  final String title;
  final String periodLabel;
  final String childName;
  final DateTime generatedAt;
  final String summary;
  final List<ReportFormattingSectionInput> sections;
  final List<String> recommendations;
}

class ReportFormattingSectionInput {
  const ReportFormattingSectionInput({
    required this.title,
    required this.percentLabel,
    required this.statusLabel,
    required this.explanation,
  });

  final String title;
  final String percentLabel;
  final String statusLabel;
  final String explanation;
}

class StructuredReportSection {
  const StructuredReportSection({
    required this.title,
    required this.percentLabel,
    required this.statusLabel,
    required this.explanation,
  });

  final String title;
  final String percentLabel;
  final String statusLabel;
  final String explanation;
}

class StructuredReportContent {
  const StructuredReportContent({
    required this.title,
    required this.periodLabel,
    required this.childName,
    required this.generatedAtLabel,
    required this.summary,
    required this.sections,
    required this.recommendations,
  });

  final String title;
  final String periodLabel;
  final String childName;
  final String generatedAtLabel;
  final String summary;
  final List<StructuredReportSection> sections;
  final List<String> recommendations;

  String toShareMessage() {
    final buffer = StringBuffer()
      ..writeln('Shared Progress Report')
      ..writeln('')
      ..writeln('Report Title: $title')
      ..writeln('Report Period: $periodLabel')
      ..writeln('Child: $childName')
      ..writeln('Generated At: $generatedAtLabel')
      ..writeln('')
      ..writeln('Summary')
      ..writeln(summary)
      ..writeln('')
      ..writeln('Progress by Section');

    for (var index = 0; index < sections.length; index += 1) {
      final section = sections[index];
      buffer
        ..writeln('${index + 1}. ${section.title}')
        ..writeln('   Progress: ${section.percentLabel}')
        ..writeln('   Status: ${section.statusLabel}')
        ..writeln('   Notes: ${section.explanation}');
    }

    buffer.writeln('');
    buffer.writeln('Recommendations');
    for (var index = 0; index < recommendations.length; index += 1) {
      buffer.writeln('${index + 1}. ${recommendations[index]}');
    }
    return buffer.toString().trim();
  }
}

class ReportFormatter {
  const ReportFormatter._();

  static StructuredReportContent build(ReportFormattingInput input) {
    final cleanSections = input.sections
        .map(
          (section) => StructuredReportSection(
            title: _normalize(section.title, fallback: 'Untitled Section'),
            percentLabel: _normalize(section.percentLabel, fallback: 'N/A'),
            statusLabel: _normalize(
              section.statusLabel,
              fallback: 'Not provided',
            ),
            explanation: _normalize(
              section.explanation,
              fallback: 'Not provided',
            ),
          ),
        )
        .toList(growable: false);

    final cleanRecommendations = input.recommendations
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);

    return StructuredReportContent(
      title: _normalize(input.title, fallback: 'Progress Report'),
      periodLabel: _normalize(input.periodLabel, fallback: 'Not provided'),
      childName: _normalize(input.childName, fallback: 'Not provided'),
      generatedAtLabel: _formatDateTime(input.generatedAt),
      summary: _normalize(input.summary, fallback: 'Not provided'),
      sections: cleanSections,
      recommendations: cleanRecommendations.isEmpty
          ? const <String>['No recommendations provided.']
          : cleanRecommendations,
    );
  }

  static String _normalize(String value, {required String fallback}) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  static String _formatDateTime(DateTime value) {
    final yyyy = value.year.toString().padLeft(4, '0');
    final mm = value.month.toString().padLeft(2, '0');
    final dd = value.day.toString().padLeft(2, '0');
    final hh = value.hour.toString().padLeft(2, '0');
    final min = value.minute.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd $hh:$min';
  }
}
