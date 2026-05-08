import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_models.dart';
import '../repositories/app_repositories.dart';
import '../utils/app_colors.dart';
import '../widgets/session_guard.dart';
import '../widgets/therapist_subscription_warning_dialog.dart';
import 'therapist_chat_screen.dart';

class _TherapistPlaceholderAvatar extends StatelessWidget {
  const _TherapistPlaceholderAvatar({
    required this.size,
    this.backgroundColor = const Color(0xFFDDF7E5),
    this.padding = 4,
  });

  final double size;
  final Color backgroundColor;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: backgroundColor),
      padding: EdgeInsets.all(padding),
      child: ClipOval(
        child: Image.asset('assets/images/autiease.png', fit: BoxFit.contain),
      ),
    );
  }
}

class ProfessionalSupportScreen extends StatefulWidget {
  const ProfessionalSupportScreen({super.key});

  @override
  State<ProfessionalSupportScreen> createState() =>
      _ProfessionalSupportScreenState();
}

class _ProfessionalSupportScreenState extends State<ProfessionalSupportScreen> {
  static final Set<String> _sessionSubscribedTherapistIds = <String>{};
  static final Set<String> _sessionHiddenTherapistIds = <String>{};

  final Set<String> _subscribedTherapistIds = _sessionSubscribedTherapistIds;
  final Set<String> _hiddenTherapistIds = _sessionHiddenTherapistIds;
  bool _showFindTherapist = false;
  bool _stateLoaded = false;

  void _showComingSoon() {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Coming soon')));
  }

  @override
  void initState() {
    super.initState();
    _loadPersistedTherapistState();
  }

  Future<void> _loadPersistedTherapistState() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        if (mounted) {
          setState(() => _stateLoaded = true);
        }
        return;
      }
      final doc = await FirebaseFirestore.instance
          .collection(FirestoreCollections.users)
          .doc(uid)
          .get();
      final data = doc.data();
      if (data != null) {
        final persistedSubscribed = stringListFrom(
          data['proSupportSubscribedTherapistIds'],
        );
        final persistedHidden = stringListFrom(
          data['proSupportHiddenTherapistIds'],
        );
        _subscribedTherapistIds
          ..clear()
          ..addAll(persistedSubscribed);
        _hiddenTherapistIds
          ..clear()
          ..addAll(persistedHidden);
      }
    } catch (_) {
      // Keep session state fallback even if persistence read fails.
    } finally {
      await _syncSubscribedTherapistsFromBackend();
      if (mounted) {
        setState(() => _stateLoaded = true);
      }
    }
  }

  Future<void> _persistTherapistState() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }
    await FirebaseFirestore.instance
        .collection(FirestoreCollections.users)
        .doc(uid)
        .set({
          'proSupportSubscribedTherapistIds': _subscribedTherapistIds.toList(),
          'proSupportHiddenTherapistIds': _hiddenTherapistIds.toList(),
          'proSupportUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  Future<Map<String, TherapistProfile>>
  _loadSubscribedTherapistsIncludingInactive() async {
    if (_subscribedTherapistIds.isEmpty) {
      return const <String, TherapistProfile>{};
    }
    final entries = await Future.wait(
      _subscribedTherapistIds.map((therapistId) async {
        try {
          final profile = await AppRepositories.support.getTherapistById(
            therapistId,
          );
          return MapEntry(therapistId, profile);
        } catch (_) {
          return MapEntry<String, TherapistProfile?>(therapistId, null);
        }
      }),
    );
    return {
      for (final entry in entries)
        if (entry.value != null) entry.key: entry.value!,
    };
  }

  Future<void> _syncSubscribedTherapistsFromBackend() async {
    final activeIds = await _loadActiveSubscribedTherapistIds();
    _subscribedTherapistIds
      ..clear()
      ..addAll(activeIds);
    await _persistTherapistState();
  }

  Future<Set<String>> _loadActiveSubscribedTherapistIds() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return <String>{};
    }
    final snapshot = await FirebaseFirestore.instance
        .collection(FirestoreCollections.subscriptions)
        .where('userId', isEqualTo: uid)
        .where('isActive', isEqualTo: true)
        .get();
    return snapshot.docs
        .map((doc) => (doc.data()['therapistId'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Future<bool> _openCheckoutForTherapist(TherapistProfile therapist) async {
    try {
      final subscribed = await AppRepositories.billing
          .purchaseTherapistSubscription(therapist.id);
      await _syncSubscribedTherapistsFromBackend();
      setState(() {
        _hiddenTherapistIds.remove(therapist.id);
      });

      if (!mounted) {
        return subscribed;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            subscribed
                ? 'Subscription activated.'
                : 'Checkout started. Complete payment, then tap Refresh Status if access is not updated yet.',
          ),
          backgroundColor: subscribed
              ? const Color(0xFF00C853)
              : const Color(0xFF00A63E),
        ),
      );
      return subscribed;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to start subscription: $error'),
          backgroundColor: AppColors.errorRed,
        ),
      );
      return false;
    }
  }

  Future<void> _restorePurchases() async {
    try {
      await AppRepositories.billing.syncSubscriptions();
      await _syncSubscribedTherapistsFromBackend();
      if (!mounted) {
        return;
      }
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Subscription status refreshed.'),
          backgroundColor: Color(0xFF00C853),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to restore purchases: $error'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  Future<void> _cancelTherapistSubscription(TherapistProfile therapist) async {
    try {
      await AppRepositories.billing.cancelSubscriptionInStore(therapist.id);

      if (!mounted) {
        return;
      }
      setState(() {
        _subscribedTherapistIds.remove(therapist.id);
      });
      await _persistTherapistState();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cancellation requested for ${therapist.displayName}.',
          ),
          backgroundColor: AppColors.errorRed,
        ),
      );
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

  void _openExistingThread(
    TherapistThread thread,
    TherapistProfile therapist, {
    required bool chatEnabled,
  }) {
    if (!chatEnabled) {
      _showComingSoon();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TherapistChatScreen(
          thread: thread,
          participantName: therapist.displayName,
          senderRole: 'parent',
          therapistProfile: therapist,
        ),
      ),
    );
  }

  Future<void> _openTherapistChat(
    TherapistProfile therapist, {
    required bool chatEnabled,
  }) async {
    if (!chatEnabled) {
      _showComingSoon();
      return;
    }
    try {
      final child = await AppRepositories.users
          .getActiveChildForCurrentParent();
      final subscription = await AppRepositories.billing
          .getSubscriptionForTherapist(therapist.id);
      if (!mounted) return;

      if (child == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please complete child profile before messaging.'),
            backgroundColor: AppColors.errorRed,
          ),
        );
        return;
      }

      final hasActiveSubscription = subscription?.isActive == true;
      if (!hasActiveSubscription) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please subscribe to this therapist first.'),
            backgroundColor: AppColors.errorRed,
          ),
        );
        return;
      }

      final thread = await AppRepositories.support.ensureThread(
        therapistId: therapist.id,
        childId: child.id,
        subscriptionId: hasActiveSubscription ? subscription!.id : '',
      );
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TherapistChatScreen(
            thread: thread,
            participantName: therapist.displayName,
            senderRole: 'parent',
            therapistProfile: therapist,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to open chat: $error'),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  Future<void> _openTherapistDetails(
    TherapistProfile therapist,
    bool isSubscribed,
    ProfessionalSupportFeatureFlags featureFlags,
  ) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _SupportTherapistDetailsScreen(
          therapist: therapist,
          initiallySubscribed: isSubscribed,
          chatEnabled: featureFlags.chatEnabled,
          paymentsEnabled: featureFlags.paymentsEnabled,
          onSubscribe: () => _openCheckoutForTherapist(therapist),
          onCancelSubscription: () => _cancelTherapistSubscription(therapist),
          onOpenMessages: () => _openTherapistChat(
            therapist,
            chatEnabled: featureFlags.chatEnabled,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_stateLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return SessionGuard(
      role: SessionGuardRole.parent,
      child: Scaffold(
        backgroundColor: const Color(0xFFF1F5F3),
        body: SafeArea(
          child: StreamBuilder<ProfessionalSupportFeatureFlags>(
            stream: AppRepositories.content
                .watchProfessionalSupportFeatureFlags(),
            initialData: ProfessionalSupportFeatureFlags.enabled,
            builder: (context, featureSnapshot) {
              final featureFlags =
                  featureSnapshot.data ??
                  ProfessionalSupportFeatureFlags.enabled;
              return FutureBuilder<List<Object?>>(
                future: Future.wait<Object?>([
                  AppRepositories.support.listTherapists(),
                  _loadActiveSubscribedTherapistIds(),
                  _loadSubscribedTherapistsIncludingInactive(),
                ]),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final activeTherapists =
                      snapshot.data?[0] as List<TherapistProfile>? ?? const [];
                  final activeSubscribedIds =
                      snapshot.data?[1] as Set<String>? ?? const <String>{};
                  _subscribedTherapistIds
                    ..clear()
                    ..addAll(activeSubscribedIds);
                  final subscribedTherapists =
                      snapshot.data?[2] as Map<String, TherapistProfile>? ??
                      const <String, TherapistProfile>{};
                  final therapistById = <String, TherapistProfile>{
                    for (final therapist in activeTherapists)
                      therapist.id: therapist,
                    ...subscribedTherapists,
                  };
                  final allKnownTherapists = therapistById.values.toList();

                  return Column(
                    children: [
                      _SupportHeaderCard(
                        title: _showFindTherapist
                            ? 'Find a Therapist'
                            : 'Professional Support',
                        subtitle: _showFindTherapist
                            ? 'Choose your specialist'
                            : 'Your therapist conversations',
                        onBack: () {
                          if (_showFindTherapist) {
                            setState(() => _showFindTherapist = false);
                            return;
                          }
                          Navigator.pop(context);
                        },
                        showAdd: !_showFindTherapist,
                        onAdd: () => setState(() => _showFindTherapist = true),
                      ),
                      Expanded(
                        child: _showFindTherapist
                            ? _buildFindTherapists(
                                activeTherapists,
                                featureFlags,
                              )
                            : _buildMessagesHome(
                                allKnownTherapists,
                                therapistById,
                                featureFlags.chatEnabled,
                              ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFindTherapists(
    List<TherapistProfile> therapists,
    ProfessionalSupportFeatureFlags featureFlags,
  ) {
    if (therapists.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'No therapists available yet. Add therapist profiles in Firestore to continue.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF4B5563)),
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Subscriptions are handled securely with GoPayFast checkout.',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ),
              TextButton(
                onPressed: _restorePurchases,
                child: const Text('Refresh Status'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
            itemCount: therapists.length,
            itemBuilder: (context, index) {
              final therapist = therapists[index];
              final isSubscribed = _subscribedTherapistIds.contains(
                therapist.id,
              );
              return _TherapistListCard(
                therapist: therapist,
                isSubscribed: isSubscribed,
                onTap: () => _openTherapistDetails(
                  therapist,
                  isSubscribed,
                  featureFlags,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMessagesHome(
    List<TherapistProfile> therapists,
    Map<String, TherapistProfile> therapistById,
    bool chatEnabled,
  ) {
    final subscribedVisibleIds = _subscribedTherapistIds
        .where((id) => !_hiddenTherapistIds.contains(id))
        .toSet();

    if (subscribedVisibleIds.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'No subscribed therapist yet. Tap + to find and subscribe.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF6B7280)),
          ),
        ),
      );
    }

    return StreamBuilder<List<TherapistThread>>(
      stream: AppRepositories.support.watchThreadsForRole('parent'),
      builder: (context, snapshot) {
        final backendThreads = (snapshot.data ?? const <TherapistThread>[])
            .where(
              (thread) =>
                  subscribedVisibleIds.contains(thread.therapistId) &&
                  !_hiddenTherapistIds.contains(thread.therapistId),
            )
            .toList();

        final hasThreadForTherapist = <String>{
          for (final thread in backendThreads) thread.therapistId,
        };

        final localSubscribedWithoutThread = therapists
            .where(
              (therapist) =>
                  subscribedVisibleIds.contains(therapist.id) &&
                  !hasThreadForTherapist.contains(therapist.id) &&
                  !_hiddenTherapistIds.contains(therapist.id),
            )
            .toList();

        final hasAny =
            backendThreads.isNotEmpty ||
            localSubscribedWithoutThread.isNotEmpty;
        if (!hasAny) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'No active conversation yet for subscribed therapists.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF6B7280)),
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 20),
          children: [
            for (final thread in backendThreads)
              _MessageHomeCard(
                therapistName: thread.therapistDisplayName.isNotEmpty
                    ? thread.therapistDisplayName
                    : (therapistById[thread.therapistId]?.displayName ??
                          'Therapist'),
                preview: thread.lastMessagePreview.isEmpty
                    ? "I'd recommend continuing with the communication exercises at home."
                    : thread.lastMessagePreview,
                timeLabel: _formatTime(thread.lastMessageAt),
                onTap: () {
                  final therapist = therapistById[thread.therapistId];
                  if (therapist == null) {
                    return;
                  }
                  _openExistingThread(
                    thread,
                    therapist,
                    chatEnabled: chatEnabled,
                  );
                },
              ),
            for (final therapist in localSubscribedWithoutThread)
              _MessageHomeCard(
                therapistName: therapist.displayName,
                preview:
                    "I'd recommend continuing with the communication exercises at home.",
                timeLabel: '10:40 AM',
                onTap: () =>
                    _openTherapistChat(therapist, chatEnabled: chatEnabled),
              ),
          ],
        );
      },
    );
  }

  String _formatTime(DateTime? value) {
    if (value == null) {
      return '10:40 AM';
    }
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final suffix = value.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }
}

class _SupportHeaderCard extends StatelessWidget {
  const _SupportHeaderCard({
    required this.title,
    required this.subtitle,
    this.onBack,
    this.showAdd = false,
    this.onAdd,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onBack;
  final bool showAdd;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFBDF1D0),
        borderRadius: BorderRadius.circular(2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack ?? () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back, color: Color(0xFF374151)),
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFF1F5F3),
              minimumSize: const Size(34, 34),
              shape: const CircleBorder(),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ],
            ),
          ),
          if (showAdd)
            IconButton(
              onPressed: onAdd,
              icon: const Icon(Icons.add, color: Colors.white, size: 24),
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFF00C853),
                minimumSize: const Size(34, 34),
                shape: const CircleBorder(),
              ),
            ),
        ],
      ),
    );
  }
}

class _TherapistListCard extends StatelessWidget {
  const _TherapistListCard({
    required this.therapist,
    required this.isSubscribed,
    required this.onTap,
  });

  final TherapistProfile therapist;
  final bool isSubscribed;
  final VoidCallback onTap;

  List<String> _specializations(TherapistProfile profile) {
    return profile.specializations
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  String _specialization(TherapistProfile profile) {
    final specs = _specializations(profile);
    if (specs.isNotEmpty) {
      return specs.first;
    }
    return 'Not provided';
  }

  int _yearsExp(TherapistProfile profile, int fallback) {
    if (profile.yearsOfExperience > 0) {
      return profile.yearsOfExperience;
    }
    final source = '${profile.availability} ${profile.bio}';
    final match = RegExp(r'(\d{1,2})\s*\+?\s*years?').firstMatch(source);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '') ?? fallback;
    }
    return fallback;
  }

  String _priceLabel(TherapistProfile profile) {
    final raw = profile.pricing.trim();
    if (raw.isEmpty) return '\$49.99/month';
    if (raw.toLowerCase().contains('/month')) return raw;
    return raw.contains('\$') ? '$raw/month' : '\$$raw/month';
  }

  @override
  Widget build(BuildContext context) {
    final specialization = _specialization(therapist);
    final price = _priceLabel(therapist);
    final years = _yearsExp(therapist, 0);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _TherapistPlaceholderAvatar(size: 44),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        therapist.displayName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1F2937),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        specialization,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF00A63E),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          // Hardcoded rating fallback removed for now.
                          Text(
                            years > 0
                                ? '$years years exp'
                                : 'Experience not set',
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Color(0xFF6B7280),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFF9CA3AF),
                  size: 22,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              therapist.bio.isEmpty ? 'Not provided' : therapist.bio,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                color: Color(0xFF4B5563),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    price,
                    style: const TextStyle(
                      fontSize: 18.5,
                      color: Color(0xFF111827),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isSubscribed
                        ? const Color(0xFFD4F7DA)
                        : const Color(0xFFDCE8FF),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    isSubscribed ? 'Subscribed' : 'View Details',
                    style: TextStyle(
                      color: isSubscribed
                          ? const Color(0xFF0B8F3E)
                          : const Color(0xFF4F46E5),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageHomeCard extends StatelessWidget {
  const _MessageHomeCard({
    required this.therapistName,
    required this.preview,
    required this.timeLabel,
    required this.onTap,
  });

  final String therapistName;
  final String preview;
  final String timeLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            const _TherapistPlaceholderAvatar(size: 44),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    therapistName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF1F2937),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: Color(0xFF4B5563),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              children: [
                Text(
                  timeLabel,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF6B7280),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFF00C853),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SupportTherapistDetailsScreen extends StatefulWidget {
  const _SupportTherapistDetailsScreen({
    required this.therapist,
    required this.initiallySubscribed,
    required this.chatEnabled,
    required this.paymentsEnabled,
    required this.onSubscribe,
    required this.onCancelSubscription,
    required this.onOpenMessages,
  });

  final TherapistProfile therapist;
  final bool initiallySubscribed;
  final bool chatEnabled;
  final bool paymentsEnabled;
  final Future<bool> Function() onSubscribe;
  final Future<void> Function() onCancelSubscription;
  final Future<void> Function() onOpenMessages;

  @override
  State<_SupportTherapistDetailsScreen> createState() =>
      _SupportTherapistDetailsScreenState();
}

class _SupportTherapistDetailsScreenState
    extends State<_SupportTherapistDetailsScreen> {
  late bool _isSubscribed;
  bool _isSubscribing = false;
  bool _loadingTherapistMeta = true;
  int _yearsFromProfile = 0;
  String _credentialsFromProfile = '';
  String _certificatePdfNameFromProfile = '';
  String _certificateUrlFromProfile = '';
  List<_SupportServicePackage> _packages = const <_SupportServicePackage>[];
  int _activePackageIndex = 0;

  @override
  void initState() {
    super.initState();
    _isSubscribed = widget.initiallySubscribed;
    _loadTherapistMeta();
  }

  Future<void> _loadTherapistMeta() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection(FirestoreCollections.therapistProfiles)
          .doc(widget.therapist.id)
          .get();
      final data = doc.data() ?? <String, dynamic>{};
      final parsed = _parsePackages(data['servicePackages']);
      if (!mounted) {
        return;
      }
      setState(() {
        _yearsFromProfile = intFrom(data['yearsOfExperience']);
        _credentialsFromProfile = (data['credentials'] ?? '').toString();
        _certificatePdfNameFromProfile = (data['certificatePdfName'] ?? '')
            .toString();
        _certificateUrlFromProfile = (data['certificateUrl'] ?? '').toString();
        _packages = parsed;
        _loadingTherapistMeta = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loadingTherapistMeta = false);
      }
    }
  }

  List<_SupportServicePackage> _parsePackages(dynamic raw) {
    if (raw is! List) {
      return const <_SupportServicePackage>[];
    }
    return raw
        .whereType<Map>()
        .map(
          (entry) =>
              _SupportServicePackage.fromMap(Map<String, dynamic>.from(entry)),
        )
        .toList(growable: false);
  }

  List<_SupportServicePackage> _visiblePackages(TherapistProfile profile) {
    final visible = _packages
        .where((package) => package.visible)
        .toList(growable: false);
    if (visible.isNotEmpty) {
      return visible;
    }
    final fallbackPrice = _priceLabel(profile).replaceAll('\$', '');
    final parsedPrice =
        double.tryParse(fallbackPrice.replaceAll(',', '')) ?? 49.99;
    return <_SupportServicePackage>[
      _SupportServicePackage(
        title: 'Standard Therapy Session',
        durationMinutes: 60,
        sessionsPerWeek: 3,
        price: parsedPrice,
        description:
            '1-hour therapy session including assessment, intervention, and parent consultation',
        visible: true,
      ),
    ];
  }

  int _selectedPackageIndexWithin(int count) {
    if (count <= 0) {
      return 0;
    }
    if (_activePackageIndex < 0) {
      return 0;
    }
    if (_activePackageIndex >= count) {
      return count - 1;
    }
    return _activePackageIndex;
  }

  List<String> _specializations(TherapistProfile profile) {
    return profile.specializations
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  String _specialization(TherapistProfile profile) {
    final specs = _specializations(profile);
    if (specs.isNotEmpty) {
      return specs.first;
    }
    return 'Not provided';
  }

  int _yearsExp(TherapistProfile profile) {
    if (_yearsFromProfile > 0) {
      return _yearsFromProfile;
    }
    if (profile.yearsOfExperience > 0) {
      return profile.yearsOfExperience;
    }
    final source = '${profile.availability} ${profile.bio}';
    final match = RegExp(r'(\d{1,2})\s*\+?\s*years?').firstMatch(source);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '') ?? 8;
    }
    return 0;
  }

  String _priceLabel(TherapistProfile profile) {
    final raw = profile.pricing.trim();
    final parsed = RegExp(r'(\d+[.,]?\d*)').firstMatch(raw)?.group(1);
    if (parsed == null) return '\$49.99';
    return '\$${parsed.replaceAll(',', '')}';
  }

  Future<void> _subscribe() async {
    if (!widget.paymentsEnabled) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Coming soon')));
      return;
    }
    final accepted = await showTherapistVerificationWarningDialog(context);
    if (!accepted) {
      return;
    }

    setState(() => _isSubscribing = true);
    try {
      final subscribed = await widget.onSubscribe();
      if (!mounted) return;
      setState(() {
        if (subscribed) _isSubscribed = true;
      });
    } finally {
      if (mounted) {
        setState(() => _isSubscribing = false);
      }
    }
  }

  Future<void> _openCertificate({required bool download}) async {
    final source = _certificateUrlFromProfile.trim().isNotEmpty
        ? _certificateUrlFromProfile.trim()
        : widget.therapist.certificateUrl.trim();
    await _launchCertificateLink(source, download: download);
  }

  String _certificateDisplayName({
    required String certificateName,
    required String certificateUrl,
  }) {
    final name = certificateName.trim();
    if (name.isNotEmpty) {
      return name;
    }
    if (certificateUrl.trim().isNotEmpty) {
      return 'Available via link';
    }
    return 'Not provided';
  }

  String? _normalizeCertificateUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return null;
    }
    return uri.toString();
  }

  String? _extractGoogleDriveFileId(Uri uri) {
    if (!uri.host.contains('drive.google.com')) {
      return null;
    }
    final byQuery = uri.queryParameters['id']?.trim();
    if (byQuery != null && byQuery.isNotEmpty) {
      return byQuery;
    }
    final segments = uri.pathSegments;
    for (var i = 0; i < segments.length - 1; i += 1) {
      if (segments[i] == 'd') {
        final candidate = segments[i + 1].trim();
        if (candidate.isNotEmpty) {
          return candidate;
        }
      }
    }
    return null;
  }

  Uri _certificateUriForAction(String source, {required bool download}) {
    final parsed = Uri.tryParse(source);
    if (parsed == null || !download) {
      return parsed ?? Uri();
    }
    final driveFileId = _extractGoogleDriveFileId(parsed);
    if (driveFileId == null) {
      return parsed;
    }
    return Uri.parse(
      'https://drive.google.com/uc?export=download&id=$driveFileId',
    );
  }

  Future<void> _launchCertificateLink(
    String source, {
    required bool download,
  }) async {
    if (source.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Certificate not available.')),
      );
      return;
    }
    final normalized = _normalizeCertificateUrl(source);
    if (normalized == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Invalid certificate URL.')));
      return;
    }
    final uri = _certificateUriForAction(normalized, download: download);
    final launched = await launchUrl(
      uri,
      mode: download
          ? LaunchMode.externalApplication
          : LaunchMode.platformDefault,
    );
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open certificate link.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final therapist = widget.therapist;
    final allSpecializations = _specializations(therapist);
    final specialization = _specialization(therapist);
    final packages = _visiblePackages(therapist);
    final safePackageIndex = _selectedPackageIndexWithin(packages.length);
    final selectedPackage = packages[safePackageIndex];
    final years = _yearsExp(therapist);
    final effectiveCertificateName =
        _certificatePdfNameFromProfile.trim().isNotEmpty
        ? _certificatePdfNameFromProfile
        : therapist.certificatePdfName;
    final effectiveCertificateUrl = _certificateUrlFromProfile.trim().isNotEmpty
        ? _certificateUrlFromProfile
        : therapist.certificateUrl;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F3),
      body: SafeArea(
        child: Column(
          children: [
            const _SupportHeaderCard(
              title: 'Therapist Profile',
              subtitle: 'View details',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
                children: [
                  _SupportDetailCard(
                    child: Column(
                      children: [
                        const _TherapistPlaceholderAvatar(size: 82, padding: 6),
                        const SizedBox(height: 12),
                        Text(
                          therapist.displayName,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16.9,
                            color: Color(0xFF1F2937),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          specialization,
                          style: const TextStyle(
                            color: Color(0xFF00A63E),
                            fontSize: 14,
                          ),
                        ),
                        if (allSpecializations.length > 1) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 6,
                            runSpacing: 6,
                            children: allSpecializations
                                .skip(1)
                                .map(
                                  (item) => Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFE6F3FF),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      item,
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        color: Color(0xFF2563EB),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        ],
                        const SizedBox(height: 8),
                        if (_isSubscribed) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFD4F7DA),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.check,
                                  size: 16,
                                  color: Color(0xFF0B8F3E),
                                ),
                                SizedBox(width: 5),
                                Text(
                                  'Active Subscription',
                                  style: TextStyle(
                                    color: Color(0xFF0B8F3E),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SupportDetailCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Experience & Credentials',
                          style: TextStyle(
                            fontSize: 16,
                            color: Color(0xFF1F2937),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 14),
                        _DetailLine(
                          icon: Icons.access_time_rounded,
                          title: 'Experience',
                          value: years > 0
                              ? '$years years of practice'
                              : 'Experience not set',
                        ),
                        const SizedBox(height: 10),
                        _DetailLine(
                          icon: Icons.verified_outlined,
                          title: 'Certifications',
                          value: _credentialsFromProfile.trim().isEmpty
                              ? 'Not provided'
                              : _credentialsFromProfile.trim(),
                        ),
                        const SizedBox(height: 10),
                        _DetailLine(
                          icon: Icons.picture_as_pdf_outlined,
                          title: 'Certificate PDF',
                          value: _certificateDisplayName(
                            certificateName: effectiveCertificateName,
                            certificateUrl: effectiveCertificateUrl,
                          ),
                        ),
                        if (effectiveCertificateUrl.trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _openCertificate(download: false),
                                icon: const Icon(Icons.open_in_new_rounded),
                                label: const Text('View Certificate'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _openCertificate(download: true),
                                icon: const Icon(Icons.download_rounded),
                                label: const Text('Download Certificate'),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SupportDetailCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'About',
                          style: TextStyle(
                            fontSize: 16,
                            color: Color(0xFF1F2937),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          therapist.bio.isEmpty
                              ? 'Not provided'
                              : therapist.bio,
                          style: const TextStyle(
                            color: Color(0xFF4B5563),
                            height: 1.5,
                            fontSize: 13.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00C853),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.14),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Monthly Subscription',
                          style: TextStyle(color: Colors.white, fontSize: 18),
                        ),
                        const SizedBox(height: 10),
                        if (_loadingTherapistMeta)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 26),
                            child: Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            ),
                          )
                        else
                          _PackageSwipeCard(
                            packages: packages,
                            currentIndex: safePackageIndex,
                            onPageChanged: (index) {
                              if (!mounted) {
                                return;
                              }
                              setState(() => _activePackageIndex = index);
                            },
                          ),
                        const SizedBox(height: 12),
                        Text(
                          selectedPackage.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (_isSubscribed) ...[
                          const Center(
                            child: Text(
                              'You already have an active subscription',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Center(
                            child: TextButton(
                              onPressed: widget.chatEnabled
                                  ? () => widget.onOpenMessages()
                                  : () {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Coming soon'),
                                        ),
                                      );
                                    },
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                textStyle: const TextStyle(
                                  fontSize: 12,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                              child: const Text(
                                'Go to Messages to start chatting',
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed: widget.paymentsEnabled
                                  ? () async {
                                      await widget.onCancelSubscription();
                                      if (!mounted) {
                                        return;
                                      }
                                      setState(() {
                                        _isSubscribed = false;
                                      });
                                    }
                                  : () {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Coming soon'),
                                        ),
                                      );
                                    },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: const BorderSide(
                                  color: Colors.white,
                                  width: 1.2,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 11,
                                ),
                              ),
                              child: const Text('Cancel Subscription'),
                            ),
                          ),
                        ] else
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _isSubscribing
                                  ? null
                                  : (widget.paymentsEnabled
                                        ? _subscribe
                                        : () {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text('Coming soon'),
                                              ),
                                            );
                                          }),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFF00A63E),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 13,
                                ),
                              ),
                              child: _isSubscribing
                                  ? const SizedBox(
                                      height: 16,
                                      width: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF00A63E),
                                      ),
                                    )
                                  : Text(
                                      'Subscribe ${selectedPackage.priceLabel}/month',
                                    ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (!_isSubscribed) ...[
                    const SizedBox(height: 10),
                    Text(
                      widget.paymentsEnabled
                          ? 'Secure payment powered by GoPayFast. You can manage your subscription from this app.'
                          : 'Subscriptions are currently unavailable.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PackageSwipeCard extends StatelessWidget {
  const _PackageSwipeCard({
    required this.packages,
    required this.currentIndex,
    required this.onPageChanged,
  });

  final List<_SupportServicePackage> packages;
  final int currentIndex;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 212,
          child: PageView.builder(
            onPageChanged: onPageChanged,
            itemCount: packages.length,
            itemBuilder: (context, index) {
              final package = packages[index];
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF3ACB6D),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RichText(
                      text: TextSpan(
                        text: package.priceLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 25.5,
                          fontWeight: FontWeight.w500,
                        ),
                        children: const [
                          TextSpan(
                            text: '/month',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    _FeatureLine(
                      text:
                          '${package.durationMinutes} min/session • ${package.sessionsPerWeek} sessions/week',
                    ),
                    if (package.description.trim().isNotEmpty)
                      _FeatureLine(text: package.description.trim()),
                    const _FeatureLine(
                      text: 'Unlimited messaging with therapist',
                    ),
                    const _FeatureLine(text: '24-hour response time'),
                    const _FeatureLine(text: 'Progress tracking & reports'),
                    const _FeatureLine(text: 'Cancel anytime'),
                  ],
                ),
              );
            },
          ),
        ),
        if (packages.length > 1) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List<Widget>.generate(
              packages.length,
              (index) => Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: index == currentIndex
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SupportServicePackage {
  const _SupportServicePackage({
    required this.title,
    required this.durationMinutes,
    required this.sessionsPerWeek,
    required this.price,
    required this.description,
    required this.visible,
  });

  final String title;
  final int durationMinutes;
  final int sessionsPerWeek;
  final double price;
  final String description;
  final bool visible;

  String get priceLabel => '\$${price.toStringAsFixed(price % 1 == 0 ? 0 : 2)}';

  factory _SupportServicePackage.fromMap(Map<String, dynamic> data) {
    final rawPrice = data['price'];
    final parsedPrice = rawPrice is num
        ? rawPrice.toDouble()
        : double.tryParse(rawPrice?.toString() ?? '') ?? 49.99;
    return _SupportServicePackage(
      title: (data['title'] ?? 'Therapy Package').toString(),
      durationMinutes: intFrom(data['durationMinutes'], 60),
      sessionsPerWeek: intFrom(data['sessionsPerWeek'], 3),
      price: parsedPrice,
      description: (data['description'] ?? '').toString(),
      visible: data['visible'] != false,
    );
  }
}

class _DemoTherapistChatScreen extends StatefulWidget {
  const _DemoTherapistChatScreen({
    required this.therapist,
    required this.onCancelSubscription,
  });

  final TherapistProfile therapist;
  final Future<void> Function() onCancelSubscription;

  @override
  State<_DemoTherapistChatScreen> createState() =>
      _DemoTherapistChatScreenState();
}

class _DemoTherapistChatScreenState extends State<_DemoTherapistChatScreen> {
  late final List<_DemoChatMessage> _messages = <_DemoChatMessage>[
    const _DemoChatMessage(
      text: 'Hello! How can I help you today?',
      time: '10:30 AM',
      isMine: false,
    ),
    const _DemoChatMessage(
      text: "Hi! I wanted to discuss my child\\'s progress this week.",
      time: '10:32 AM',
      isMine: true,
    ),
    const _DemoChatMessage(
      text:
          "Of course! I've noticed great improvement in social interactions. Your child has been participating more actively in group activities.",
      time: '10:35 AM',
      isMine: false,
    ),
    const _DemoChatMessage(
      text: "That\\'s wonderful to hear! Any areas we should focus on?",
      time: '10:37 AM',
      isMine: true,
    ),
    const _DemoChatMessage(
      text:
          "I\\'d recommend continuing with the communication exercises at home. The daily practice is showing excellent results!",
      time: '10:40 AM',
      isMine: false,
    ),
  ];

  bool _emergencyActive = true;

  List<String> _specializations(TherapistProfile profile) {
    return profile.specializations
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  String _specialization(TherapistProfile profile) {
    final specs = _specializations(profile);
    if (specs.isNotEmpty) {
      return specs.first;
    }
    return 'Not provided';
  }

  String _certificateDisplayName({
    required String certificateName,
    required String certificateUrl,
  }) {
    final name = certificateName.trim();
    if (name.isNotEmpty) {
      return name;
    }
    if (certificateUrl.trim().isNotEmpty) {
      return 'Available via link';
    }
    return 'Not provided';
  }

  String? _normalizeCertificateUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return null;
    }
    return uri.toString();
  }

  String? _extractGoogleDriveFileId(Uri uri) {
    if (!uri.host.contains('drive.google.com')) {
      return null;
    }
    final byQuery = uri.queryParameters['id']?.trim();
    if (byQuery != null && byQuery.isNotEmpty) {
      return byQuery;
    }
    final segments = uri.pathSegments;
    for (var i = 0; i < segments.length - 1; i += 1) {
      if (segments[i] == 'd') {
        final candidate = segments[i + 1].trim();
        if (candidate.isNotEmpty) {
          return candidate;
        }
      }
    }
    return null;
  }

  Uri _certificateUriForAction(String source, {required bool download}) {
    final parsed = Uri.tryParse(source);
    if (parsed == null || !download) {
      return parsed ?? Uri();
    }
    final driveFileId = _extractGoogleDriveFileId(parsed);
    if (driveFileId == null) {
      return parsed;
    }
    return Uri.parse(
      'https://drive.google.com/uc?export=download&id=$driveFileId',
    );
  }

  Future<void> _launchCertificateLink(
    String source, {
    required bool download,
  }) async {
    final normalized = _normalizeCertificateUrl(source);
    if (normalized == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Invalid certificate URL.')));
      return;
    }
    final uri = _certificateUriForAction(normalized, download: download);
    final launched = await launchUrl(
      uri,
      mode: download
          ? LaunchMode.externalApplication
          : LaunchMode.platformDefault,
    );
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open certificate link.')),
      );
    }
  }

  Future<void> _showTherapistProfileSheet() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        final therapist = widget.therapist;
        final yearsText = therapist.yearsOfExperience > 0
            ? '${therapist.yearsOfExperience} years of practice'
            : 'Experience not set';
        final certificateText = _certificateDisplayName(
          certificateName: therapist.certificatePdfName,
          certificateUrl: therapist.certificateUrl,
        );
        final certificateUrl = therapist.certificateUrl.trim();
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(18)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: const BoxDecoration(
                    color: Color(0xFF00C853),
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(18),
                    ),
                  ),
                  child: Stack(
                    children: [
                      Align(
                        child: Column(
                          children: [
                            const _TherapistPlaceholderAvatar(
                              size: 70,
                              backgroundColor: Color(0xFF3ACB6D),
                              padding: 5,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              therapist.displayName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 29 / 1.6,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _specialization(therapist),
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
                      Text(
                        'Experience\n$yearsText',
                        style: const TextStyle(height: 1.4),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Certificate PDF\n$certificateText',
                        style: const TextStyle(height: 1.4),
                      ),
                      if (certificateUrl.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () async {
                                await _launchCertificateLink(
                                  certificateUrl,
                                  download: false,
                                );
                              },
                              icon: const Icon(Icons.open_in_new_rounded),
                              label: const Text('View Certificate'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () async {
                                await _launchCertificateLink(
                                  certificateUrl,
                                  download: true,
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
                          onPressed: _confirmCancelSubscription,
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
          ),
        );
      },
    );
  }

  Future<void> _confirmCancelSubscription() async {
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
                      style: TextStyle(color: Colors.white, fontSize: 25 / 1.5),
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
                        'Please note: You will lose access to:\n• Direct messaging with therapist\n• 24-hour response time\n• Progress tracking & reports\n• Future session scheduling',
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

    if (shouldCancel == true) {
      await widget.onCancelSubscription();
      if (!mounted) {
        return;
      }
      Navigator.pop(context); // close profile dialog
      Navigator.pop(context); // close chat and return to messages home
    }
  }

  void _endEmergency() {
    if (!_emergencyActive) {
      return;
    }
    setState(() {
      _emergencyActive = false;
      _messages.add(
        const _DemoChatMessage(
          text: 'Emergency has been resolved. Thank you.',
          time: '6:28 PM',
          isMine: false,
        ),
      );
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Emergency ended successfully.'),
        backgroundColor: Color(0xFF00C853),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final therapist = widget.therapist;
    return Scaffold(
      backgroundColor: const Color(0xFFEFF4F1),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: const Color(0xFFBDF1D0),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(
                      Icons.arrow_back,
                      color: Color(0xFF374151),
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFFF1F5F3),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _showTherapistProfileSheet,
                    child: Row(
                      children: [
                        const _TherapistPlaceholderAvatar(
                          size: 38,
                          backgroundColor: Color(0xFF00C853),
                          padding: 3,
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              therapist.displayName,
                              style: const TextStyle(
                                fontSize: 18 / 1.2,
                                color: Color(0xFF1F2937),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              _specialization(therapist),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF4B5563),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      color: Color(0xFF00C853),
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  return Align(
                    alignment: message.isMine
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.74,
                      ),
                      decoration: BoxDecoration(
                        color: message.isMine
                            ? const Color(0xFF00C853)
                            : const Color(0xFFE5E7EB),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            message.text,
                            style: TextStyle(
                              color: message.isMine
                                  ? Colors.white
                                  : const Color(0xFF374151),
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            message.time,
                            style: TextStyle(
                              fontSize: 11,
                              color: message.isMine
                                  ? Colors.white70
                                  : const Color(0xFF6B7280),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_emergencyActive)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _endEmergency,
                      icon: const Icon(Icons.warning_amber_rounded),
                      label: const Text('End Emergency'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF3040),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DemoChatMessage {
  const _DemoChatMessage({
    required this.text,
    required this.time,
    required this.isMine,
  });

  final String text;
  final String time;
  final bool isMine;
}

class _SupportCheckoutScreen extends StatefulWidget {
  const _SupportCheckoutScreen({required this.therapist});

  final TherapistProfile therapist;

  @override
  State<_SupportCheckoutScreen> createState() => _SupportCheckoutScreenState();
}

class _SupportCheckoutScreenState extends State<_SupportCheckoutScreen> {
  final _cardController = TextEditingController(text: '1234 5678 9012 3456');
  final _expiryController = TextEditingController(text: 'MM/YY');
  final _cvcController = TextEditingController(text: '123');
  final _nameController = TextEditingController(text: 'John Doe');

  bool _processing = false;

  String _priceOnly(TherapistProfile profile) {
    final raw = profile.pricing.trim();
    final parsed = RegExp(r'(\d+[.,]?\d*)').firstMatch(raw)?.group(1);
    if (parsed == null) return '\$49.99';
    return '\$${parsed.replaceAll(',', '')}';
  }

  Future<void> _submit() async {
    if (_cardController.text.trim().isEmpty ||
        _expiryController.text.trim().isEmpty ||
        _cvcController.text.trim().isEmpty ||
        _nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please complete all payment fields.'),
          backgroundColor: AppColors.errorRed,
        ),
      );
      return;
    }

    setState(() => _processing = true);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _cardController.dispose();
    _expiryController.dispose();
    _cvcController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final therapist = widget.therapist;
    final price = _priceOnly(therapist);

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F3),
      body: SafeArea(
        child: Column(
          children: [
            const _SupportHeaderCard(
              title: 'Secure Checkout',
              subtitle: 'Complete your subscription',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
                children: [
                  _SupportDetailCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Order Summary',
                          style: TextStyle(
                            fontSize: 16,
                            color: Color(0xFF1F2937),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const _TherapistPlaceholderAvatar(
                              size: 36,
                              padding: 3,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    therapist.displayName,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      color: Color(0xFF374151),
                                    ),
                                  ),
                                  const Text(
                                    'Monthly Subscription',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF6B7280),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              price,
                              style: const TextStyle(
                                fontSize: 16.9,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF111827),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Divider(height: 1),
                        const SizedBox(height: 10),
                        _summaryRow('Subtotal', price),
                        const SizedBox(height: 6),
                        _summaryRow('Total (monthly)', price, emphasized: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SupportDetailCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.lock_outline_rounded,
                              color: Color(0xFF00A63E),
                              size: 18,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Payment Details',
                              style: TextStyle(
                                fontSize: 16,
                                color: Color(0xFF1F2937),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _labeledField('Card Number', _cardController),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _labeledField(
                                'Expiry Date',
                                _expiryController,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _labeledField('CVC', _cvcController),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _labeledField('Cardholder Name', _nameController),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _processing ? null : _submit,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00C853),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 13),
                            ),
                            child: _processing
                                ? const SizedBox(
                                    height: 16,
                                    width: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text('Pay $price/month'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F8ED),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 18,
                          color: Color(0xFF00A63E),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Secure Payment\nYour payment information is encrypted and secure. This is a demo - no real charges will be made.',
                            style: TextStyle(
                              color: Color(0xFF4B5563),
                              fontSize: 11.5,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(String label, String value, {bool emphasized = false}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: const Color(0xFF374151),
              fontSize: emphasized ? 15 : 14.5,
              fontWeight: emphasized ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: const Color(0xFF1F2937),
            fontSize: emphasized ? 15 : 14.5,
            fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _labeledField(String label, TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12.5, color: Color(0xFF4B5563)),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          style: const TextStyle(fontSize: 13.5),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: const Color(0xFFF7F9FA),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 11,
            ),
          ),
        ),
      ],
    );
  }
}

class _SupportDetailCard extends StatelessWidget {
  const _SupportDetailCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: const Color(0xFF00A63E)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF6B7280),
                ),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14.5,
                  color: Color(0xFF1F2937),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FeatureLine extends StatelessWidget {
  const _FeatureLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.check, color: Colors.white, size: 15),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}
