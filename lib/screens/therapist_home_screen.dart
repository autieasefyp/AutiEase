import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_models.dart';
import '../repositories/app_repositories.dart';
import '../services/firebase_service.dart';
import '../utils/responsive.dart';
import '../widgets/session_guard.dart';
import 'about_application_screen.dart';
import 'login_screen.dart';
import 'therapist_chat_screen.dart';

class TherapistHomeScreen extends StatefulWidget {
  const TherapistHomeScreen({super.key});

  @override
  State<TherapistHomeScreen> createState() => _TherapistHomeScreenState();
}

class _TherapistHomeScreenState extends State<TherapistHomeScreen> {
  TherapistProfile? _profile;
  bool _loading = true;
  int _years = 0;
  String _credentials = '';
  String _contactEmail = '';
  String _contactPhone = '';
  String? _certificatePdfName;
  String? _certificateUrl;
  List<String> _reportSuggestions = const <String>[];
  List<TherapyPackage> _packages = const <TherapyPackage>[];
  bool _profilePromptDone = false;
  Map<String, bool> _notificationPrefs = _defaultTherapistNotificationPrefs;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) {
        setState(() => _loading = false);
      }
      return;
    }

    try {
      final profile = await AppRepositories.support.getTherapistById(uid);
      final doc = await FirebaseFirestore.instance
          .collection(FirestoreCollections.therapistProfiles)
          .doc(uid)
          .get();
      final userProfile = await AppRepositories.users.getCurrentUserProfile();
      final data = doc.data() ?? <String, dynamic>{};
      final parsedPackages = _parsePackages(data['servicePackages']);
      final userFullName = userProfile?.fullName.trim() ?? '';
      final canonicalDisplayName = userFullName.isNotEmpty
          ? userFullName
          : (profile?.displayName.trim().isNotEmpty == true
                ? profile!.displayName.trim()
                : (FirebaseAuth.instance.currentUser?.displayName
                              ?.trim()
                              .isNotEmpty ==
                          true
                      ? FirebaseAuth.instance.currentUser!.displayName!.trim()
                      : 'Therapist'));
      final canonicalEmail = (userProfile?.email.trim().isNotEmpty == true
          ? userProfile!.email.trim()
          : (data['contactEmail'] ??
                    FirebaseAuth.instance.currentUser?.email ??
                    '')
                .toString()
                .trim());
      final canonicalPhone = (userProfile?.phone.trim().isNotEmpty == true
          ? userProfile!.phone.trim()
          : (data['contactPhone'] ??
                    FirebaseAuth.instance.currentUser?.phoneNumber ??
                    '')
                .toString()
                .trim());

      if (!mounted) {
        return;
      }
      setState(() {
        _profile =
            profile ??
            TherapistProfile(
              id: uid,
              displayName: canonicalDisplayName,
              bio: '',
              specializations: const <String>[],
              pricing: '',
              languages: const <String>['English'],
              // Hardcoded fallback rating removed for now.
              rating: 0,
              availability: 'Open',
              photoUrl: '',
              isActive: true,
            );
        if (_profile != null && _profile!.displayName != canonicalDisplayName) {
          _profile = TherapistProfile(
            id: _profile!.id,
            displayName: canonicalDisplayName,
            bio: _profile!.bio,
            specializations: _profile!.specializations,
            pricing: _profile!.pricing,
            languages: _profile!.languages,
            rating: _profile!.rating,
            availability: _profile!.availability,
            photoUrl: _profile!.photoUrl,
            isActive: _profile!.isActive,
            yearsOfExperience: _profile!.yearsOfExperience,
            certificatePdfName: _profile!.certificatePdfName,
            certificateUrl: _profile!.certificateUrl,
            reportSuggestions: _profile!.reportSuggestions,
          );
        }
        _years = intFrom(data['yearsOfExperience']);
        _credentials = (data['credentials'] ?? '').toString();
        _contactEmail = canonicalEmail;
        _contactPhone = canonicalPhone;
        _certificatePdfName = data['certificatePdfName']?.toString();
        _certificateUrl = data['certificateUrl']?.toString();
        _reportSuggestions = stringListFrom(data['reportSuggestions']);
        _packages = parsedPackages;
        _notificationPrefs = {
          ..._defaultTherapistNotificationPrefs,
          ...boolMapFrom(data['therapistNotificationPreferences']),
        };
        _loading = false;
      });

      await _maybePromptCompleteProfile();
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _maybePromptCompleteProfile() async {
    if (_profilePromptDone || !mounted || _profile == null) {
      return;
    }
    _profilePromptDone = true;

    final incomplete =
        _profile!.specializations.isEmpty ||
        _years <= 0 ||
        _credentials.trim().isEmpty ||
        _packages.isEmpty;
    if (!incomplete) {
      return;
    }

    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) {
      return;
    }

    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => TherapistProfileSettingsScreen(
          profile: _profile!,
          setupMode: true,
          initialYears: _years,
          initialCredentials: _credentials,
          initialEmail: _contactEmail,
          initialPhone: _contactPhone,
          initialCertificatePdfName: _certificatePdfName,
          initialCertificateUrl: _certificateUrl,
          initialReportSuggestions: _reportSuggestions,
          initialPackages: _packages,
          onSave: _saveProfileData,
        ),
      ),
    );

    if (saved == true) {
      await _loadState();
    }
  }

  Future<void> _saveProfileData({
    required TherapistProfile profile,
    required int years,
    required String credentials,
    required String contactEmail,
    required String contactPhone,
    required List<TherapyPackage> packages,
    required List<String> reportSuggestions,
    String? certificatePdfName,
    String? certificateUrl,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }
    final firstName = profile.displayName.trim().split(' ').first;
    final lastNameParts = profile.displayName.trim().split(' ')..removeAt(0);
    final lastName = lastNameParts.join(' ').trim();
    final fullName = '$firstName $lastName'.trim();

    final pricing = packages.isEmpty
        ? profile.pricing
        : '\$${packages.map((item) => item.price).reduce(math.min).toDouble().toStringAsFixed(0)}/month';

    final normalized = TherapistProfile(
      id: profile.id,
      displayName: profile.displayName,
      bio: profile.bio,
      specializations: profile.specializations,
      pricing: pricing,
      languages: profile.languages.isEmpty
          ? const ['English']
          : profile.languages,
      // Hardcoded fallback rating removed for now.
      rating: profile.rating,
      availability: profile.availability.isEmpty
          ? 'Open'
          : profile.availability,
      photoUrl: profile.photoUrl,
      isActive: profile.isActive,
      yearsOfExperience: years,
      certificatePdfName: certificatePdfName ?? profile.certificatePdfName,
      certificateUrl: certificateUrl ?? profile.certificateUrl,
      reportSuggestions: reportSuggestions,
    );

    await AppRepositories.users.upsertTherapistProfile(normalized);
    await AppRepositories.users.updateCurrentUser({
      'firstName': firstName,
      'lastName': lastName,
      'fullName': fullName,
      'email': contactEmail.trim().toLowerCase(),
      'phone': contactPhone.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser != null &&
        fullName.isNotEmpty &&
        authUser.displayName?.trim() != fullName) {
      try {
        await authUser.updateDisplayName(fullName);
      } catch (_) {
        // Keep saving resilient even if Auth profile update fails.
      }
    }

    await FirebaseFirestore.instance
        .collection(FirestoreCollections.therapistProfiles)
        .doc(uid)
        .set({
          'yearsOfExperience': years,
          'credentials': credentials,
          'contactEmail': contactEmail,
          'contactPhone': contactPhone,
          if (certificatePdfName != null)
            'certificatePdfName': certificatePdfName,
          if (certificateUrl != null) 'certificateUrl': certificateUrl,
          'reportSuggestions': reportSuggestions,
          'servicePackages': packages.map((item) => item.toMap()).toList(),
          'isActive': normalized.isActive,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

    if (!mounted) {
      return;
    }
    setState(() {
      _profile = normalized;
      _years = years;
      _credentials = credentials;
      _contactEmail = contactEmail;
      _contactPhone = contactPhone;
      if (certificatePdfName != null) {
        _certificatePdfName = certificatePdfName;
      }
      if (certificateUrl != null) {
        _certificateUrl = certificateUrl;
      }
      _reportSuggestions = reportSuggestions;
      _packages = packages;
    });
  }

  Future<void> _toggleProfileVisibility(bool isActive) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final profile = _profile;
    if (uid == null || profile == null) {
      return;
    }
    final updated = TherapistProfile(
      id: profile.id,
      displayName: profile.displayName,
      bio: profile.bio,
      specializations: profile.specializations,
      pricing: profile.pricing,
      languages: profile.languages,
      rating: profile.rating,
      availability: profile.availability,
      photoUrl: profile.photoUrl,
      isActive: isActive,
      yearsOfExperience: profile.yearsOfExperience,
      certificatePdfName: profile.certificatePdfName,
      certificateUrl: profile.certificateUrl,
      reportSuggestions: profile.reportSuggestions,
    );
    await AppRepositories.users.upsertTherapistProfile(updated);
    await FirebaseFirestore.instance
        .collection(FirestoreCollections.therapistProfiles)
        .doc(uid)
        .set({
          'isActive': isActive,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
    if (!mounted) {
      return;
    }
    setState(() => _profile = updated);
  }

  Future<void> _logout() async {
    await FirebaseService().logout();
    if (!mounted) {
      return;
    }
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  Future<void> _openSettingsDialog() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black45,
      builder: (context) {
        return _TherapistSettingsDialog(
          onProfile: () async {
            Navigator.pop(context);
            if (_profile == null) return;
            await Navigator.push<bool>(
              this.context,
              MaterialPageRoute(
                builder: (_) => TherapistProfileSettingsScreen(
                  profile: _profile!,
                  setupMode: false,
                  initialYears: _years,
                  initialCredentials: _credentials,
                  initialEmail: _contactEmail,
                  initialPhone: _contactPhone,
                  initialCertificatePdfName: _certificatePdfName,
                  initialCertificateUrl: _certificateUrl,
                  initialReportSuggestions: _reportSuggestions,
                  initialPackages: _packages,
                  onSave: _saveProfileData,
                ),
              ),
            );
            if (mounted) {
              await _loadState();
            }
          },
          onPackage: () async {
            Navigator.pop(context);
            final updated = await Navigator.push<List<TherapyPackage>>(
              this.context,
              MaterialPageRoute(
                builder: (_) =>
                    TherapistPackagesScreen(initialPackages: _packages),
              ),
            );
            if (updated != null && _profile != null) {
              await _saveProfileData(
                profile: _profile!,
                years: _years,
                credentials: _credentials,
                contactEmail: _contactEmail,
                contactPhone: _contactPhone,
                packages: updated,
                reportSuggestions: _reportSuggestions,
                certificatePdfName: _certificatePdfName,
                certificateUrl: _certificateUrl,
              );
            }
          },
          onAlerts: () async {
            Navigator.pop(context);
            final updated = await Navigator.push<Map<String, bool>>(
              this.context,
              MaterialPageRoute(
                builder: (_) => TherapistNotificationSettingsScreen(
                  initialValues: _notificationPrefs,
                ),
              ),
            );
            if (updated != null) {
              await _saveNotificationPreferences(updated);
            }
          },
          onAbout: () async {
            Navigator.pop(context);
            await Navigator.push<void>(
              this.context,
              MaterialPageRoute(builder: (_) => const AboutApplicationScreen()),
            );
          },
          onLogout: () async {
            Navigator.pop(context);
            await _logout();
          },
        );
      },
    );
  }

  Future<void> _saveNotificationPreferences(Map<String, bool> values) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }
    await FirebaseFirestore.instance
        .collection(FirestoreCollections.therapistProfiles)
        .doc(uid)
        .set({
          'therapistNotificationPreferences': values,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
    if (!mounted) {
      return;
    }
    setState(() {
      _notificationPrefs = {..._defaultTherapistNotificationPrefs, ...values};
    });
  }

  Future<void> _openDashboard() async {
    if (_profile == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => TherapistDashboardScreen(
          profile: _profile!,
          years: _years,
          onToggleVisibility: _toggleProfileVisibility,
          onOpenSettings: _openSettingsDialog,
        ),
      ),
    );
  }

  void _showComingSoon() {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Coming soon')));
  }

  @override
  Widget build(BuildContext context) {
    final r = context.responsive;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return SessionGuard(
      role: SessionGuardRole.therapist,
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F6F6),
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFF9ED7F4))),
            Positioned(
              top: r.h(96),
              left: 0,
              right: 0,
              bottom: 0,
              child: ClipRRect(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(r.w(14)),
                  topRight: Radius.circular(r.w(14)),
                ),
                child: const ColoredBox(color: Color(0xFFF6F6F6)),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SafeArea(
                bottom: false,
                child: Container(
                  height: r.h(92),
                  decoration: BoxDecoration(
                    color: Color(0xFF77C6F0),
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(r.w(18)),
                      bottomRight: Radius.circular(r.w(18)),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: r.h(160),
              child: ClipPath(
                clipper: _FooterWaveClipper(),
                child: const ColoredBox(color: Color(0xFF60BEEF)),
              ),
            ),
            Positioned(
              left: r.w(44),
              bottom: r.h(34),
              child: _DecorSquare(
                color: const Color(0xFFF6E72F),
                size: r.w(16),
              ),
            ),
            Positioned(
              left: r.w(100),
              bottom: r.h(54),
              child: Icon(
                Icons.star,
                size: r.sp(20, min: 16, max: 24),
                color: const Color(0xFFFF4081),
              ),
            ),
            Positioned(
              left: r.w(188),
              bottom: r.h(20),
              child: _DecorTriangle(
                color: const Color(0xFFFF5B47),
                size: r.w(18),
              ),
            ),
            Positioned(
              right: r.w(44),
              bottom: r.h(10),
              child: _DecorCircle(
                color: const Color(0xFF24C235),
                size: r.w(15),
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + r.h(10),
              left: 0,
              right: 0,
              child: Center(child: _TherapistHomeBadge(size: r.w(124))),
            ),
            SafeArea(
              child: Column(
                children: [
                  SizedBox(height: r.h(140)),
                  Expanded(
                    child: StreamBuilder<ProfessionalSupportFeatureFlags>(
                      stream: AppRepositories.content
                          .watchProfessionalSupportFeatureFlags(),
                      initialData: ProfessionalSupportFeatureFlags.enabled,
                      builder: (context, flagsSnapshot) {
                        final featureFlags =
                            flagsSnapshot.data ??
                            ProfessionalSupportFeatureFlags.enabled;
                        return LayoutBuilder(
                          builder: (context, constraints) {
                            final cardWidth = math.min(
                              324.0,
                              constraints.maxWidth - 52,
                            );
                            return SingleChildScrollView(
                              padding: EdgeInsets.fromLTRB(
                                0,
                                r.h(12),
                                0,
                                r.h(172),
                              ),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: math.max(
                                    0,
                                    constraints.maxHeight - 184,
                                  ),
                                ),
                                child: Center(
                                  child: SizedBox(
                                    width: cardWidth,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _ModuleCard(
                                          title: 'Dashboard',
                                          color: const Color(0xFFF6B1BF),
                                          asset: 'assets/images/Dashboard.png',
                                          onTap: _openDashboard,
                                        ),
                                        SizedBox(height: r.h(14)),
                                        _ModuleCard(
                                          title: 'Messages',
                                          color: const Color(0xFFA5E876),
                                          asset:
                                              'assets/images/Professional_Support.png',
                                          enabled: featureFlags.chatEnabled,
                                          onTap: featureFlags.chatEnabled
                                              ? () => Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        const TherapistMessagesScreen(),
                                                  ),
                                                )
                                              : _showComingSoon,
                                        ),
                                        SizedBox(height: r.h(14)),
                                        _ModuleCard(
                                          title: 'Settings',
                                          color: const Color(0xFF66D2E8),
                                          asset: 'assets/images/Settings.png',
                                          onTap: _openSettingsDialog,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
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
}

class TherapistDashboardScreen extends StatefulWidget {
  const TherapistDashboardScreen({
    super.key,
    required this.profile,
    required this.years,
    required this.onToggleVisibility,
    required this.onOpenSettings,
  });

  final TherapistProfile profile;
  final int years;
  final Future<void> Function(bool isActive) onToggleVisibility;
  final Future<void> Function() onOpenSettings;

  @override
  State<TherapistDashboardScreen> createState() =>
      _TherapistDashboardScreenState();
}

class _TherapistDashboardScreenState extends State<TherapistDashboardScreen> {
  late bool _isActive;
  bool _updatingVisibility = false;

  @override
  void initState() {
    super.initState();
    _isActive = widget.profile.isActive;
  }

  @override
  void didUpdateWidget(covariant TherapistDashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.isActive != widget.profile.isActive) {
      _isActive = widget.profile.isActive;
    }
  }

  Future<void> _handleToggleVisibility() async {
    if (_updatingVisibility) {
      return;
    }
    final nextIsActive = !_isActive;
    setState(() {
      _updatingVisibility = true;
      _isActive = nextIsActive;
    });
    try {
      await widget.onToggleVisibility(nextIsActive);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            nextIsActive
                ? 'Profile is now visible to all parents.'
                : 'Profile is now hidden from new parents.',
          ),
          backgroundColor: nextIsActive
              ? const Color(0xFF0B7D3B)
              : const Color(0xFFB45309),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _isActive = !nextIsActive);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to update visibility right now.'),
          backgroundColor: Color(0xFFFF4D4D),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _updatingVisibility = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final specialization = profile.specializations.isEmpty
        ? 'ABA Therapy'
        : profile.specializations.first;
    final visibilityBg = _isActive
        ? const Color(0xFFDDFCEA)
        : const Color(0xFFFFF1E8);
    final visibilityBorder = _isActive
        ? const Color(0xFFA7E9C6)
        : const Color(0xFFFFC9A7);
    final statusColor = _isActive
        ? const Color(0xFF0B7D3B)
        : const Color(0xFFB45309);
    final detailColor = _isActive
        ? const Color(0xFF17924C)
        : const Color(0xFFC2410C);
    final actionColor = _isActive
        ? const Color(0xFF0EA5C6)
        : const Color(0xFFB45309);
    return SessionGuard(
      role: SessionGuardRole.therapist,
      child: Scaffold(
        backgroundColor: const Color(0xFFF1F3F4),
        body: SafeArea(
          child: Column(
            children: [
              Container(
                height: 80,
                color: const Color(0xFF99E8F2),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.arrow_back,
                        color: Color(0xFF1F2937),
                      ),
                    ),
                    const Expanded(
                      child: Text(
                        'Dashboard',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 30 / 1.5,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF1F2937),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: widget.onOpenSettings,
                      icon: const Icon(Icons.menu, color: Color(0xFF1F2937)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: _cardDeco,
                      child: Column(
                        children: [
                          Row(
                            children: [
                              const _LogoCircleAvatar(
                                radius: 26,
                                backgroundColor: Color(0xFFD8F6DF),
                                padding: 4,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      profile.displayName,
                                      style: const TextStyle(
                                        fontSize: 30 / 1.5,
                                        fontWeight: FontWeight.w500,
                                        color: Color(0xFF1F2937),
                                      ),
                                    ),
                                    Text(
                                      specialization,
                                      style: const TextStyle(
                                        color: Color(0xFF16A34A),
                                      ),
                                    ),
                                    Text(
                                      widget.years > 0
                                          ? '${widget.years} years exp'
                                          : 'Experience not set',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF6B7280),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: _cardDeco,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Specializations',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF1F2937),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children:
                                (profile.specializations.isEmpty
                                        ? const [
                                            'ABA Therapy',
                                            'Speech Therapy',
                                            'Social Skills',
                                          ]
                                        : profile.specializations)
                                    .map(
                                      (item) => Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFDDEBFF),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                        child: Text(
                                          item,
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            color: Color(0xFF3165C9),
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: _cardDeco,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Profile Visibility',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF1F2937),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _isActive
                                ? 'Your profile is visible to parents in the community'
                                : 'Your profile is hidden from new parent discovery',
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF4B5563),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: visibilityBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: visibilityBorder),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _isActive
                                            ? 'Status: Active'
                                            : 'Status: Inactive',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: statusColor,
                                        ),
                                      ),
                                      Text(
                                        _isActive
                                            ? 'Parents can discover and contact you'
                                            : 'Only subscribed parents can continue seeing you',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: detailColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                OutlinedButton(
                                  onPressed: _updatingVisibility
                                      ? null
                                      : _handleToggleVisibility,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: actionColor,
                                    side: BorderSide(color: actionColor),
                                    minimumSize: const Size(86, 40),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                  ),
                                  child: _updatingVisibility
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Text(
                                          _isActive ? 'Hide' : 'Show',
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: _cardDeco.copyWith(
                        color: const Color(0xFFDDF6FF),
                        border: Border.all(color: const Color(0xFFA8E4F7)),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Tips to Increase Visibility:',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1F2937),
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            '✓ Complete all profile sections with detailed information',
                          ),
                          Text(
                            '✓ Add multiple service packages to attract different needs',
                          ),
                          Text('✓ Respond quickly to parent inquiries'),
                          Text(
                            '✓ Maintain a high rating through quality service',
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
      ),
    );
  }
}

class TherapistMessagesScreen extends StatefulWidget {
  const TherapistMessagesScreen({super.key});

  @override
  State<TherapistMessagesScreen> createState() =>
      _TherapistMessagesScreenState();
}

class _TherapistMessagesScreenState extends State<TherapistMessagesScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<Map<String, UserProfile>> _loadParentProfiles(
    List<TherapistThread> threads,
  ) async {
    final parentIds = threads.map((thread) => thread.parentId).toSet();
    final entries = await Future.wait(
      parentIds.map((parentId) async {
        final profile = await AppRepositories.users.getUserProfile(parentId);
        return MapEntry(parentId, profile);
      }),
    );

    return {
      for (final entry in entries)
        if (entry.value != null) entry.key: entry.value!,
    };
  }

  @override
  Widget build(BuildContext context) {
    return SessionGuard(
      role: SessionGuardRole.therapist,
      child: Scaffold(
        backgroundColor: const Color(0xFFF1F3F4),
        body: SafeArea(
          child: Column(
            children: [
              Container(
                height: 80,
                color: const Color(0xFF9FE7F2),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const Expanded(
                      child: Text(
                        'Messages',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 46 / 1.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 40),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                  decoration: InputDecoration(
                    hintText: 'Search conversations...',
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: StreamBuilder<List<TherapistThread>>(
                  stream: AppRepositories.support.watchThreadsForRole(
                    'therapist',
                  ),
                  builder: (context, snapshot) {
                    final threads = snapshot.data ?? const <TherapistThread>[];
                    if (threads.isEmpty) {
                      return const Center(
                        child: Text('No parent conversations yet.'),
                      );
                    }
                    final filtered = threads.where((thread) {
                      if (_query.isEmpty) return true;
                      final hay =
                          '${thread.parentDisplayName} ${thread.lastMessagePreview}'
                              .toLowerCase();
                      return hay.contains(_query);
                    }).toList();

                    return FutureBuilder<Map<String, UserProfile>>(
                      future: _loadParentProfiles(filtered),
                      builder: (context, parentSnapshot) {
                        final parentMap =
                            parentSnapshot.data ??
                            const <String, UserProfile>{};
                        return ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final thread = filtered[index];
                            final parentProfile = parentMap[thread.parentId];
                            final parentName =
                                thread.parentDisplayName.isNotEmpty
                                ? thread.parentDisplayName
                                : (parentProfile?.fullName.isNotEmpty == true
                                      ? parentProfile!.fullName
                                      : parentProfile?.email ?? 'Parent');

                            return ListTile(
                              leading: const CircleAvatar(
                                backgroundColor: Color(0xFFD9F4DF),
                                child: Icon(
                                  Icons.person,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                              title: Text(
                                parentName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Parent conversation',
                                    style: TextStyle(color: Color(0xFF16A34A)),
                                  ),
                                  Text(
                                    thread.lastMessagePreview.isEmpty
                                        ? 'No messages yet'
                                        : thread.lastMessagePreview,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    _friendlyTime(thread.lastMessageAt),
                                    style: const TextStyle(
                                      color: Color(0xFF9CA3AF),
                                    ),
                                  ),
                                ],
                              ),
                              trailing: thread.hasOpenEmergency
                                  ? const CircleAvatar(
                                      radius: 12,
                                      backgroundColor: Color(0xFFF85D93),
                                      child: Text(
                                        '2',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    )
                                  : null,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => TherapistChatScreen(
                                      thread: thread,
                                      participantName: parentName,
                                      senderRole: 'therapist',
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TherapistProfileSettingsScreen extends StatefulWidget {
  const TherapistProfileSettingsScreen({
    super.key,
    required this.profile,
    required this.setupMode,
    required this.initialYears,
    required this.initialCredentials,
    required this.initialEmail,
    required this.initialPhone,
    required this.initialCertificatePdfName,
    required this.initialCertificateUrl,
    required this.initialReportSuggestions,
    required this.initialPackages,
    required this.onSave,
  });

  final TherapistProfile profile;
  final bool setupMode;
  final int initialYears;
  final String initialCredentials;
  final String initialEmail;
  final String initialPhone;
  final String? initialCertificatePdfName;
  final String? initialCertificateUrl;
  final List<String> initialReportSuggestions;
  final List<TherapyPackage> initialPackages;
  final Future<void> Function({
    required TherapistProfile profile,
    required int years,
    required String credentials,
    required String contactEmail,
    required String contactPhone,
    required List<TherapyPackage> packages,
    required List<String> reportSuggestions,
    String? certificatePdfName,
    String? certificateUrl,
  })
  onSave;

  @override
  State<TherapistProfileSettingsScreen> createState() =>
      _TherapistProfileSettingsScreenState();
}

class _TherapistProfileSettingsScreenState
    extends State<TherapistProfileSettingsScreen> {
  final _selected = <String>{};
  late final TextEditingController _first;
  late final TextEditingController _last;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _years;
  late final TextEditingController _credentials;
  late final TextEditingController _reportSuggestionsController;
  late final TextEditingController _about;
  String? _certificatePdfName;
  String? _certificateUrl;
  bool _uploadingCertificate = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final display = widget.profile.displayName.trim().split(' ');
    _first = TextEditingController(text: display.isEmpty ? '' : display.first);
    _last = TextEditingController(
      text: display.length > 1 ? display.sublist(1).join(' ') : '',
    );
    _email = TextEditingController(text: widget.initialEmail);
    _phone = TextEditingController(text: widget.initialPhone);
    _years = TextEditingController(
      text: widget.initialYears > 0 ? widget.initialYears.toString() : '',
    );
    _credentials = TextEditingController(text: widget.initialCredentials);
    _reportSuggestionsController = TextEditingController(
      text: widget.initialReportSuggestions.join('\n'),
    );
    _about = TextEditingController(text: widget.profile.bio);
    _certificatePdfName = widget.initialCertificatePdfName;
    _certificateUrl = widget.initialCertificateUrl;
    _selected.addAll(widget.profile.specializations);
  }

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _email.dispose();
    _phone.dispose();
    _years.dispose();
    _credentials.dispose();
    _reportSuggestionsController.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _openPricing() async {
    final updated = await Navigator.push<List<TherapyPackage>>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            TherapistPackagesScreen(initialPackages: widget.initialPackages),
      ),
    );

    if (updated == null) {
      return;
    }

    await _save(updated);
  }

  Future<void> _save(List<TherapyPackage> packages) async {
    if (_saving) {
      return;
    }
    if (_first.text.trim().isEmpty || _selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete required fields.')),
      );
      return;
    }
    final email = _email.text.trim();
    if (!_isValidEmail(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid email address.')),
      );
      return;
    }
    final phone = _phone.text.trim();
    if (!_isValidPhoneNumber(phone)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid phone number (10-15 digits).'),
        ),
      );
      return;
    }

    final years = int.tryParse(_years.text.trim()) ?? 0;

    setState(() => _saving = true);
    try {
      final updated = TherapistProfile(
        id: widget.profile.id,
        displayName: '${_first.text.trim()} ${_last.text.trim()}'.trim(),
        bio: _about.text.trim(),
        specializations: _selected.toList(growable: false),
        pricing: widget.profile.pricing,
        languages: widget.profile.languages,
        rating: widget.profile.rating,
        availability: widget.profile.availability,
        photoUrl: widget.profile.photoUrl,
        isActive: widget.profile.isActive,
      );

      await widget.onSave(
        profile: updated,
        years: years,
        credentials: _credentials.text.trim(),
        contactEmail: email,
        contactPhone: phone,
        packages: packages,
        reportSuggestions: _parseReportSuggestions(
          _reportSuggestionsController.text,
        ),
        certificatePdfName: _certificatePdfName,
        certificateUrl: _certificateUrl,
      );

      if (mounted) {
        Navigator.pop(context, true);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _pickCertificatePdf() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      withData: true,
      withReadStream: true,
    );
    if (result == null || result.files.isEmpty) {
      return;
    }
    final file = result.files.single;
    final fileName = file.name.trim();
    final bytes = await _resolvePickedFileBytes(file);
    if (bytes == null || bytes.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to read PDF bytes. Please try another file.'),
        ),
      );
      return;
    }

    await _uploadCertificateBytes(
      uid: uid,
      fileName: fileName,
      bytes: bytes,
      successMessage: 'Certificate uploaded: $fileName',
    );
  }

  Future<Uint8List?> _resolvePickedFileBytes(PlatformFile file) async {
    if (file.bytes != null && file.bytes!.isNotEmpty) {
      return file.bytes!;
    }
    final stream = file.readStream;
    if (stream == null) {
      return null;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) {
      return null;
    }
    return bytes;
  }

  Future<void> _uploadCertificateBytes({
    required String uid,
    required String fileName,
    required Uint8List bytes,
    required String successMessage,
  }) async {
    if (bytes.isEmpty) {
      return;
    }

    setState(() => _uploadingCertificate = true);
    try {
      final certificateUrl = await _uploadCertificateToStorage(
        uid: uid,
        fileName: fileName,
        bytes: bytes,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _certificatePdfName = fileName;
        _certificateUrl = certificateUrl;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload failed: $error')));
    } finally {
      if (mounted) {
        setState(() => _uploadingCertificate = false);
      }
    }
  }

  Future<String> _uploadCertificateToStorage({
    required String uid,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeName = _sanitizeFileName(fileName);
    final objectPath = 'therapist_certificates/$uid/${timestamp}_$safeName';
    final candidates = _storageBucketCandidates();
    Object? lastError;

    for (final bucket in candidates) {
      try {
        final storage = bucket == null
            ? FirebaseStorage.instance
            : FirebaseStorage.instanceFor(bucket: bucket);
        final ref = storage.ref(objectPath);
        await ref.putData(
          bytes,
          SettableMetadata(contentType: 'application/pdf'),
        );
        return _resolveDownloadUrlWithRetry(ref);
      } catch (error) {
        final message = error.toString();
        final objectNotFound = message.contains('object-not-found');
        if (objectNotFound) {
          try {
            final fallbackStorage = bucket == null
                ? FirebaseStorage.instance
                : FirebaseStorage.instanceFor(bucket: bucket);
            final fallbackRef = fallbackStorage.ref(objectPath);
            await _uploadViaTempFile(fallbackRef, bytes);
            return _resolveDownloadUrlWithRetry(fallbackRef);
          } catch (_) {
            // Keep trying other bucket candidates.
          }
        }
        lastError = error;
      }
    }

    throw StateError(
      'Unable to upload certificate to Firebase Storage. ${lastError ?? ''}',
    );
  }

  Future<void> _uploadViaTempFile(Reference ref, Uint8List bytes) async {
    final tempDir = Directory.systemTemp;
    final tempFile = File(
      '${tempDir.path}${Platform.pathSeparator}autiease_certificate_${DateTime.now().microsecondsSinceEpoch}.pdf',
    );
    await tempFile.writeAsBytes(bytes, flush: true);
    try {
      await ref.putFile(
        tempFile,
        SettableMetadata(contentType: 'application/pdf'),
      );
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  Future<String> _resolveDownloadUrlWithRetry(Reference ref) async {
    Object? lastError;
    for (var attempt = 0; attempt < 4; attempt += 1) {
      try {
        return await ref.getDownloadURL();
      } catch (error) {
        lastError = error;
        if (!error.toString().contains('object-not-found')) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }
    throw StateError('Unable to resolve certificate download URL: $lastError');
  }

  List<String?> _storageBucketCandidates() {
    final configuredRaw = Firebase.app().options.storageBucket;
    final configured = (configuredRaw ?? '').trim();
    final normalizedConfigured = configured
        .replaceFirst(RegExp(r'^gs://'), '')
        .replaceFirst(RegExp(r'/$'), '');

    final projectId = Firebase.app().options.projectId.trim();
    final candidates = <String?>[];

    candidates.add(null); // default app storage
    if (normalizedConfigured.isNotEmpty) {
      candidates.add(normalizedConfigured);
      if (normalizedConfigured.endsWith('.firebasestorage.app')) {
        final prefix = normalizedConfigured.replaceFirst(
          '.firebasestorage.app',
          '',
        );
        candidates.add('$prefix.appspot.com');
      } else if (normalizedConfigured.endsWith('.appspot.com')) {
        final prefix = normalizedConfigured.replaceFirst('.appspot.com', '');
        candidates.add('$prefix.firebasestorage.app');
      }
    }

    if (projectId.isNotEmpty) {
      candidates.add('$projectId.appspot.com');
      candidates.add('$projectId.firebasestorage.app');
    }

    final seen = <String?>{};
    final unique = <String?>[];
    for (final item in candidates) {
      if (item != null && item.trim().isEmpty) {
        continue;
      }
      if (seen.add(item)) {
        unique.add(item);
      }
    }
    return unique;
  }

  String _sanitizeFileName(String value) {
    final normalized = value
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    if (normalized.isEmpty) {
      return 'certificate.pdf';
    }
    return normalized.toLowerCase().endsWith('.pdf')
        ? normalized
        : '$normalized.pdf';
  }

  Future<void> _openCertificateUrl(String? url) async {
    final value = (url ?? '').trim();
    if (value.isEmpty) {
      return;
    }
    final uri = Uri.tryParse(value);
    if (uri == null) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _certificateUploadStatusText() {
    if (_uploadingCertificate) {
      return const Text(
        'Uploading certificate...',
        style: TextStyle(color: Color(0xFF0F766E), fontWeight: FontWeight.w500),
      );
    }
    if ((_certificatePdfName ?? '').trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return Text(
      'Selected: $_certificatePdfName',
      style: const TextStyle(
        color: Color(0xFF334155),
        fontWeight: FontWeight.w500,
      ),
    );
  }

  List<String> _parseReportSuggestions(String raw) {
    return raw
        .split(RegExp(r'[\r\n]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.setupMode) {
      return _buildSetupMode(context);
    }
    return _buildProfileSettingsMode(context);
  }

  Widget _buildSetupMode(BuildContext context) {
    return SessionGuard(
      role: SessionGuardRole.therapist,
      child: Scaffold(
        backgroundColor: const Color(0xFFF1F3F4),
        body: SafeArea(
          child: Column(
            children: [
              Container(
                height: 80,
                color: const Color(0xFF9FE7F2),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                    ),
                    Expanded(
                      child: Text(
                        widget.setupMode
                            ? 'Complete Your Profile'
                            : 'My Profile',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 30 / 1.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 40),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                  children: [
                    const Center(
                      child: _LogoCircleAvatar(
                        radius: 42,
                        backgroundColor: Colors.white,
                        padding: 6,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: _cardDeco,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Select Your Specializations',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          for (final item in _specializations)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              value: _selected.contains(item),
                              onChanged: (value) {
                                setState(() {
                                  if (value == true) {
                                    _selected.add(item);
                                  } else {
                                    _selected.remove(item);
                                  }
                                });
                              },
                              title: Text(
                                item,
                                style: const TextStyle(fontSize: 13.5),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (!widget.setupMode) ...[
                      _input('First Name', _first),
                      const SizedBox(height: 8),
                      _input('Last Name', _last),
                      const SizedBox(height: 8),
                    ],
                    _input(
                      'Years of Experience',
                      _years,
                      keyboard: TextInputType.number,
                    ),
                    const SizedBox(height: 8),
                    _input(
                      'Credentials & Certifications',
                      _credentials,
                      lines: 3,
                    ),
                    const SizedBox(height: 8),
                    _input(
                      'Report Suggestions (one per line)',
                      _reportSuggestionsController,
                      lines: 4,
                    ),
                    const SizedBox(height: 8),
                    _input('About You', _about, lines: 4),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _uploadingCertificate
                          ? null
                          : _pickCertificatePdf,
                      icon: const Icon(Icons.upload_file_outlined),
                      label: const Text('Upload Certificate PDF'),
                    ),
                    if (_uploadingCertificate ||
                        _certificatePdfName != null) ...[
                      const SizedBox(height: 6),
                      _certificateUploadStatusText(),
                      if ((_certificateUrl ?? '').trim().isNotEmpty)
                        TextButton(
                          onPressed: () => _openCertificateUrl(_certificateUrl),
                          child: const Text('View Uploaded Certificate'),
                        ),
                    ],
                    const SizedBox(height: 12),
                    if (widget.setupMode)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Back'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: _saving ? null : _openPricing,
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF11B5CF),
                                foregroundColor: Colors.white,
                              ),
                              child: _saving
                                  ? const SizedBox(
                                      height: 16,
                                      width: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('Next: Pricing'),
                            ),
                          ),
                        ],
                      )
                    else
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _saving
                              ? null
                              : () => _save(widget.initialPackages),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF11B5CF),
                            foregroundColor: Colors.white,
                          ),
                          child: _saving
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Save Changes'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileSettingsMode(BuildContext context) {
    return SessionGuard(
      role: SessionGuardRole.therapist,
      child: Scaffold(
        backgroundColor: const Color(0xFFF1F3F4),
        body: SafeArea(
          child: Column(
            children: [
              Container(
                height: 80,
                color: const Color(0xFF9FE7F2),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const Expanded(
                      child: Text(
                        'Profile Settings',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 26 / 1.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1F2937),
                        ),
                      ),
                    ),
                    const SizedBox(width: 40),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                  children: [
                    _sectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Profile Picture',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1F2937),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Stack(
                                children: [
                                  const _LogoCircleAvatar(
                                    radius: 26,
                                    backgroundColor: Colors.white,
                                    padding: 4,
                                  ),
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF11B5CF),
                                        borderRadius: BorderRadius.circular(9),
                                        border: Border.all(
                                          color: Colors.white,
                                          width: 1.6,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.camera_alt_outlined,
                                        size: 11,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${_first.text.trim()} ${_last.text.trim()}'
                                              .trim()
                                              .isEmpty
                                          ? widget.profile.displayName
                                          : '${_first.text.trim()} ${_last.text.trim()}'
                                                .trim(),
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF1F2937),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _sectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Basic Information',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1F2937),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(child: _input('First Name', _first)),
                              const SizedBox(width: 8),
                              Expanded(child: _input('Last Name', _last)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _input(
                            'Email Address',
                            _email,
                            keyboard: TextInputType.emailAddress,
                            readOnly: true,
                          ),
                          const SizedBox(height: 8),
                          _input(
                            'Phone Number',
                            _phone,
                            keyboard: TextInputType.phone,
                          ),
                          const SizedBox(height: 8),
                          _input('About Me', _about, lines: 4),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _sectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Professional Information',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1F2937),
                            ),
                          ),
                          const SizedBox(height: 10),
                          _input(
                            'Years of Experience',
                            _years,
                            keyboard: TextInputType.number,
                          ),
                          const SizedBox(height: 8),
                          _input(
                            'Credentials & Certifications',
                            _credentials,
                            lines: 3,
                          ),
                          const SizedBox(height: 8),
                          _input(
                            'Report Suggestions (one per line)',
                            _reportSuggestionsController,
                            lines: 4,
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _uploadingCertificate
                                ? null
                                : _pickCertificatePdf,
                            icon: const Icon(Icons.upload_file_outlined),
                            label: Text(
                              _uploadingCertificate
                                  ? 'Uploading...'
                                  : _certificatePdfName == null
                                  ? 'Upload Certificate PDF'
                                  : 'Selected: $_certificatePdfName',
                              overflow: TextOverflow.ellipsis,
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(42),
                              alignment: Alignment.centerLeft,
                              side: const BorderSide(color: Color(0xFF11B5CF)),
                              foregroundColor: const Color(0xFF11B5CF),
                            ),
                          ),
                          if ((_certificateUrl ?? '').trim().isNotEmpty)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: () =>
                                    _openCertificateUrl(_certificateUrl),
                                child: const Text('View Uploaded Certificate'),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _sectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Specializations (${_selected.length} selected)',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1F2937),
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (final item in _specializations) ...[
                            Container(
                              margin: const EdgeInsets.only(bottom: 7),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0xFFE5E7EB),
                                ),
                                color: Colors.white,
                              ),
                              child: CheckboxListTile(
                                dense: true,
                                value: _selected.contains(item),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 0,
                                ),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                activeColor: const Color(0xFF11B5CF),
                                onChanged: (value) {
                                  setState(() {
                                    if (value == true) {
                                      _selected.add(item);
                                    } else {
                                      _selected.remove(item);
                                    }
                                  });
                                },
                                title: Text(
                                  item,
                                  style: const TextStyle(
                                    fontSize: 13.2,
                                    color: Color(0xFF374151),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _saving
                            ? null
                            : () => _save(widget.initialPackages),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF11B5CF),
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: _saving
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Save All Changes'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _input(
    String label,
    TextEditingController controller, {
    int lines = 1,
    TextInputType? keyboard,
    bool readOnly = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 12,
            color: Color(0xFF6B7280),
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          maxLines: lines,
          keyboardType: keyboard,
          readOnly: readOnly,
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF11B5CF)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  bool _isValidEmail(String email) {
    if (email.isEmpty) {
      return false;
    }
    final emailRegex = RegExp(
      r'^[a-zA-Z0-9.!#$%&*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$',
    );
    return emailRegex.hasMatch(email);
  }

  bool _isValidPhoneNumber(String phone) {
    final digitsOnly = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (digitsOnly.length < 10 || digitsOnly.length > 15) {
      return false;
    }
    final phoneRegex = RegExp(r'^[+]?[\d\s\-()]+$');
    return phoneRegex.hasMatch(phone);
  }
}

class TherapistPackagesScreen extends StatefulWidget {
  const TherapistPackagesScreen({super.key, required this.initialPackages});

  final List<TherapyPackage> initialPackages;

  @override
  State<TherapistPackagesScreen> createState() =>
      _TherapistPackagesScreenState();
}

class _TherapistPackagesScreenState extends State<TherapistPackagesScreen> {
  late List<TherapyPackage> _packages;

  @override
  void initState() {
    super.initState();
    _packages = widget.initialPackages.isEmpty
        ? <TherapyPackage>[
            const TherapyPackage(
              title: 'Standard Therapy Session',
              durationMinutes: 60,
              sessionsPerWeek: 3,
              price: 75,
              description:
                  '1-hour therapy session including assessment, intervention, and parent consultation',
              visible: true,
            ),
          ]
        : widget.initialPackages.map((item) => item.copy()).toList();
  }

  Future<void> _addOrEdit({int? index}) async {
    final initial = index == null ? null : _packages[index];
    final pkg = await showDialog<TherapyPackage>(
      context: context,
      barrierColor: Colors.black45,
      builder: (_) => _PackageEditor(initial: initial),
    );
    if (pkg == null) {
      return;
    }
    setState(() {
      if (index == null) {
        _packages.add(pkg);
      } else {
        _packages[index] = pkg;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.pop(context, _packages);
        }
      },
      child: SessionGuard(
        role: SessionGuardRole.therapist,
        child: Scaffold(
          backgroundColor: const Color(0xFFF1F3F4),
          body: SafeArea(
            child: Column(
              children: [
                Container(
                  height: 80,
                  color: const Color(0xFF9FE7F2),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context, _packages),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const Expanded(
                        child: Text(
                          'Service Packages',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 46 / 1.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 40),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    children: [
                      FilledButton.icon(
                        onPressed: () => _addOrEdit(),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF10B6CF),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.add),
                        label: const Text('Add New Package'),
                      ),
                      const SizedBox(height: 12),
                      for (var i = 0; i < _packages.length; i++) ...[
                        _PackageTile(
                          package: _packages[i],
                          onEdit: () => _addOrEdit(index: i),
                          onDelete: () => setState(() => _packages.removeAt(i)),
                          onVisible: (value) => setState(
                            () => _packages[i] = _packages[i].copy(
                              visible: value,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      FilledButton(
                        onPressed: () => Navigator.pop(context, _packages),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF10B6CF),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Complete'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TherapistNotificationSettingsScreen extends StatefulWidget {
  const TherapistNotificationSettingsScreen({
    super.key,
    required this.initialValues,
  });

  final Map<String, bool> initialValues;

  @override
  State<TherapistNotificationSettingsScreen> createState() =>
      _TherapistNotificationSettingsScreenState();
}

class _TherapistNotificationSettingsScreenState
    extends State<TherapistNotificationSettingsScreen> {
  bool email = false;
  bool sms = false;
  bool newMessages = false;
  bool bookings = false;
  bool reminders = false;
  bool payments = false;
  bool emergency = true;

  @override
  void initState() {
    super.initState();
    final initial = {
      ..._defaultTherapistNotificationPrefs,
      ...widget.initialValues,
    };
    email = initial['email'] ?? false;
    sms = initial['sms'] ?? false;
    newMessages = initial['newMessages'] ?? false;
    bookings = initial['bookings'] ?? false;
    reminders = initial['reminders'] ?? false;
    payments = initial['payments'] ?? false;
    emergency = initial['emergency'] ?? true;
  }

  @override
  Widget build(BuildContext context) {
    return SessionGuard(
      role: SessionGuardRole.therapist,
      child: Scaffold(
        backgroundColor: const Color(0xFFF1F3F4),
        body: SafeArea(
          child: Column(
            children: [
              Container(
                height: 80,
                color: const Color(0xFF9FE7F2),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const Expanded(
                      child: Text(
                        'Notification Settings',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 40 / 1.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 40),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  children: [
                    _switchTile(
                      'Email Notifications',
                      'Receive updates via email',
                      email,
                      (v) => setState(() => email = v),
                    ),
                    _switchTile(
                      'SMS Notifications',
                      'Receive text message alerts',
                      sms,
                      (v) => setState(() => sms = v),
                    ),
                    _switchTile(
                      'New Messages',
                      'When parents send you messages',
                      newMessages,
                      (v) => setState(() => newMessages = v),
                    ),
                    _switchTile(
                      'New Bookings',
                      'When parents book your sessions',
                      bookings,
                      (v) => setState(() => bookings = v),
                    ),
                    _switchTile(
                      'Session Reminders',
                      'Upcoming session notifications',
                      reminders,
                      (v) => setState(() => reminders = v),
                    ),
                    _switchTile(
                      'Payment Alerts',
                      'Payment and transaction updates',
                      payments,
                      (v) => setState(() => payments = v),
                    ),
                    _switchTile(
                      'Emergency Button Alerts',
                      'Instant alerts for emergency events',
                      emergency,
                      (v) => setState(() => emergency = v),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () {
                        Navigator.pop(context, <String, bool>{
                          'email': email,
                          'sms': sms,
                          'newMessages': newMessages,
                          'bookings': bookings,
                          'reminders': reminders,
                          'payments': payments,
                          'emergency': emergency,
                        });
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF8CC93B),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Save Notification Preferences'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _switchTile(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: _cardDeco,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(color: Color(0xFF6B7280)),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _TherapistSettingsDialog extends StatelessWidget {
  const _TherapistSettingsDialog({
    required this.onProfile,
    required this.onPackage,
    required this.onAlerts,
    required this.onAbout,
    required this.onLogout,
  });

  final VoidCallback onProfile;
  final VoidCallback onPackage;
  final VoidCallback onAlerts;
  final VoidCallback onAbout;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            const CircleAvatar(
              radius: 23,
              backgroundColor: Color(0xFF10B6CF),
              child: Icon(Icons.settings, color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text(
              'Settings',
              style: TextStyle(fontSize: 36 / 1.5, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _setBtn(
                    'Profile',
                    const Color(0xFF10B6CF),
                    Icons.person_outline,
                    onProfile,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _setBtn(
                    'Package',
                    const Color(0xFFFB923C),
                    Icons.inventory_2_outlined,
                    onPackage,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _setBtn(
                    'Alerts',
                    const Color(0xFF8CC93B),
                    Icons.notifications_none,
                    onAlerts,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _setBtn(
                    'About Application',
                    const Color(0xFF60A5FA),
                    Icons.info_outline,
                    onAbout,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onLogout,
                icon: const Icon(Icons.logout),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF3040),
                  foregroundColor: Colors.white,
                ),
                label: const Text('Logout'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _setBtn(String title, Color color, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Ink(
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                title,
                maxLines: 2,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PackageTile extends StatelessWidget {
  const _PackageTile({
    required this.package,
    required this.onEdit,
    required this.onDelete,
    required this.onVisible,
  });

  final TherapyPackage package;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onVisible;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _cardDeco,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: const BoxDecoration(
              color: Color(0xFFFB955F),
              borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
            ),
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    package.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 30 / 1.5,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit, color: Colors.white),
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, color: Colors.white),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '\$${package.price.toStringAsFixed(0)} /session',
                  style: const TextStyle(
                    color: Color(0xFF0EA5C6),
                    fontWeight: FontWeight.w700,
                    fontSize: 42 / 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${package.durationMinutes} min • ${package.sessionsPerWeek} sessions/week',
                ),
                const SizedBox(height: 6),
                Text(
                  package.description,
                  style: const TextStyle(color: Color(0xFF6B7280)),
                ),
                Row(
                  children: [
                    const Expanded(child: Text('Visible to parents')),
                    Switch(value: package.visible, onChanged: onVisible),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PackageEditor extends StatefulWidget {
  const _PackageEditor({this.initial});

  final TherapyPackage? initial;

  @override
  State<_PackageEditor> createState() => _PackageEditorState();
}

class _PackageEditorState extends State<_PackageEditor> {
  late final TextEditingController _title;
  late final TextEditingController _price;
  late final TextEditingController _duration;
  late final TextEditingController _sessions;
  late final TextEditingController _description;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initial?.title ?? '');
    _price = TextEditingController(
      text: (widget.initial?.price ?? 75).toStringAsFixed(0),
    );
    _duration = TextEditingController(
      text: '${widget.initial?.durationMinutes ?? 60}',
    );
    _sessions = TextEditingController(
      text: '${widget.initial?.sessionsPerWeek ?? 3}',
    );
    _description = TextEditingController(
      text: widget.initial?.description ?? '',
    );
  }

  @override
  void dispose() {
    _title.dispose();
    _price.dispose();
    _duration.dispose();
    _sessions.dispose();
    _description.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    final price = double.tryParse(_price.text.trim()) ?? 0;
    if (title.isEmpty || price <= 0) {
      return;
    }
    Navigator.pop(
      context,
      TherapyPackage(
        title: title,
        durationMinutes: int.tryParse(_duration.text.trim()) ?? 60,
        sessionsPerWeek: int.tryParse(_sessions.text.trim()) ?? 3,
        price: price,
        description: _description.text.trim(),
        visible: widget.initial?.visible ?? true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.initial == null ? 'Add New Package' : 'Edit Package',
                    style: const TextStyle(
                      fontSize: 34 / 1.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _field('Package Title', _title),
            const SizedBox(height: 8),
            _field(
              'Price per Session (\$)',
              _price,
              keyboard: TextInputType.number,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _field(
                    'Duration (min)',
                    _duration,
                    keyboard: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _field(
                    'Sessions/Week',
                    _sessions,
                    keyboard: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _field('Description', _description, lines: 3),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _save,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF11B5CF),
                  foregroundColor: Colors.white,
                ),
                child: Text(
                  widget.initial == null ? 'Add Package' : 'Save Changes',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController c, {
    TextInputType? keyboard,
    int lines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        TextField(
          controller: c,
          keyboardType: keyboard,
          maxLines: lines,
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
          ),
        ),
      ],
    );
  }
}

class _TherapistHomeBadge extends StatelessWidget {
  const _TherapistHomeBadge({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFFC4E5C6),
      ),
      padding: EdgeInsets.all(size * 0.065),
      child: ClipOval(
        child: Image.asset('assets/images/autiease.png', fit: BoxFit.contain),
      ),
    );
  }
}

class _LogoCircleAvatar extends StatelessWidget {
  const _LogoCircleAvatar({
    required this.radius,
    required this.backgroundColor,
    this.padding = 4,
  });

  final double radius;
  final Color backgroundColor;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(color: backgroundColor, shape: BoxShape.circle),
      padding: EdgeInsets.all(padding),
      child: ClipOval(
        child: Image.asset('assets/images/autiease.png', fit: BoxFit.contain),
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.title,
    required this.color,
    required this.asset,
    required this.onTap,
    this.enabled = true,
  });

  final String title;
  final Color color;
  final String asset;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final r = context.responsive;
    final cardColor = enabled ? color : color.withValues(alpha: 0.6);
    final textColor = enabled
        ? const Color(0xFF111827)
        : const Color(0xFF4B5563);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(r.w(14)),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(horizontal: r.w(20), vertical: r.h(22)),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(r.w(14)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: r.sp(40 / 1.5, min: 18, max: 28),
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
              SizedBox(
                height: r.w(44),
                width: r.w(44),
                child: Image.asset(asset, fit: BoxFit.contain),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TherapyPackage {
  const TherapyPackage({
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

  TherapyPackage copy({
    String? title,
    int? durationMinutes,
    int? sessionsPerWeek,
    double? price,
    String? description,
    bool? visible,
  }) {
    return TherapyPackage(
      title: title ?? this.title,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      sessionsPerWeek: sessionsPerWeek ?? this.sessionsPerWeek,
      price: price ?? this.price,
      description: description ?? this.description,
      visible: visible ?? this.visible,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'durationMinutes': durationMinutes,
      'sessionsPerWeek': sessionsPerWeek,
      'price': price,
      'description': description,
      'visible': visible,
    };
  }

  static TherapyPackage fromMap(Map<String, dynamic> map) {
    final rawPrice = map.containsKey('price')
        ? map['price']
        : map['pricePerSession'];
    final price = rawPrice is num ? rawPrice.toDouble() : 0.0;
    return TherapyPackage(
      title: (map['title'] ?? '').toString(),
      durationMinutes: intFrom(map['durationMinutes'], 60),
      sessionsPerWeek: intFrom(map['sessionsPerWeek'], 3),
      price: price,
      description: (map['description'] ?? '').toString(),
      visible:
          (map.containsKey('visible') ? map['visible'] : map['isVisible']) !=
          false,
    );
  }
}

List<TherapyPackage> _parsePackages(dynamic raw) {
  if (raw is! List) {
    return const <TherapyPackage>[];
  }
  final parsed = <TherapyPackage>[];
  for (final entry in raw) {
    final map = mapFrom(entry);
    if (map.isEmpty) continue;
    parsed.add(TherapyPackage.fromMap(map));
  }
  return parsed;
}

String _friendlyTime(DateTime? time) {
  if (time == null) return 'Just now';
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  if (diff.inDays == 1) return 'Yesterday';
  return '${diff.inDays} days ago';
}

class _FooterWaveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.moveTo(0, 48);
    path.quadraticBezierTo(size.width * 0.18, 72, size.width * 0.48, 104);
    path.quadraticBezierTo(size.width * 0.78, 138, size.width, 62);
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _DecorSquare extends StatelessWidget {
  const _DecorSquare({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(width: size, height: size, color: color);
  }
}

class _DecorCircle extends StatelessWidget {
  const _DecorCircle({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _DecorTriangle extends StatelessWidget {
  const _DecorTriangle({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _TrianglePainter(color),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  const _TrianglePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

const BoxDecoration _cardDeco = BoxDecoration(
  color: Colors.white,
  borderRadius: BorderRadius.all(Radius.circular(14)),
  boxShadow: [
    BoxShadow(color: Color(0x1A000000), blurRadius: 10, offset: Offset(0, 2)),
  ],
);

const Map<String, bool> _defaultTherapistNotificationPrefs = <String, bool>{
  'email': false,
  'sms': false,
  'newMessages': false,
  'bookings': false,
  'reminders': false,
  'payments': false,
  'emergency': true,
};

const List<String> _specializations = <String>[
  'Applied Behavior Analysis (ABA)',
  'Speech and Language Therapy',
  'Occupational Therapy',
  'Physical Therapy',
  'Social Skills Training',
  'Sensory Integration Therapy',
  'Cognitive Behavioral Therapy (CBT)',
  'TEACCH',
  'PECS',
  'Floortime (DIR Model)',
  'Relationship Development Intervention (RDI)',
  'Developmental Therapy',
  'Music Therapy',
  'Art Therapy',
  'Feeding Therapy',
];
