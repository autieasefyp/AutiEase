import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_runtime_config.dart';
import '../models/app_models.dart';
import '../services/auth_verification_policy.dart';
import '../services/dashboard_metrics_calculator.dart';
import '../services/payment_backend_client.dart';

class FirestoreCollections {
  static const users = 'users';
  static const childProfiles = 'child_profiles';
  static const therapistProfiles = 'therapist_profiles';
  static const contentCategories = 'content_categories';
  static const contentItems = 'content_items';
  static const learningModules = 'learning_modules';
  static const dailyActivityTemplates = 'daily_activity_templates';
  static const childAssignments = 'child_assignments';
  static const activityProgress = 'activity_progress';
  static const moodLogs = 'mood_logs';
  static const dashboardSnapshots = 'dashboard_snapshots';
  static const therapistThreads = 'therapist_threads';
  static const subscriptionProducts = 'subscription_products';
  static const subscriptions = 'subscriptions';
  static const legalDocuments = 'legal_documents';
  static const appModules = 'app_modules';
  static const settingsEntries = 'settings_entries';
  static const feedback = 'feedback';
}

abstract class AuthRepository {
  User? get currentUser;
  Future<AppSession> resolveSession();
  Future<void> signOut();
}

abstract class UserRepository {
  Future<UserProfile?> getCurrentUserProfile();
  Future<UserProfile?> getUserProfile(String uid);
  Future<ChildProfile?> getActiveChildForCurrentParent();
  Future<List<ChildProfile>> getChildrenForParent(String parentId);
  Future<void> upsertParentProfile(UserProfile profile);
  Future<void> upsertChildProfile(ChildProfile profile);
  Future<void> upsertTherapistProfile(TherapistProfile profile);
  Future<void> updateNotificationPreferences(Map<String, bool> preferences);
  Future<void> updateCurrentUser(Map<String, dynamic> data);
}

abstract class ContentRepository {
  Stream<List<AppModule>> watchModules(String targetRole);
  Stream<ProfessionalSupportFeatureFlags>
  watchProfessionalSupportFeatureFlags();
  Future<ProfessionalSupportFeatureFlags> getProfessionalSupportFeatureFlags();
  Future<List<ContentCategory>> getAssignedCategories(
    String childId, {
    String? type,
  });
  Future<List<ContentItem>> getItemsForCategory(String categoryId);
  Future<List<LearningModuleModel>> getAssignedLearningModules(String childId);
  Future<List<DailyActivityTemplate>> getAssignedActivities(String childId);
  Future<List<ContentItem>> getAllContentItems();
  Future<List<SettingsEntry>> getSettingsEntries(String targetRole);
  Future<LegalDocument?> getLegalDocument(String audience, String documentId);
  Future<List<ContentCategory>> getAllCategories({String? type});
  Future<List<LearningModuleModel>> getAllLearningModules();
  Future<List<DailyActivityTemplate>> getAllActivityTemplates();
}

abstract class PlannerRepository {
  Future<ChildAssignment?> getAssignmentForChild(String childId);
  Future<void> saveAssignment(ChildAssignment assignment);
  Stream<DashboardSnapshot?> watchDashboard(String childId);
  Stream<DashboardMetrics?> watchDashboardMetrics(String childId);
  Future<void> recordMood({
    required String childId,
    required String emotion,
    String note,
  });
  Future<void> recordActivityCompletion({
    required String childId,
    required String itemId,
    String? moduleId,
    int score,
  });
  Future<void> undoActivityCompletion({
    required String childId,
    required String itemId,
  });
}

abstract class SupportRepository {
  Future<List<TherapistProfile>> listTherapists();
  Future<TherapistProfile?> getTherapistById(String therapistId);
  Stream<List<TherapistThread>> watchThreadsForRole(String role);
  Stream<TherapistThread?> watchThread(String threadId);
  Future<TherapistThread> ensureThread({
    required String therapistId,
    required String childId,
    required String subscriptionId,
  });
  Stream<List<TherapistMessage>> watchMessages(String threadId);
  Future<void> sendMessage({
    required String threadId,
    required String senderRole,
    required String body,
  });
  Future<void> requestEmergency({
    required String threadId,
    required String requestedByRole,
  });
  Future<void> resolveEmergency({
    required String threadId,
    required String resolvedByRole,
  });
}

abstract class BillingRepository {
  Future<UserSubscription?> getSubscriptionForTherapist(String therapistId);
  Stream<UserSubscription?> watchSubscriptionForTherapist(String therapistId);
  Future<bool> purchaseTherapistSubscription(String therapistId);
  Future<void> restorePurchases();
  Future<void> syncSubscriptions();
  Future<void> cancelSubscriptionInStore(String therapistId);
}

class AppRepositories {
  AppRepositories._();

  static final FirebaseFirestore firestore = FirebaseFirestore.instance;
  static final FirebaseAuth authClient = FirebaseAuth.instance;

  static final AuthRepository auth = FirebaseAuthRepository(
    authClient,
    firestore,
  );
  static final UserRepository users = FirebaseUserRepository(
    authClient,
    firestore,
  );
  static final ContentRepository content = FirebaseContentRepository(firestore);
  static final PlannerRepository planner = FirebasePlannerRepository(firestore);
  static final SupportRepository support = FirebaseSupportRepository(
    authClient,
    firestore,
  );
  static final BillingRepository billing = FirebaseBillingRepository(
    authClient,
    firestore,
  );
}

class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository(this._auth, this._firestore);

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  @override
  User? get currentUser => _auth.currentUser;

  @override
  Future<AppSession> resolveSession() async {
    var user = currentUser;
    if (user == null) {
      return const AppSession(state: AppSessionState.unauthenticated);
    }

    try {
      await user.getIdToken(true);
      await user.reload();
      user = _auth.currentUser;
    } catch (_) {
      // If refresh fails, continue with the last known auth user and let the
      // downstream checks decide whether the session is usable.
    }

    if (user == null) {
      return const AppSession(state: AppSessionState.unauthenticated);
    }

    final isGoogleUser = user.providerData.any(
      (provider) => provider.providerId == 'google.com',
    );

    final doc = await _firestore
        .collection(FirestoreCollections.users)
        .doc(user.uid)
        .get();

    if (!doc.exists || doc.data() == null) {
      return AppSession(
        state: AppSessionState.incompleteProfile,
        uid: user.uid,
      );
    }

    final profile = UserProfile.fromMap(doc.id, doc.data()!);
    if (profile.role.isEmpty) {
      return AppSession(
        state: AppSessionState.incompleteProfile,
        uid: user.uid,
      );
    }

    if (requiresEmailVerification(
      isGoogleUser: isGoogleUser,
      isEmailVerified: user.emailVerified,
    )) {
      return AppSession(
        state: AppSessionState.emailVerificationPending,
        uid: user.uid,
      );
    }

    if (profile.role == 'parent') {
      final childSnapshot = await _firestore
          .collection(FirestoreCollections.childProfiles)
          .where('parentId', isEqualTo: profile.uid)
          .limit(1)
          .get();
      if (childSnapshot.docs.isEmpty) {
        return AppSession(
          state: AppSessionState.incompleteProfile,
          uid: profile.uid,
          role: profile.role,
        );
      }
      return AppSession(
        state: AppSessionState.parent,
        uid: profile.uid,
        role: profile.role,
        activeChildId: profile.activeChildId,
      );
    }

    if (profile.role == 'therapist') {
      return AppSession(
        state: AppSessionState.therapist,
        uid: profile.uid,
        role: profile.role,
      );
    }

    return AppSession(
      state: AppSessionState.incompleteProfile,
      uid: profile.uid,
      role: profile.role,
    );
  }

  @override
  Future<void> signOut() => _auth.signOut();
}

class FirebaseUserRepository implements UserRepository {
  FirebaseUserRepository(this._auth, this._firestore);

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection(FirestoreCollections.users);

  CollectionReference<Map<String, dynamic>> get _children =>
      _firestore.collection(FirestoreCollections.childProfiles);

  CollectionReference<Map<String, dynamic>> get _therapists =>
      _firestore.collection(FirestoreCollections.therapistProfiles);

  @override
  Future<UserProfile?> getCurrentUserProfile() async {
    final user = _auth.currentUser;
    if (user == null) {
      return null;
    }
    return getUserProfile(user.uid);
  }

  @override
  Future<UserProfile?> getUserProfile(String uid) async {
    final doc = await _users.doc(uid).get();
    if (!doc.exists || doc.data() == null) {
      return null;
    }
    return UserProfile.fromMap(doc.id, doc.data()!);
  }

  @override
  Future<List<ChildProfile>> getChildrenForParent(String parentId) async {
    final snapshot = await _children
        .where('parentId', isEqualTo: parentId)
        .orderBy('name')
        .get();
    return snapshot.docs
        .map((doc) => ChildProfile.fromMap(doc.id, doc.data()))
        .toList();
  }

  @override
  Future<ChildProfile?> getActiveChildForCurrentParent() async {
    final profile = await getCurrentUserProfile();
    if (profile == null) {
      return null;
    }
    if (profile.activeChildId != null && profile.activeChildId!.isNotEmpty) {
      final activeDoc = await _children.doc(profile.activeChildId).get();
      if (activeDoc.exists && activeDoc.data() != null) {
        return ChildProfile.fromMap(activeDoc.id, activeDoc.data()!);
      }
    }

    final children = await getChildrenForParent(profile.uid);
    if (children.isEmpty) {
      return null;
    }

    final activeChild = children.first;
    await _users.doc(profile.uid).set({
      'activeChildId': activeChild.id,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    return activeChild;
  }

  @override
  Future<void> updateCurrentUser(Map<String, dynamic> data) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('No logged in user');
    }
    await _users.doc(user.uid).set({
      ...data,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  @override
  Future<void> updateNotificationPreferences(
    Map<String, bool> preferences,
  ) async {
    await updateCurrentUser({'notificationPreferences': preferences});
  }

  @override
  Future<void> upsertParentProfile(UserProfile profile) async {
    await _users.doc(profile.uid).set({
      ...profile.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': profile.createdAt ?? FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  @override
  Future<void> upsertChildProfile(ChildProfile profile) async {
    await _children.doc(profile.id).set({
      ...profile.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': profile.createdAt ?? FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  @override
  Future<void> upsertTherapistProfile(TherapistProfile profile) async {
    await _therapists.doc(profile.id).set({
      'displayName': profile.displayName,
      'bio': profile.bio,
      'specializations': profile.specializations,
      'pricing': profile.pricing,
      'languages': profile.languages,
      'rating': profile.rating,
      'availability': profile.availability,
      'photoUrl': profile.photoUrl,
      'isActive': profile.isActive,
      'yearsOfExperience': profile.yearsOfExperience,
      'certificatePdfName': profile.certificatePdfName,
      'certificateUrl': profile.certificateUrl,
      'reportSuggestions': profile.reportSuggestions,
      'subscriptionProductId': profile.subscriptionProductId,
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}

class FirebaseContentRepository implements ContentRepository {
  FirebaseContentRepository(this._firestore);

  final FirebaseFirestore _firestore;
  static const _professionalSupportModuleId = 'professional_support';

  @override
  Stream<List<AppModule>> watchModules(String targetRole) {
    return _firestore
        .collection(FirestoreCollections.appModules)
        .where('targetRole', whereIn: [targetRole, 'all'])
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((snapshot) {
          final modules = snapshot.docs
              .map((doc) => AppModule.fromMap(doc.id, doc.data()))
              .toList();
          modules.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
          return modules;
        });
  }

  @override
  Stream<ProfessionalSupportFeatureFlags>
  watchProfessionalSupportFeatureFlags() {
    return _firestore
        .collection(FirestoreCollections.appModules)
        .doc(_professionalSupportModuleId)
        .snapshots()
        .map((snapshot) {
          if (!snapshot.exists || snapshot.data() == null) {
            return ProfessionalSupportFeatureFlags.enabled;
          }
          return ProfessionalSupportFeatureFlags.fromAppModuleMap(
            mapFrom(snapshot.data()),
          );
        });
  }

  @override
  Future<ProfessionalSupportFeatureFlags>
  getProfessionalSupportFeatureFlags() async {
    final snapshot = await _firestore
        .collection(FirestoreCollections.appModules)
        .doc(_professionalSupportModuleId)
        .get();
    if (!snapshot.exists || snapshot.data() == null) {
      return ProfessionalSupportFeatureFlags.enabled;
    }
    return ProfessionalSupportFeatureFlags.fromAppModuleMap(
      mapFrom(snapshot.data()),
    );
  }

  @override
  Future<List<ContentCategory>> getAllCategories({String? type}) async {
    Query<Map<String, dynamic>> query = _firestore
        .collection(FirestoreCollections.contentCategories)
        .where('isActive', isEqualTo: true);
    if (type != null && type.isNotEmpty) {
      query = query.where('type', isEqualTo: type);
    }
    final snapshot = await query.get();
    final categories = snapshot.docs
        .map((doc) => ContentCategory.fromMap(doc.id, doc.data()))
        .toList();
    categories.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return categories;
  }

  @override
  Future<List<ContentCategory>> getAssignedCategories(
    String childId, {
    String? type,
  }) async {
    final assignmentDoc = await _firestore
        .collection(FirestoreCollections.childAssignments)
        .doc(childId)
        .get();
    if (!assignmentDoc.exists || assignmentDoc.data() == null) {
      return const [];
    }

    final assignment = ChildAssignment.fromMap(childId, assignmentDoc.data()!);
    if (assignment.assignedCategoryIds.isEmpty) {
      return const [];
    }

    final snapshot = await _firestore
        .collection(FirestoreCollections.contentCategories)
        .where(FieldPath.documentId, whereIn: assignment.assignedCategoryIds)
        .get();

    final categories = snapshot.docs
        .map((doc) => ContentCategory.fromMap(doc.id, doc.data()))
        .where((category) => category.isActive)
        .where((category) => type == null || category.type == type)
        .toList();
    categories.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return categories;
  }

  @override
  Future<List<ContentItem>> getItemsForCategory(String categoryId) async {
    final snapshot = await _firestore
        .collection(FirestoreCollections.contentItems)
        .where('categoryId', isEqualTo: categoryId)
        .where('isActive', isEqualTo: true)
        .get();
    final items = snapshot.docs
        .map((doc) => ContentItem.fromMap(doc.id, doc.data()))
        .toList();
    items.sort((a, b) => a.level.compareTo(b.level));
    return items;
  }

  @override
  Future<List<ContentItem>> getAllContentItems() async {
    final snapshot = await _firestore
        .collection(FirestoreCollections.contentItems)
        .where('isActive', isEqualTo: true)
        .get();
    final items = snapshot.docs
        .map((doc) => ContentItem.fromMap(doc.id, doc.data()))
        .toList();
    items.sort((a, b) => a.title.compareTo(b.title));
    return items;
  }

  @override
  Future<List<LearningModuleModel>> getAllLearningModules() async {
    final snapshot = await _firestore
        .collection(FirestoreCollections.learningModules)
        .where('isActive', isEqualTo: true)
        .get();
    final modules = snapshot.docs
        .map((doc) => LearningModuleModel.fromMap(doc.id, doc.data()))
        .toList();
    modules.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return modules;
  }

  @override
  Future<List<DailyActivityTemplate>> getAllActivityTemplates() async {
    final snapshot = await _firestore
        .collection(FirestoreCollections.dailyActivityTemplates)
        .where('isActive', isEqualTo: true)
        .get();
    final activities = snapshot.docs
        .map((doc) => DailyActivityTemplate.fromMap(doc.id, doc.data()))
        .toList();
    activities.sort((a, b) => a.title.compareTo(b.title));
    return activities;
  }

  @override
  Future<List<LearningModuleModel>> getAssignedLearningModules(
    String childId,
  ) async {
    final assignmentDoc = await _firestore
        .collection(FirestoreCollections.childAssignments)
        .doc(childId)
        .get();
    if (!assignmentDoc.exists || assignmentDoc.data() == null) {
      return const [];
    }
    final assignment = ChildAssignment.fromMap(childId, assignmentDoc.data()!);
    if (assignment.assignedModuleIds.isEmpty) {
      return const [];
    }
    final snapshot = await _firestore
        .collection(FirestoreCollections.learningModules)
        .where(FieldPath.documentId, whereIn: assignment.assignedModuleIds)
        .get();
    final modules = snapshot.docs
        .map((doc) => LearningModuleModel.fromMap(doc.id, doc.data()))
        .where((module) => module.isActive)
        .toList();
    modules.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return modules;
  }

  @override
  Future<List<DailyActivityTemplate>> getAssignedActivities(
    String childId,
  ) async {
    final assignmentDoc = await _firestore
        .collection(FirestoreCollections.childAssignments)
        .doc(childId)
        .get();
    if (!assignmentDoc.exists || assignmentDoc.data() == null) {
      return const [];
    }
    final assignment = ChildAssignment.fromMap(childId, assignmentDoc.data()!);
    if (assignment.assignedActivityTemplateIds.isEmpty) {
      return const [];
    }
    final snapshot = await _firestore
        .collection(FirestoreCollections.dailyActivityTemplates)
        .where(
          FieldPath.documentId,
          whereIn: assignment.assignedActivityTemplateIds,
        )
        .get();
    return snapshot.docs
        .map((doc) => DailyActivityTemplate.fromMap(doc.id, doc.data()))
        .where((template) => template.isActive)
        .toList();
  }

  @override
  Future<LegalDocument?> getLegalDocument(
    String audience,
    String documentId,
  ) async {
    final doc = await _firestore
        .collection(FirestoreCollections.legalDocuments)
        .doc(documentId)
        .get();
    if (doc.exists && doc.data() != null) {
      final legal = LegalDocument.fromMap(doc.id, doc.data()!);
      if (legal.isActive && legal.audience == audience) {
        return legal;
      }
    }

    final snapshot = await _firestore
        .collection(FirestoreCollections.legalDocuments)
        .where('audience', isEqualTo: audience)
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();
    if (snapshot.docs.isEmpty) {
      return null;
    }
    return LegalDocument.fromMap(
      snapshot.docs.first.id,
      snapshot.docs.first.data(),
    );
  }

  @override
  Future<List<SettingsEntry>> getSettingsEntries(String targetRole) async {
    final snapshot = await _firestore
        .collection(FirestoreCollections.settingsEntries)
        .where('targetRole', whereIn: [targetRole, 'all'])
        .where('isActive', isEqualTo: true)
        .get();
    final entries = snapshot.docs
        .map((doc) => SettingsEntry.fromMap(doc.id, doc.data()))
        .toList();
    entries.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return entries;
  }
}

class FirebasePlannerRepository implements PlannerRepository {
  FirebasePlannerRepository(this._firestore);

  final FirebaseFirestore _firestore;
  final DashboardMetricsCalculator _calculator = DashboardMetricsCalculator();

  @override
  Future<ChildAssignment?> getAssignmentForChild(String childId) async {
    final doc = await _firestore
        .collection(FirestoreCollections.childAssignments)
        .doc(childId)
        .get();
    if (!doc.exists || doc.data() == null) {
      return null;
    }
    return ChildAssignment.fromMap(doc.id, doc.data()!);
  }

  @override
  Future<void> saveAssignment(ChildAssignment assignment) async {
    await _firestore
        .collection(FirestoreCollections.childAssignments)
        .doc(assignment.id)
        .set({
          ...assignment.toMap(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  @override
  Stream<DashboardSnapshot?> watchDashboard(String childId) {
    return _firestore
        .collection(FirestoreCollections.dashboardSnapshots)
        .doc(childId)
        .snapshots()
        .map((doc) {
          if (!doc.exists || doc.data() == null) {
            return null;
          }
          return DashboardSnapshot.fromMap(doc.id, doc.data()!);
        });
  }

  @override
  Stream<DashboardMetrics?> watchDashboardMetrics(String childId) {
    final progressStream = _firestore
        .collection(FirestoreCollections.activityProgress)
        .where('childId', isEqualTo: childId)
        .snapshots();
    final moodStream = _firestore
        .collection(FirestoreCollections.moodLogs)
        .where('childId', isEqualTo: childId)
        .snapshots();

    return Stream<DashboardMetrics?>.multi((controller) {
      QuerySnapshot<Map<String, dynamic>>? latestProgress;
      QuerySnapshot<Map<String, dynamic>>? latestMoods;
      var cancelled = false;

      Future<void> emitIfReady() async {
        if (cancelled || latestProgress == null || latestMoods == null) {
          return;
        }
        try {
          final metrics = await _buildMetrics(
            childId: childId,
            progressSnapshot: latestProgress!,
            moodSnapshot: latestMoods!,
          );
          if (!cancelled) {
            controller.add(metrics);
          }
        } catch (error, stackTrace) {
          if (!cancelled) {
            controller.addError(error, stackTrace);
          }
        }
      }

      final progressSub = progressStream.listen((snapshot) {
        latestProgress = snapshot;
        emitIfReady();
      }, onError: controller.addError);

      final moodSub = moodStream.listen((snapshot) {
        latestMoods = snapshot;
        emitIfReady();
      }, onError: controller.addError);

      controller.onCancel = () async {
        cancelled = true;
        await progressSub.cancel();
        await moodSub.cancel();
      };
    });
  }

  Future<DashboardMetrics> _buildMetrics({
    required String childId,
    required QuerySnapshot<Map<String, dynamic>> progressSnapshot,
    required QuerySnapshot<Map<String, dynamic>> moodSnapshot,
  }) async {
    final activityEvents = progressSnapshot.docs
        .map((doc) => ActivityProgressEntry.fromMap(doc.id, doc.data()))
        .where((event) => event.status.toLowerCase() == 'completed')
        .toList();
    final moodLogs = moodSnapshot.docs
        .map((doc) => MoodLogEntry.fromMap(doc.id, doc.data()))
        .toList();

    final assignment = await getAssignmentForChild(childId);
    final assignedModules = await _fetchLearningModules(
      assignment?.assignedModuleIds ?? const <String>[],
    );
    final assignedTemplates = await _fetchActivityTemplates(
      assignment?.assignedActivityTemplateIds ?? const <String>[],
    );

    return _calculator.build(
      childId: childId,
      activityEvents: activityEvents,
      moodLogs: moodLogs,
      assignedModules: assignedModules,
      assignedTemplates: assignedTemplates,
    );
  }

  Future<List<LearningModuleModel>> _fetchLearningModules(
    List<String> moduleIds,
  ) async {
    final normalizedIds = moduleIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (normalizedIds.isEmpty) {
      return const <LearningModuleModel>[];
    }
    final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final chunk in _chunkIds(normalizedIds)) {
      final snapshot = await _firestore
          .collection(FirestoreCollections.learningModules)
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      docs.addAll(snapshot.docs);
    }
    final modules = docs
        .map((doc) => LearningModuleModel.fromMap(doc.id, doc.data()))
        .where((module) => module.isActive)
        .toList();
    modules.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return modules;
  }

  Future<List<DailyActivityTemplate>> _fetchActivityTemplates(
    List<String> templateIds,
  ) async {
    final normalizedIds = templateIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (normalizedIds.isEmpty) {
      return const <DailyActivityTemplate>[];
    }
    final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final chunk in _chunkIds(normalizedIds)) {
      final snapshot = await _firestore
          .collection(FirestoreCollections.dailyActivityTemplates)
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      docs.addAll(snapshot.docs);
    }
    final templates = docs
        .map((doc) => DailyActivityTemplate.fromMap(doc.id, doc.data()))
        .where((template) => template.isActive)
        .toList();
    templates.sort((a, b) => a.title.compareTo(b.title));
    return templates;
  }

  Iterable<List<String>> _chunkIds(List<String> ids, {int size = 10}) sync* {
    if (ids.isEmpty) {
      return;
    }
    var index = 0;
    while (index < ids.length) {
      final end = (index + size) < ids.length ? index + size : ids.length;
      yield ids.sublist(index, end);
      index = end;
    }
  }

  @override
  Future<void> recordMood({
    required String childId,
    required String emotion,
    String note = '',
  }) async {
    await _firestore.collection(FirestoreCollections.moodLogs).add({
      'childId': childId,
      'emotion': emotion,
      'note': note,
      'source': 'app',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Future<void> recordActivityCompletion({
    required String childId,
    required String itemId,
    String? moduleId,
    int score = 0,
  }) async {
    await _firestore.collection(FirestoreCollections.activityProgress).add({
      'childId': childId,
      'itemId': itemId,
      'moduleId': moduleId,
      'status': 'completed',
      'score': score,
      'attempts': 1,
      'completedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Future<void> undoActivityCompletion({
    required String childId,
    required String itemId,
  }) async {
    await _firestore.collection(FirestoreCollections.activityProgress).add({
      'childId': childId,
      'itemId': itemId,
      'moduleId': itemId,
      'status': 'undone',
      'score': 0,
      'attempts': 1,
      'completedAt': FieldValue.serverTimestamp(),
    });
  }
}

class FirebaseSupportRepository implements SupportRepository {
  FirebaseSupportRepository(this._auth, this._firestore);

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  String _resolveParentDisplayName(Map<String, dynamic>? data) {
    if (data == null) {
      return '';
    }
    final firstName = (data['firstName'] ?? '').toString().trim();
    final lastName = (data['lastName'] ?? '').toString().trim();
    final fullName = '$firstName $lastName'.trim();
    if (fullName.isNotEmpty) {
      return fullName;
    }
    return (data['fullName'] ?? data['email'] ?? '').toString();
  }

  @override
  Future<TherapistProfile?> getTherapistById(String therapistId) async {
    final doc = await _firestore
        .collection(FirestoreCollections.therapistProfiles)
        .doc(therapistId)
        .get();
    if (!doc.exists || doc.data() == null) {
      return null;
    }
    return TherapistProfile.fromMap(doc.id, doc.data()!);
  }

  @override
  Future<List<TherapistProfile>> listTherapists() async {
    final snapshot = await _firestore
        .collection(FirestoreCollections.therapistProfiles)
        .where('isActive', isEqualTo: true)
        .get();
    final therapists = snapshot.docs
        .map((doc) => TherapistProfile.fromMap(doc.id, doc.data()))
        .toList();
    therapists.sort((a, b) => b.rating.compareTo(a.rating));
    return therapists;
  }

  @override
  Stream<List<TherapistThread>> watchThreadsForRole(String role) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      return const Stream<List<TherapistThread>>.empty();
    }

    final field = role == 'therapist' ? 'therapistId' : 'parentId';
    return _firestore
        .collection(FirestoreCollections.therapistThreads)
        .where(field, isEqualTo: userId)
        .snapshots()
        .map((snapshot) {
          final threads = snapshot.docs
              .map((doc) => TherapistThread.fromMap(doc.id, doc.data()))
              .toList();
          threads.sort((a, b) {
            final left =
                a.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final right =
                b.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            return right.compareTo(left);
          });
          return threads;
        });
  }

  @override
  Stream<TherapistThread?> watchThread(String threadId) {
    return _firestore
        .collection(FirestoreCollections.therapistThreads)
        .doc(threadId)
        .snapshots()
        .map((doc) {
          if (!doc.exists || doc.data() == null) {
            return null;
          }
          return TherapistThread.fromMap(doc.id, doc.data()!);
        });
  }

  @override
  Future<TherapistThread> ensureThread({
    required String therapistId,
    required String childId,
    required String subscriptionId,
  }) async {
    final parentId = _auth.currentUser?.uid;
    if (parentId == null) {
      throw StateError('No logged in user');
    }

    final parentDoc = await _firestore
        .collection(FirestoreCollections.users)
        .doc(parentId)
        .get();
    final therapistDoc = await _firestore
        .collection(FirestoreCollections.therapistProfiles)
        .doc(therapistId)
        .get();
    final parentDisplayName = _resolveParentDisplayName(parentDoc.data());
    final therapistDisplayName = (therapistDoc.data()?['displayName'] ?? '')
        .toString();

    final existing = await _firestore
        .collection(FirestoreCollections.therapistThreads)
        .where('parentId', isEqualTo: parentId)
        .where('therapistId', isEqualTo: therapistId)
        .where('childId', isEqualTo: childId)
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) {
      final existingThread = TherapistThread.fromMap(
        existing.docs.first.id,
        existing.docs.first.data(),
      );
      final needsMetadataPatch =
          existingThread.parentDisplayName.isEmpty ||
          existingThread.therapistDisplayName.isEmpty;
      final normalizedSubscriptionId = subscriptionId.trim();
      final needsReadOnlyPatch =
          normalizedSubscriptionId.isEmpty && existingThread.status == 'active';
      if (needsMetadataPatch || needsReadOnlyPatch) {
        await existing.docs.first.reference.set({
          'parentDisplayName': parentDisplayName,
          'therapistDisplayName': therapistDisplayName,
          if (needsReadOnlyPatch) ...{
            'status': 'canceled',
            'postCancelVisible': true,
          },
        }, SetOptions(merge: true));
        return existingThread.copyWith(
          parentDisplayName: parentDisplayName,
          therapistDisplayName: therapistDisplayName,
          status: needsReadOnlyPatch ? 'canceled' : null,
          postCancelVisible: needsReadOnlyPatch ? true : null,
        );
      }
      return existingThread;
    }

    final normalizedSubscriptionId = subscriptionId.trim();
    final ref = _firestore
        .collection(FirestoreCollections.therapistThreads)
        .doc();
    final thread = TherapistThread(
      id: ref.id,
      parentId: parentId,
      therapistId: therapistId,
      childId: childId,
      subscriptionId: normalizedSubscriptionId,
      status: normalizedSubscriptionId.isNotEmpty ? 'active' : 'canceled',
      parentDisplayName: parentDisplayName,
      therapistDisplayName: therapistDisplayName,
      lastMessageAt: DateTime.now(),
      emergencyStatus: 'none',
      postCancelVisible: true,
    );
    await ref.set({
      ...thread.toMap(),
      'lastMessageAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return thread;
  }

  @override
  Stream<List<TherapistMessage>> watchMessages(String threadId) {
    return _firestore
        .collection(FirestoreCollections.therapistThreads)
        .doc(threadId)
        .collection('messages')
        .orderBy('sentAt')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => TherapistMessage.fromMap(doc.id, doc.data()))
              .toList(),
        );
  }

  @override
  Future<void> sendMessage({
    required String threadId,
    required String senderRole,
    required String body,
  }) async {
    final senderId = _auth.currentUser?.uid;
    if (senderId == null) {
      throw StateError('No logged in user');
    }
    if (senderRole == 'parent') {
      final threadSnapshot = await _firestore
          .collection(FirestoreCollections.therapistThreads)
          .doc(threadId)
          .get();
      final threadData = threadSnapshot.data() ?? const <String, dynamic>{};
      final status = (threadData['status'] ?? 'active').toString();
      final postCancelVisible = threadData['postCancelVisible'] != false;
      if (status != 'active' || !postCancelVisible) {
        throw StateError(
          'Messaging is disabled until an active subscription is restored.',
        );
      }
    }

    await _firestore
        .collection(FirestoreCollections.therapistThreads)
        .doc(threadId)
        .collection('messages')
        .add({
          'senderId': senderId,
          'senderRole': senderRole,
          'body': body,
          'attachments': const <String>[],
          'messageType': 'text',
          'deliveryStatus': 'sent',
          'sentAt': FieldValue.serverTimestamp(),
        });

    await _firestore
        .collection(FirestoreCollections.therapistThreads)
        .doc(threadId)
        .set({
          'lastMessageAt': FieldValue.serverTimestamp(),
          'lastMessagePreview': body.length <= 120
              ? body
              : '${body.substring(0, 117)}...',
        }, SetOptions(merge: true));
  }

  @override
  Future<void> requestEmergency({
    required String threadId,
    required String requestedByRole,
  }) async {
    final senderId = _auth.currentUser?.uid;
    if (senderId == null) {
      throw StateError('No logged in user');
    }
    final threadRef = _firestore
        .collection(FirestoreCollections.therapistThreads)
        .doc(threadId);

    await threadRef.collection('messages').add({
      'senderId': senderId,
      'senderRole': requestedByRole,
      'body': 'Emergency support requested.',
      'attachments': const <String>[],
      'messageType': 'system',
      'deliveryStatus': 'sent',
      'sentAt': FieldValue.serverTimestamp(),
    });

    await threadRef.set({
      'emergencyStatus': 'requested',
      'emergencyRequestedBy': requestedByRole,
      'emergencyRequestedAt': FieldValue.serverTimestamp(),
      'lastMessageAt': FieldValue.serverTimestamp(),
      'lastMessagePreview': 'Emergency support requested.',
    }, SetOptions(merge: true));
  }

  @override
  Future<void> resolveEmergency({
    required String threadId,
    required String resolvedByRole,
  }) async {
    final senderId = _auth.currentUser?.uid;
    if (senderId == null) {
      throw StateError('No logged in user');
    }
    final threadRef = _firestore
        .collection(FirestoreCollections.therapistThreads)
        .doc(threadId);

    await threadRef.collection('messages').add({
      'senderId': senderId,
      'senderRole': resolvedByRole,
      'body': 'Emergency support responded.',
      'attachments': const <String>[],
      'messageType': 'system',
      'deliveryStatus': 'sent',
      'sentAt': FieldValue.serverTimestamp(),
    });

    await threadRef.set({
      'emergencyStatus': 'responded',
      'emergencyRespondedAt': FieldValue.serverTimestamp(),
      'lastMessageAt': FieldValue.serverTimestamp(),
      'lastMessagePreview': 'Emergency support responded.',
    }, SetOptions(merge: true));
  }
}

class FirebaseBillingRepository implements BillingRepository {
  FirebaseBillingRepository(this._auth, this._firestore)
    : _paymentBackend = PaymentBackendClient(_auth) {
    unawaited(syncSubscriptions());
  }

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final PaymentBackendClient _paymentBackend;

  static String _subscriptionDocId(String userId, String therapistId) =>
      '${userId.trim()}_${therapistId.trim()}';

  static Future<void> _updateUserEntitlements(
    FirebaseFirestore firestore,
    String userId,
  ) async {
    final activeSnapshot = await firestore
        .collection(FirestoreCollections.subscriptions)
        .where('userId', isEqualTo: userId)
        .where('status', whereIn: const ['active', 'trialing'])
        .limit(1)
        .get();
    final hasActive = activeSnapshot.docs.isNotEmpty;
    await firestore.collection(FirestoreCollections.users).doc(userId).set({
      'subscriptionTier': hasActive ? 'professional-support' : 'free',
      'entitlements': {
        'professionalSupport': hasActive,
        'chatAccess': hasActive,
      },
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  UserSubscription _localBypassSubscription(String userId, String therapistId) {
    return UserSubscription(
      id: _subscriptionDocId(userId, therapistId),
      userId: userId,
      therapistId: therapistId,
      productId: 'bypass-plan',
      status: 'active',
      isActive: true,
      cancelAtPeriodEnd: false,
      currentPeriodEnd: DateTime.now().add(const Duration(days: 3650)),
    );
  }

  String _requireAuthenticatedUser({required String action}) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      throw StateError('You need to be logged in to $action.');
    }
    return userId;
  }

  Future<String> _resolveProductIdForTherapist(String therapistId) async {
    final therapistSnapshot = await _firestore
        .collection(FirestoreCollections.therapistProfiles)
        .doc(therapistId)
        .get();
    final therapistData =
        therapistSnapshot.data() ?? const <String, dynamic>{};
    final productId = (therapistData['subscriptionProductId'] ?? '')
        .toString()
        .trim();
    if (productId.isEmpty) {
      throw StateError(
        'This therapist is not linked to a subscription product. '
        'Set `subscriptionProductId` in therapist profile.',
      );
    }
    return productId;
  }

  Future<bool> _waitForSubscriptionActivation({
    required String userId,
    required String therapistId,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final docId = _subscriptionDocId(userId, therapistId);
    final startedAt = DateTime.now();
    while (DateTime.now().difference(startedAt) < timeout) {
      final snapshot = await _firestore
          .collection(FirestoreCollections.subscriptions)
          .doc(docId)
          .get();
      if (snapshot.exists && snapshot.data() != null) {
        final subscription = UserSubscription.fromMap(snapshot.id, snapshot.data()!);
        if (subscription.isActive) {
          return true;
        }
        final status = subscription.status.trim().toLowerCase();
        if (status == 'payment_failed' ||
            status == 'failed' ||
            status == 'canceled' ||
            status == 'expired') {
          return false;
        }
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    return false;
  }

  @override
  Future<UserSubscription?> getSubscriptionForTherapist(
    String therapistId,
  ) async {
    final normalizedTherapistId = therapistId.trim();
    if (normalizedTherapistId.isEmpty) {
      return null;
    }
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      return null;
    }
    if (AppRuntimeConfig.bypassProSupportPaywall) {
      return _localBypassSubscription(userId, normalizedTherapistId);
    }
    final docId = _subscriptionDocId(userId, normalizedTherapistId);
    final snapshot = await _firestore
        .collection(FirestoreCollections.subscriptions)
        .doc(docId)
        .get();
    if (!snapshot.exists || snapshot.data() == null) {
      return null;
    }
    return UserSubscription.fromMap(snapshot.id, snapshot.data()!);
  }

  @override
  Stream<UserSubscription?> watchSubscriptionForTherapist(String therapistId) {
    final normalizedTherapistId = therapistId.trim();
    final userId = _auth.currentUser?.uid;
    if (userId == null || normalizedTherapistId.isEmpty) {
      return const Stream<UserSubscription?>.empty();
    }
    if (AppRuntimeConfig.bypassProSupportPaywall) {
      return Stream<UserSubscription?>.value(
        _localBypassSubscription(userId, normalizedTherapistId),
      );
    }
    final docId = _subscriptionDocId(userId, normalizedTherapistId);
    return _firestore
        .collection(FirestoreCollections.subscriptions)
        .doc(docId)
        .snapshots()
        .map((snapshot) {
          final data = snapshot.data();
          if (!snapshot.exists || data == null) {
            return null;
          }
          return UserSubscription.fromMap(snapshot.id, data);
        });
  }

  @override
  Future<bool> purchaseTherapistSubscription(String therapistId) async {
    final normalizedTherapistId = therapistId.trim();
    if (normalizedTherapistId.isEmpty) {
      throw StateError('Missing therapist id.');
    }
    final userId = _requireAuthenticatedUser(action: 'purchase a subscription');
    if (AppRuntimeConfig.bypassProSupportPaywall) {
      return true;
    }
    if (!_paymentBackend.isConfigured) {
      throw StateError(
        'Payment backend is not configured. Start app with '
        '--dart-define=PAYMENT_BACKEND_BASE_URL=https://your-backend-url',
      );
    }
    final productId = await _resolveProductIdForTherapist(normalizedTherapistId);

    final checkoutUrl = await _paymentBackend.createCheckoutSession(
      therapistId: normalizedTherapistId,
      productId: productId,
      successUrl: AppRuntimeConfig.paymentSuccessUrl,
      cancelUrl: AppRuntimeConfig.paymentCancelUrl,
    );
    if (checkoutUrl == null || checkoutUrl.trim().isEmpty) {
      throw StateError('Payment backend did not return a checkout URL.');
    }

    final launched = await launchUrl(
      Uri.parse(checkoutUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      throw StateError('Unable to open payment checkout.');
    }

    final active = await _waitForSubscriptionActivation(
      userId: userId,
      therapistId: normalizedTherapistId,
    );
    await _updateUserEntitlements(_firestore, userId);
    if (active) {
      return true;
    }
    final latest = await getSubscriptionForTherapist(normalizedTherapistId);
    return latest?.isActive == true;
  }

  @override
  Future<void> restorePurchases() async {
    if (AppRuntimeConfig.bypassProSupportPaywall) {
      return;
    }
    final userId = _auth.currentUser?.uid;
    if (userId != null) {
      await _updateUserEntitlements(_firestore, userId);
    }
  }

  @override
  Future<void> syncSubscriptions() async {
    await restorePurchases();
  }

  @override
  Future<void> cancelSubscriptionInStore(String therapistId) async {
    final normalizedTherapistId = therapistId.trim();
    if (normalizedTherapistId.isEmpty) {
      throw StateError('Missing therapist id.');
    }
    final userId = _requireAuthenticatedUser(
      action: 'manage subscriptions',
    );
    if (AppRuntimeConfig.bypassProSupportPaywall) {
      return;
    }
    if (!_paymentBackend.isConfigured) {
      throw StateError(
        'Payment backend is not configured. Start app with '
        '--dart-define=PAYMENT_BACKEND_BASE_URL=https://your-backend-url',
      );
    }

    final docId = _subscriptionDocId(userId, normalizedTherapistId);
    await _paymentBackend.cancelSubscription(docId);
    final subscriptionRef = _firestore
        .collection(FirestoreCollections.subscriptions)
        .doc(docId);
    final snapshot = await subscriptionRef.get();
    if (snapshot.exists) {
      await subscriptionRef.set({
        'cancelAtPeriodEnd': true,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
    await _updateUserEntitlements(_firestore, userId);
  }
}
