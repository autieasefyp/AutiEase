import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/duration_utils.dart';

DateTime? dateTimeFromFirestore(dynamic value) {
  if (value is Timestamp) {
    return value.toDate();
  }
  if (value is DateTime) {
    return value;
  }
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}

List<String> stringListFrom(dynamic value) {
  if (value is List) {
    return value.map((item) => item.toString()).toList();
  }
  return const [];
}

Map<String, dynamic> mapFrom(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}

Map<String, bool> boolMapFrom(dynamic value) {
  final raw = mapFrom(value);
  return raw.map(
    (key, item) => MapEntry(
      key,
      item is bool ? item : item.toString().toLowerCase() == 'true',
    ),
  );
}

int intFrom(dynamic value, [int fallback = 0]) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

enum AppSessionState {
  unauthenticated,
  incompleteProfile,
  emailVerificationPending,
  parent,
  therapist,
}

class AppSession {
  const AppSession({
    required this.state,
    this.uid,
    this.role,
    this.activeChildId,
  });

  final AppSessionState state;
  final String? uid;
  final String? role;
  final String? activeChildId;
}

class UserProfile {
  const UserProfile({
    required this.uid,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.role,
    required this.status,
    required this.phone,
    required this.photoUrl,
    required this.subscriptionTier,
    required this.entitlements,
    required this.notificationPreferences,
    this.activeChildId,
    this.createdAt,
    this.updatedAt,
  });

  final String uid;
  final String email;
  final String firstName;
  final String lastName;
  final String role;
  final String status;
  final String phone;
  final String photoUrl;
  final String subscriptionTier;
  final Map<String, bool> entitlements;
  final Map<String, bool> notificationPreferences;
  final String? activeChildId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get fullName => '$firstName $lastName'.trim();

  factory UserProfile.fromMap(String uid, Map<String, dynamic> data) {
    return UserProfile(
      uid: uid,
      email: (data['email'] ?? '').toString(),
      firstName: (data['firstName'] ?? '').toString(),
      lastName: (data['lastName'] ?? '').toString(),
      role: (data['role'] ?? '').toString(),
      status: (data['status'] ?? '').toString(),
      phone: (data['phone'] ?? '').toString(),
      photoUrl: (data['photoUrl'] ?? '').toString(),
      subscriptionTier: (data['subscriptionTier'] ?? 'free').toString(),
      entitlements: boolMapFrom(data['entitlements']),
      notificationPreferences: boolMapFrom(data['notificationPreferences']),
      activeChildId: data['activeChildId']?.toString(),
      createdAt: dateTimeFromFirestore(data['createdAt']),
      updatedAt: dateTimeFromFirestore(data['updatedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'email': email,
      'firstName': firstName,
      'lastName': lastName,
      'fullName': fullName,
      'role': role,
      'status': status,
      'phone': phone,
      'photoUrl': photoUrl,
      'subscriptionTier': subscriptionTier,
      'entitlements': entitlements,
      'notificationPreferences': notificationPreferences,
      'activeChildId': activeChildId,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }
}

class ChildProfile {
  const ChildProfile({
    required this.id,
    required this.parentId,
    required this.name,
    required this.avatar,
    required this.supportAreas,
    required this.status,
    this.activePlanId,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String parentId;
  final String name;
  final String avatar;
  final List<String> supportAreas;
  final String status;
  final String? activePlanId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory ChildProfile.fromMap(String id, Map<String, dynamic> data) {
    return ChildProfile(
      id: id,
      parentId: (data['parentId'] ?? '').toString(),
      name: (data['name'] ?? '').toString(),
      avatar: (data['avatar'] ?? '').toString(),
      supportAreas: stringListFrom(data['supportAreas']),
      status: (data['status'] ?? 'active').toString(),
      activePlanId: data['activePlanId']?.toString(),
      createdAt: dateTimeFromFirestore(data['createdAt']),
      updatedAt: dateTimeFromFirestore(data['updatedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'parentId': parentId,
      'name': name,
      'avatar': avatar,
      'supportAreas': supportAreas,
      'status': status,
      'activePlanId': activePlanId,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }
}

class AppModule {
  const AppModule({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.routeKey,
    required this.targetRole,
    required this.sortOrder,
    required this.isActive,
    this.imageAsset = '',
  });

  final String id;
  final String title;
  final String subtitle;
  final String routeKey;
  final String targetRole;
  final int sortOrder;
  final bool isActive;
  final String imageAsset;

  factory AppModule.fromMap(String id, Map<String, dynamic> data) {
    return AppModule(
      id: id,
      title: (data['title'] ?? '').toString(),
      subtitle: (data['subtitle'] ?? '').toString(),
      routeKey: (data['routeKey'] ?? id).toString(),
      targetRole: (data['targetRole'] ?? '').toString(),
      sortOrder: intFrom(data['sortOrder']),
      isActive: data['isActive'] != false,
      imageAsset: (data['imageAsset'] ?? '').toString(),
    );
  }
}

class ProfessionalSupportFeatureFlags {
  const ProfessionalSupportFeatureFlags({
    required this.chatEnabled,
    required this.paymentsEnabled,
  });

  final bool chatEnabled;
  final bool paymentsEnabled;

  static const enabled = ProfessionalSupportFeatureFlags(
    chatEnabled: true,
    paymentsEnabled: true,
  );

  factory ProfessionalSupportFeatureFlags.fromAppModuleMap(
    Map<String, dynamic> data,
  ) {
    return ProfessionalSupportFeatureFlags(
      chatEnabled: data['chatEnabled'] != false,
      paymentsEnabled: data['paymentsEnabled'] != false,
    );
  }
}

class ContentCategory {
  const ContentCategory({
    required this.id,
    required this.type,
    required this.title,
    required this.icon,
    required this.imageUrl,
    required this.sortOrder,
    required this.isActive,
  });

  final String id;
  final String type;
  final String title;
  final String icon;
  final String imageUrl;
  final int sortOrder;
  final bool isActive;

  factory ContentCategory.fromMap(String id, Map<String, dynamic> data) {
    return ContentCategory(
      id: id,
      type: (data['type'] ?? '').toString(),
      title: (data['title'] ?? '').toString(),
      icon: (data['icon'] ?? '').toString(),
      imageUrl: (data['imageUrl'] ?? '').toString(),
      sortOrder: intFrom(data['sortOrder']),
      isActive: data['isActive'] != false,
    );
  }
}

class ContentItem {
  const ContentItem({
    required this.id,
    required this.categoryId,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.audioText,
    required this.level,
    required this.tags,
    required this.isActive,
  });

  final String id;
  final String categoryId;
  final String title;
  final String subtitle;
  final String imageUrl;
  final String audioText;
  final int level;
  final List<String> tags;
  final bool isActive;

  factory ContentItem.fromMap(String id, Map<String, dynamic> data) {
    return ContentItem(
      id: id,
      categoryId: (data['categoryId'] ?? '').toString(),
      title: (data['title'] ?? '').toString(),
      subtitle: (data['subtitle'] ?? '').toString(),
      imageUrl: (data['imageUrl'] ?? '').toString(),
      audioText: (data['audioText'] ?? '').toString(),
      level: intFrom(data['level'], 1),
      tags: stringListFrom(data['tags']),
      isActive: data['isActive'] != false,
    );
  }
}

class LearningModuleModel {
  const LearningModuleModel({
    required this.id,
    required this.title,
    required this.description,
    required this.type,
    required this.learningCategoryKey,
    required this.learningCategoryTitle,
    required this.gameTypeKey,
    required this.levelRange,
    required this.assetRefs,
    required this.sortOrder,
    required this.isActive,
  });

  final String id;
  final String title;
  final String description;
  final String type;
  final String learningCategoryKey;
  final String learningCategoryTitle;
  final String gameTypeKey;
  final String levelRange;
  final List<String> assetRefs;
  final int sortOrder;
  final bool isActive;

  factory LearningModuleModel.fromMap(String id, Map<String, dynamic> data) {
    return LearningModuleModel(
      id: id,
      title: (data['title'] ?? '').toString(),
      description: (data['description'] ?? '').toString(),
      type: (data['type'] ?? '').toString(),
      learningCategoryKey: (data['learningCategoryKey'] ?? 'general')
          .toString()
          .trim(),
      learningCategoryTitle: (data['learningCategoryTitle'] ?? 'General')
          .toString()
          .trim(),
      gameTypeKey: (data['gameTypeKey'] ?? id).toString().trim(),
      levelRange: (data['levelRange'] ?? '').toString(),
      assetRefs: stringListFrom(data['assetRefs']),
      sortOrder: intFrom(data['sortOrder']),
      isActive: data['isActive'] != false,
    );
  }
}

class DailyActivityTemplate {
  const DailyActivityTemplate({
    required this.id,
    required this.title,
    required this.description,
    required this.moduleRefs,
    required this.estimatedMinutes,
    required this.difficulty,
    required this.isActive,
  });

  final String id;
  final String title;
  final String description;
  final List<String> moduleRefs;
  final int estimatedMinutes;
  final String difficulty;
  final bool isActive;

  factory DailyActivityTemplate.fromMap(String id, Map<String, dynamic> data) {
    return DailyActivityTemplate(
      id: id,
      title: (data['title'] ?? '').toString(),
      description: (data['description'] ?? '').toString(),
      moduleRefs: stringListFrom(data['moduleRefs']),
      estimatedMinutes: intFrom(data['estimatedMinutes']),
      difficulty: (data['difficulty'] ?? 'easy').toString(),
      isActive: data['isActive'] != false,
    );
  }
}

class CustomDailyActivity {
  const CustomDailyActivity({
    required this.id,
    required this.title,
    required this.durationMinutes,
    this.createdAt,
  });

  final String id;
  final String title;
  final int durationMinutes;
  final DateTime? createdAt;

  factory CustomDailyActivity.fromMap(Map<String, dynamic> data) {
    final storedDuration = intFrom(data['durationMinutes']);
    final parsedLegacyDuration = parseDurationLabelToMinutes(
      (data['timeLabel'] ?? '').toString(),
    );
    final resolvedDuration = storedDuration > 0
        ? storedDuration
        : normalizeDurationMinutes(parsedLegacyDuration);

    return CustomDailyActivity(
      id: (data['id'] ?? '').toString(),
      title: (data['title'] ?? '').toString(),
      durationMinutes: resolvedDuration,
      createdAt: dateTimeFromFirestore(data['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'durationMinutes': normalizeDurationMinutes(durationMinutes),
      // Keep legacy field for backward compatibility with older builds.
      'timeLabel': formatDurationLabel(durationMinutes),
      'createdAt': createdAt,
    };
  }
}

class ChildAssignment {
  const ChildAssignment({
    required this.id,
    required this.childId,
    required this.parentId,
    required this.assignedCategoryIds,
    required this.assignedModuleIds,
    required this.assignedActivityTemplateIds,
    required this.status,
    this.customDailyActivities = const <CustomDailyActivity>[],
    this.effectiveFrom,
  });

  final String id;
  final String childId;
  final String parentId;
  final List<String> assignedCategoryIds;
  final List<String> assignedModuleIds;
  final List<String> assignedActivityTemplateIds;
  final String status;
  final List<CustomDailyActivity> customDailyActivities;
  final DateTime? effectiveFrom;

  factory ChildAssignment.fromMap(String id, Map<String, dynamic> data) {
    return ChildAssignment(
      id: id,
      childId: (data['childId'] ?? '').toString(),
      parentId: (data['parentId'] ?? '').toString(),
      assignedCategoryIds: stringListFrom(data['assignedCategoryIds']),
      assignedModuleIds: stringListFrom(data['assignedModuleIds']),
      assignedActivityTemplateIds: stringListFrom(
        data['assignedActivityTemplateIds'],
      ),
      status: (data['status'] ?? 'draft').toString(),
      customDailyActivities: (data['customDailyActivities'] is List)
          ? (data['customDailyActivities'] as List)
                .map((item) => CustomDailyActivity.fromMap(mapFrom(item)))
                .where((item) => item.id.isNotEmpty && item.title.isNotEmpty)
                .toList()
          : const <CustomDailyActivity>[],
      effectiveFrom: dateTimeFromFirestore(data['effectiveFrom']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'childId': childId,
      'parentId': parentId,
      'assignedCategoryIds': assignedCategoryIds,
      'assignedModuleIds': assignedModuleIds,
      'assignedActivityTemplateIds': assignedActivityTemplateIds,
      'status': status,
      'customDailyActivities': customDailyActivities
          .map((item) => item.toMap())
          .toList(),
      'effectiveFrom': effectiveFrom,
    };
  }
}

class DashboardSnapshot {
  const DashboardSnapshot({
    required this.childId,
    required this.completedTasks,
    required this.weeklyMinutes,
    required this.streakDays,
    required this.moodEntries,
    required this.lastUpdated,
  });

  final String childId;
  final int completedTasks;
  final int weeklyMinutes;
  final int streakDays;
  final int moodEntries;
  final DateTime? lastUpdated;

  factory DashboardSnapshot.fromMap(String childId, Map<String, dynamic> data) {
    return DashboardSnapshot(
      childId: childId,
      completedTasks: intFrom(data['completedTasks']),
      weeklyMinutes: intFrom(data['weeklyMinutes']),
      streakDays: intFrom(data['streakDays']),
      moodEntries: intFrom(data['moodEntries']),
      lastUpdated: dateTimeFromFirestore(data['lastUpdated']),
    );
  }
}

class ActivityProgressEntry {
  const ActivityProgressEntry({
    required this.id,
    required this.childId,
    required this.itemId,
    required this.moduleId,
    required this.status,
    required this.score,
    required this.attempts,
    this.completedAt,
  });

  final String id;
  final String childId;
  final String itemId;
  final String? moduleId;
  final String status;
  final int score;
  final int attempts;
  final DateTime? completedAt;

  factory ActivityProgressEntry.fromMap(String id, Map<String, dynamic> data) {
    return ActivityProgressEntry(
      id: id,
      childId: (data['childId'] ?? '').toString(),
      itemId: (data['itemId'] ?? '').toString(),
      moduleId: data['moduleId']?.toString(),
      status: (data['status'] ?? 'completed').toString(),
      score: intFrom(data['score']),
      attempts: intFrom(data['attempts'], 1),
      completedAt: dateTimeFromFirestore(data['completedAt']),
    );
  }
}

class MoodLogEntry {
  const MoodLogEntry({
    required this.id,
    required this.childId,
    required this.emotion,
    required this.note,
    this.createdAt,
  });

  final String id;
  final String childId;
  final String emotion;
  final String note;
  final DateTime? createdAt;

  factory MoodLogEntry.fromMap(String id, Map<String, dynamic> data) {
    return MoodLogEntry(
      id: id,
      childId: (data['childId'] ?? '').toString(),
      emotion: (data['emotion'] ?? '').toString(),
      note: (data['note'] ?? '').toString(),
      createdAt: dateTimeFromFirestore(data['createdAt']),
    );
  }
}

class DashboardReportSection {
  const DashboardReportSection({
    required this.title,
    required this.progressValue,
    required this.body,
    required this.statusLabel,
  });

  final String title;
  final double progressValue;
  final String body;
  final String statusLabel;
}

class DashboardReport {
  const DashboardReport({
    required this.title,
    required this.dateLabel,
    required this.summarySubtitle,
    required this.summaryText,
    required this.sections,
    required this.recommendations,
  });

  final String title;
  final String dateLabel;
  final String summarySubtitle;
  final String summaryText;
  final List<DashboardReportSection> sections;
  final List<String> recommendations;
}

class DashboardMetrics {
  const DashboardMetrics({
    required this.childId,
    required this.completedActivities,
    required this.weeklyMinutes,
    required this.monthlyCompletedActivities,
    required this.monthlyMinutes,
    required this.activityLevel,
    required this.moodLabel,
    required this.movePlayProgress,
    required this.talkExpressProgress,
    required this.focusGamesProgress,
    required this.weeklyReport,
    required this.monthlyReport,
    required this.generatedAt,
  });

  final String childId;
  final int completedActivities;
  final int weeklyMinutes;
  final int monthlyCompletedActivities;
  final int monthlyMinutes;
  final String activityLevel;
  final String moodLabel;
  final double movePlayProgress;
  final double talkExpressProgress;
  final double focusGamesProgress;
  final DashboardReport weeklyReport;
  final DashboardReport monthlyReport;
  final DateTime generatedAt;

  factory DashboardMetrics.empty(String childId) {
    const emptySections = <DashboardReportSection>[
      DashboardReportSection(
        title: 'Move & Play',
        progressValue: 0,
        body: 'No tracked activity yet.',
        statusLabel: 'No Data',
      ),
      DashboardReportSection(
        title: 'Talk & Express',
        progressValue: 0,
        body: 'No tracked activity yet.',
        statusLabel: 'No Data',
      ),
      DashboardReportSection(
        title: 'Focus Games',
        progressValue: 0,
        body: 'No tracked activity yet.',
        statusLabel: 'No Data',
      ),
    ];
    return DashboardMetrics(
      childId: childId,
      completedActivities: 0,
      weeklyMinutes: 0,
      monthlyCompletedActivities: 0,
      monthlyMinutes: 0,
      activityLevel: 'Low',
      moodLabel: 'Not set',
      movePlayProgress: 0,
      talkExpressProgress: 0,
      focusGamesProgress: 0,
      weeklyReport: const DashboardReport(
        title: 'Weekly Progress Report',
        dateLabel: '',
        summarySubtitle: 'Progress',
        summaryText: 'No activity has been tracked this week yet.',
        sections: emptySections,
        recommendations: <String>[
          'Start with one short learning session today.',
          'Use Learning Planner to assign activities.',
        ],
      ),
      monthlyReport: const DashboardReport(
        title: 'Monthly Assessment',
        dateLabel: '',
        summarySubtitle: 'Assessment',
        summaryText: 'No activity has been tracked this month yet.',
        sections: emptySections,
        recommendations: <String>[
          'Assign modules and daily activities in Learning Planner.',
          'Track a few sessions to unlock monthly insights.',
        ],
      ),
      generatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class TherapistProfile {
  const TherapistProfile({
    required this.id,
    required this.displayName,
    required this.bio,
    required this.specializations,
    required this.pricing,
    required this.languages,
    required this.rating,
    required this.availability,
    required this.photoUrl,
    required this.isActive,
    this.yearsOfExperience = 0,
    this.certificatePdfName = '',
    this.certificateUrl = '',
    this.reportSuggestions = const <String>[],
  });

  final String id;
  final String displayName;
  final String bio;
  final List<String> specializations;
  final String pricing;
  final List<String> languages;
  final double rating;
  final String availability;
  final String photoUrl;
  final bool isActive;
  final int yearsOfExperience;
  final String certificatePdfName;
  final String certificateUrl;
  final List<String> reportSuggestions;

  factory TherapistProfile.fromMap(String id, Map<String, dynamic> data) {
    final rawRating = data['rating'];
    return TherapistProfile(
      id: id,
      displayName: (data['displayName'] ?? '').toString(),
      bio: (data['bio'] ?? '').toString(),
      specializations: stringListFrom(data['specializations']),
      pricing: (data['pricing'] ?? '').toString(),
      languages: stringListFrom(data['languages']),
      rating: rawRating is num ? rawRating.toDouble() : 0,
      availability: (data['availability'] ?? '').toString(),
      photoUrl: (data['photoUrl'] ?? '').toString(),
      isActive: data['isActive'] != false,
      yearsOfExperience: intFrom(data['yearsOfExperience']),
      certificatePdfName: (data['certificatePdfName'] ?? '').toString(),
      certificateUrl: (data['certificateUrl'] ?? '').toString(),
      reportSuggestions: stringListFrom(data['reportSuggestions']),
    );
  }
}

class TherapistThread {
  const TherapistThread({
    required this.id,
    required this.parentId,
    required this.therapistId,
    required this.childId,
    required this.subscriptionId,
    required this.status,
    this.parentDisplayName = '',
    this.therapistDisplayName = '',
    this.lastMessagePreview = '',
    this.lastMessageAt,
    this.emergencyStatus = 'none',
    this.emergencyRequestedBy,
    this.emergencyRequestedAt,
    this.emergencyRespondedAt,
    this.postCancelVisible = true,
  });

  final String id;
  final String parentId;
  final String therapistId;
  final String childId;
  final String subscriptionId;
  final String status;
  final String parentDisplayName;
  final String therapistDisplayName;
  final String lastMessagePreview;
  final DateTime? lastMessageAt;
  final String emergencyStatus;
  final String? emergencyRequestedBy;
  final DateTime? emergencyRequestedAt;
  final DateTime? emergencyRespondedAt;
  final bool postCancelVisible;

  bool get hasOpenEmergency => emergencyStatus == 'requested';
  bool get emergencyResponded => emergencyStatus == 'responded';

  factory TherapistThread.fromMap(String id, Map<String, dynamic> data) {
    return TherapistThread(
      id: id,
      parentId: (data['parentId'] ?? '').toString(),
      therapistId: (data['therapistId'] ?? '').toString(),
      childId: (data['childId'] ?? '').toString(),
      subscriptionId: (data['subscriptionId'] ?? '').toString(),
      status: (data['status'] ?? 'active').toString(),
      parentDisplayName: (data['parentDisplayName'] ?? '').toString(),
      therapistDisplayName: (data['therapistDisplayName'] ?? '').toString(),
      lastMessagePreview: (data['lastMessagePreview'] ?? '').toString(),
      lastMessageAt: dateTimeFromFirestore(data['lastMessageAt']),
      emergencyStatus: (data['emergencyStatus'] ?? 'none').toString(),
      emergencyRequestedBy: data['emergencyRequestedBy']?.toString(),
      emergencyRequestedAt: dateTimeFromFirestore(data['emergencyRequestedAt']),
      emergencyRespondedAt: dateTimeFromFirestore(data['emergencyRespondedAt']),
      postCancelVisible: data['postCancelVisible'] != false,
    );
  }

  TherapistThread copyWith({
    String? parentDisplayName,
    String? therapistDisplayName,
    String? lastMessagePreview,
    DateTime? lastMessageAt,
    String? status,
    String? emergencyStatus,
    String? emergencyRequestedBy,
    DateTime? emergencyRequestedAt,
    DateTime? emergencyRespondedAt,
    bool? postCancelVisible,
  }) {
    return TherapistThread(
      id: id,
      parentId: parentId,
      therapistId: therapistId,
      childId: childId,
      subscriptionId: subscriptionId,
      status: status ?? this.status,
      parentDisplayName: parentDisplayName ?? this.parentDisplayName,
      therapistDisplayName: therapistDisplayName ?? this.therapistDisplayName,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      emergencyStatus: emergencyStatus ?? this.emergencyStatus,
      emergencyRequestedBy: emergencyRequestedBy ?? this.emergencyRequestedBy,
      emergencyRequestedAt: emergencyRequestedAt ?? this.emergencyRequestedAt,
      emergencyRespondedAt: emergencyRespondedAt ?? this.emergencyRespondedAt,
      postCancelVisible: postCancelVisible ?? this.postCancelVisible,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'parentId': parentId,
      'therapistId': therapistId,
      'childId': childId,
      'subscriptionId': subscriptionId,
      'status': status,
      'parentDisplayName': parentDisplayName,
      'therapistDisplayName': therapistDisplayName,
      'lastMessagePreview': lastMessagePreview,
      'lastMessageAt': lastMessageAt,
      'emergencyStatus': emergencyStatus,
      'emergencyRequestedBy': emergencyRequestedBy,
      'emergencyRequestedAt': emergencyRequestedAt,
      'emergencyRespondedAt': emergencyRespondedAt,
      'postCancelVisible': postCancelVisible,
    };
  }
}

class TherapistMessage {
  const TherapistMessage({
    required this.id,
    required this.senderId,
    required this.senderRole,
    required this.body,
    required this.attachments,
    this.sentAt,
    this.messageType = 'text',
    this.deliveryStatus = 'sent',
    this.deliveryError,
  });

  final String id;
  final String senderId;
  final String senderRole;
  final String body;
  final List<String> attachments;
  final DateTime? sentAt;
  final String messageType;
  final String deliveryStatus;
  final String? deliveryError;

  factory TherapistMessage.fromMap(String id, Map<String, dynamic> data) {
    return TherapistMessage(
      id: id,
      senderId: (data['senderId'] ?? '').toString(),
      senderRole: (data['senderRole'] ?? '').toString(),
      body: (data['body'] ?? '').toString(),
      attachments: stringListFrom(data['attachments']),
      sentAt: dateTimeFromFirestore(data['sentAt']),
      messageType: (data['messageType'] ?? 'text').toString(),
      deliveryStatus: (data['deliveryStatus'] ?? 'sent').toString(),
      deliveryError: data['deliveryError']?.toString(),
    );
  }
}

class SubscriptionProduct {
  const SubscriptionProduct({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.featureList,
    required this.priceLabel,
    required this.billingPlanId,
    required this.amount,
    required this.isActive,
  });

  final String id;
  final String title;
  final String subtitle;
  final List<String> featureList;
  final String priceLabel;
  final String billingPlanId;
  final double amount;
  final bool isActive;

  factory SubscriptionProduct.fromMap(String id, Map<String, dynamic> data) {
    final rawAmount = data['amount'];
    return SubscriptionProduct(
      id: id,
      title: (data['title'] ?? '').toString(),
      subtitle: (data['subtitle'] ?? '').toString(),
      featureList: stringListFrom(data['featureList']),
      priceLabel: (data['priceLabel'] ?? '').toString(),
      billingPlanId: (data['billingPlanId'] ?? '').toString(),
      amount: rawAmount is num
          ? rawAmount.toDouble()
          : double.tryParse(rawAmount?.toString() ?? '') ?? 0,
      isActive: data['isActive'] != false,
    );
  }
}

class UserSubscription {
  const UserSubscription({
    required this.id,
    required this.userId,
    required this.productId,
    required this.status,
    required this.cancelAtPeriodEnd,
    this.currentPeriodEnd,
    this.provider = '',
    this.providerTransactionId = '',
    this.providerCustomerRef = '',
    this.lastPaymentRef = '',
  });

  final String id;
  final String userId;
  final String productId;
  final String status;
  final bool cancelAtPeriodEnd;
  final DateTime? currentPeriodEnd;
  final String provider;
  final String providerTransactionId;
  final String providerCustomerRef;
  final String lastPaymentRef;

  bool get isActive => status == 'active' || status == 'trialing';

  factory UserSubscription.fromMap(String id, Map<String, dynamic> data) {
    return UserSubscription(
      id: id,
      userId: (data['userId'] ?? '').toString(),
      productId: (data['productId'] ?? '').toString(),
      status: (data['status'] ?? 'inactive').toString(),
      cancelAtPeriodEnd: data['cancelAtPeriodEnd'] == true,
      currentPeriodEnd: dateTimeFromFirestore(data['currentPeriodEnd']),
      provider: (data['provider'] ?? '').toString(),
      providerTransactionId: (data['providerTransactionId'] ?? '').toString(),
      providerCustomerRef: (data['providerCustomerRef'] ?? '').toString(),
      lastPaymentRef: (data['lastPaymentRef'] ?? '').toString(),
    );
  }
}

class LegalDocument {
  const LegalDocument({
    required this.id,
    required this.audience,
    required this.version,
    required this.title,
    required this.body,
    required this.isActive,
  });

  final String id;
  final String audience;
  final String version;
  final String title;
  final String body;
  final bool isActive;

  factory LegalDocument.fromMap(String id, Map<String, dynamic> data) {
    return LegalDocument(
      id: id,
      audience: (data['audience'] ?? '').toString(),
      version: (data['version'] ?? 'v1').toString(),
      title: (data['title'] ?? '').toString(),
      body: (data['body'] ?? '').toString(),
      isActive: data['isActive'] != false,
    );
  }
}

class SettingsEntry {
  const SettingsEntry({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.routeKey,
    required this.targetRole,
    required this.sortOrder,
    required this.isActive,
  });

  final String id;
  final String title;
  final String subtitle;
  final String routeKey;
  final String targetRole;
  final int sortOrder;
  final bool isActive;

  factory SettingsEntry.fromMap(String id, Map<String, dynamic> data) {
    return SettingsEntry(
      id: id,
      title: (data['title'] ?? '').toString(),
      subtitle: (data['subtitle'] ?? '').toString(),
      routeKey: (data['routeKey'] ?? '').toString(),
      targetRole: (data['targetRole'] ?? '').toString(),
      sortOrder: intFrom(data['sortOrder']),
      isActive: data['isActive'] != false,
    );
  }
}
