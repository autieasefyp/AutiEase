import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_models.dart';
import '../repositories/app_repositories.dart';
import '../utils/app_colors.dart';
import '../widgets/session_guard.dart';

class _TherapistPlaceholderAvatar extends StatelessWidget {
  const _TherapistPlaceholderAvatar({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Color(0xFF3ACB6D),
        shape: BoxShape.circle,
      ),
      padding: const EdgeInsets.all(5),
      child: ClipOval(
        child: Image.asset('assets/images/autiease.png', fit: BoxFit.contain),
      ),
    );
  }
}

class TherapistChatScreen extends StatefulWidget {
  const TherapistChatScreen({
    super.key,
    required this.thread,
    required this.participantName,
    required this.senderRole,
    this.readOnly = false,
    this.therapistProfile,
  });

  final TherapistThread thread;
  final String participantName;
  final String senderRole;
  final bool readOnly;
  final TherapistProfile? therapistProfile;

  @override
  State<TherapistChatScreen> createState() => _TherapistChatScreenState();
}

enum _MessageSendState { idle, sending, sent, error }

class _TherapistChatScreenState extends State<TherapistChatScreen> {
  final TextEditingController _controller = TextEditingController();
  _MessageSendState _sendState = _MessageSendState.idle;
  String? _sendError;
  Timer? _resolvedBannerTimer;
  DateTime? _lastResolvedAtSeen;
  bool _showResolvedBanner = false;

  void _syncResolvedBanner(TherapistThread thread) {
    final respondedAt = thread.emergencyRespondedAt;
    if (!thread.emergencyResponded || respondedAt == null) {
      _resolvedBannerTimer?.cancel();
      _resolvedBannerTimer = null;
      _lastResolvedAtSeen = null;
      if (_showResolvedBanner) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() => _showResolvedBanner = false);
          }
        });
      }
      return;
    }

    final isSameEvent = _lastResolvedAtSeen == respondedAt;
    // Do not retrigger banner for the same resolved event on rebuilds.
    if (isSameEvent) {
      return;
    }

    _lastResolvedAtSeen = respondedAt;
    _resolvedBannerTimer?.cancel();

    if (!_showResolvedBanner) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _showResolvedBanner = true);
        }
      });
    }

    _resolvedBannerTimer = Timer(const Duration(minutes: 1), () {
      if (mounted) {
        setState(() => _showResolvedBanner = false);
      }
    });
  }

  bool _canSendMessage(TherapistThread thread) {
    if (widget.readOnly) {
      return false;
    }
    if (widget.senderRole == 'parent') {
      return thread.status == 'active' && thread.postCancelVisible;
    }
    return true;
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sendState == _MessageSendState.sending) {
      return;
    }
    setState(() {
      _sendState = _MessageSendState.sending;
      _sendError = null;
    });
    try {
      _controller.clear();
      await AppRepositories.support.sendMessage(
        threadId: widget.thread.id,
        senderRole: widget.senderRole,
        body: text,
      );
      if (!mounted) {
        return;
      }
      setState(() => _sendState = _MessageSendState.sent);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _sendState = _MessageSendState.error;
        _sendError = error.toString();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to send message: $error'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    } finally {
      if (mounted) {
        if (_sendState == _MessageSendState.sent) {
          Future<void>.delayed(const Duration(seconds: 2), () {
            if (mounted) {
              setState(() => _sendState = _MessageSendState.idle);
            }
          });
        }
      }
    }
  }

  Future<void> _requestEmergency() async {
    try {
      await AppRepositories.support.requestEmergency(
        threadId: widget.thread.id,
        requestedByRole: widget.senderRole,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Emergency request sent to therapist.'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to request emergency support: $error'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  Future<void> _resolveEmergency() async {
    try {
      await AppRepositories.support.resolveEmergency(
        threadId: widget.thread.id,
        resolvedByRole: widget.senderRole,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Emergency response sent.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to respond to emergency: $error'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  Future<void> _endEmergency() async {
    await _resolveEmergency();
  }

  Future<void> _persistHiddenTherapist(String therapistId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }
    final ref = FirebaseFirestore.instance
        .collection(FirestoreCollections.users)
        .doc(uid);
    final doc = await ref.get();
    final data = doc.data() ?? <String, dynamic>{};
    final subscribed = stringListFrom(data['proSupportSubscribedTherapistIds'])
      ..remove(therapistId);
    final hidden = stringListFrom(data['proSupportHiddenTherapistIds']);
    if (!hidden.contains(therapistId)) {
      hidden.add(therapistId);
    }
    await ref.set({
      'proSupportSubscribedTherapistIds': subscribed,
      'proSupportHiddenTherapistIds': hidden,
      'proSupportUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _confirmCancelSubscription(TherapistProfile therapist) async {
    final shouldCancel = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                decoration: const BoxDecoration(
                  color: Color(0xFFFF3040),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                ),
                child: const Column(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.white,
                      size: 46,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Cancel Subscription?',
                      style: TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: Column(
                  children: [
                    const Text(
                      'Are you sure you want to cancel your subscription?',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF374151)),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF5DD),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        'Please note: You will lose access to:\n- Direct messaging with therapist\n- 24-hour response time\n- Progress tracking & reports\n- Future session scheduling',
                        style: TextStyle(
                          height: 1.45,
                          color: Color(0xFF4B5563),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: () => Navigator.pop(context, false),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFE5E7EB),
                              foregroundColor: const Color(0xFF374151),
                            ),
                            child: const Text('Keep Subscription'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFFF3040),
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('Yes, Cancel'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

    if (shouldCancel != true) {
      return;
    }

    try {
      final subscriptionId = widget.thread.subscriptionId.trim();
      final canCallPaymentBackend =
          AppRepositories.paymentBackend.isConfigured &&
          subscriptionId.isNotEmpty;

      if (canCallPaymentBackend) {
        try {
          await AppRepositories.billing.cancelSubscription(subscriptionId);
        } catch (error) {
          final message = error.toString();
          final backendNotConfigured =
              message.contains('Payment backend is not configured') ||
              message.contains('PAYMENT_BACKEND_BASE_URL');
          if (!backendNotConfigured) {
            rethrow;
          }
          // In local/demo mode, proceed with in-app cancellation state.
        }
      }

      await _persistHiddenTherapist(widget.thread.therapistId);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Subscription canceled.'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context); // close therapist detail dialog
      Navigator.pop(context); // back to messages home
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to cancel subscription: $error'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  Future<void> _openTherapistDetails() async {
    final therapist = widget.therapistProfile;
    if (therapist == null) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        final specialization = therapist.specializations.isNotEmpty
            ? therapist.specializations.first
            : 'Not provided';
        final yearsText = therapist.yearsOfExperience > 0
            ? '${therapist.yearsOfExperience} years of practice'
            : 'Experience not set';
        final certificateText = therapist.certificatePdfName.trim().isEmpty
            ? 'Not provided'
            : therapist.certificatePdfName.trim();
        final certificateUrl = therapist.certificateUrl.trim();
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: const BoxDecoration(
                  color: Color(0xFF00C853),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                ),
                child: Stack(
                  children: [
                    Align(
                      child: Column(
                        children: [
                          const _TherapistPlaceholderAvatar(size: 70),
                          const SizedBox(height: 10),
                          Text(
                            therapist.displayName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            specialization,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: Colors.white),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0x334B5563),
                          minimumSize: const Size(32, 32),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Hardcoded rating/reviews removed for now.
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    const SizedBox(height: 10),
                    Text('Experience\n$yearsText'),
                    const SizedBox(height: 10),
                    Text('Certificate PDF\n$certificateText'),
                    if (certificateUrl.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () async {
                              final uri = Uri.tryParse(certificateUrl);
                              if (uri == null) {
                                return;
                              }
                              await launchUrl(
                                uri,
                                mode: LaunchMode.platformDefault,
                              );
                            },
                            icon: const Icon(Icons.open_in_new_rounded),
                            label: const Text('View Certificate'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final uri = Uri.tryParse(certificateUrl);
                              if (uri == null) {
                                return;
                              }
                              await launchUrl(
                                uri,
                                mode: LaunchMode.externalApplication,
                              );
                            },
                            icon: const Icon(Icons.download_rounded),
                            label: const Text('Download Certificate'),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    const Divider(height: 1),
                    const SizedBox(height: 10),
                    const Text(
                      'About',
                      style: TextStyle(
                        color: Color(0xFF4B5563),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      therapist.bio.isEmpty ? 'Not provided' : therapist.bio,
                      style: const TextStyle(height: 1.4),
                    ),
                    const SizedBox(height: 10),
                    const Center(
                      child: Text(
                        '- Active now',
                        style: TextStyle(color: Color(0xFF00A63E)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _confirmCancelSubscription(therapist),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('Cancel Subscription'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF3040),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _resolvedBannerTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SessionGuard(
      role: SessionGuardRole.authenticated,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.participantName),
          backgroundColor: AppColors.primaryBlue,
          foregroundColor: Colors.white,
          actions: [
            if (widget.therapistProfile != null)
              IconButton(
                onPressed: _openTherapistDetails,
                icon: const Icon(Icons.info_outline),
              ),
          ],
        ),
        body: StreamBuilder<TherapistThread?>(
          stream: AppRepositories.support.watchThread(widget.thread.id),
          builder: (context, threadSnapshot) {
            final thread = threadSnapshot.data ?? widget.thread;
            _syncResolvedBanner(thread);
            final canSendMessage = _canSendMessage(thread);
            return Column(
              children: [
                if (widget.readOnly)
                  const _ChatStateBanner(
                    text:
                        'Read-only mode: this conversation remains visible, but new parent messages require an active subscription.',
                    color: Color(0xFFF2E8C6),
                  ),
                if (thread.hasOpenEmergency)
                  _ChatStateBanner(
                    text: thread.emergencyRequestedBy == 'parent'
                        ? 'Emergency requested by parent.'
                        : 'Emergency requested by therapist.',
                    color: const Color(0xFFFFD9D9),
                  )
                else if (_showResolvedBanner)
                  const _ChatStateBanner(
                    text: 'Emergency response has been recorded.',
                    color: Color(0xFFD8F4DD),
                  ),
                Expanded(
                  child: StreamBuilder<List<TherapistMessage>>(
                    stream: AppRepositories.support.watchMessages(
                      widget.thread.id,
                    ),
                    builder: (context, snapshot) {
                      final messages = snapshot.data ?? const [];
                      if (snapshot.connectionState == ConnectionState.waiting &&
                          messages.isEmpty) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (messages.isEmpty) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No messages yet. Start the conversation to get professional support.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final message = messages[index];
                          if (message.messageType == 'system') {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE9EEF6),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    message.body,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF334A6E),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }
                          final isMine =
                              message.senderRole == widget.senderRole;
                          return Align(
                            alignment: isMine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(14),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.75,
                              ),
                              decoration: BoxDecoration(
                                color: isMine
                                    ? AppColors.primaryBlue
                                    : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Text(
                                message.body,
                                style: TextStyle(
                                  color: isMine ? Colors.white : Colors.black87,
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.senderRole == 'parent' &&
                            !thread.hasOpenEmergency &&
                            canSendMessage)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: OutlinedButton.icon(
                              onPressed: _requestEmergency,
                              icon: const Icon(
                                Icons.warning_amber_rounded,
                                color: AppColors.errorRed,
                              ),
                              label: const Text('Request emergency support'),
                            ),
                          ),
                        if (thread.hasOpenEmergency)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ElevatedButton.icon(
                              onPressed: _endEmergency,
                              icon: const Icon(
                                Icons.health_and_safety_outlined,
                              ),
                              label: const Text('End emergency'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                        if (!canSendMessage)
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF7F7F7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              'Messaging is currently disabled for this conversation state.',
                              style: TextStyle(color: Colors.black54),
                            ),
                          )
                        else
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _controller,
                                  decoration: InputDecoration(
                                    hintText: 'Send a message',
                                    filled: true,
                                    fillColor: const Color(0xFFF1F5F9),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(18),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              FloatingActionButton(
                                onPressed:
                                    _sendState == _MessageSendState.sending
                                    ? null
                                    : _sendMessage,
                                backgroundColor: AppColors.primaryBlue,
                                foregroundColor: Colors.white,
                                child: _sendState == _MessageSendState.sending
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.send),
                              ),
                            ],
                          ),
                        if (_sendState == _MessageSendState.sending)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'Sending message...',
                              style: TextStyle(
                                color: AppColors.primaryBlue,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        if (_sendState == _MessageSendState.sent)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'Message sent',
                              style: TextStyle(
                                color: Colors.green,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        if (_sendState == _MessageSendState.error)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _sendError ?? 'Message failed',
                              style: const TextStyle(
                                color: AppColors.errorRed,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ChatStateBanner extends StatelessWidget {
  const _ChatStateBanner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          color: Color(0xFF223651),
        ),
      ),
    );
  }
}
