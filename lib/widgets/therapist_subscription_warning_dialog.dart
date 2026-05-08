import 'package:flutter/material.dart';

Future<bool> showTherapistVerificationWarningDialog(
  BuildContext context,
) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('Important Notice'),
        content: const Text(
          'AutiEase does not verify or guarantee therapist credentials, licenses, or certifications. Please independently verify the therapist\'s qualifications and certificate authenticity before making any payment.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('I Understand, Continue'),
          ),
        ],
      );
    },
  );

  return accepted == true;
}
