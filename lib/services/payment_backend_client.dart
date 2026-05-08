import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config/app_runtime_config.dart';
import '../models/app_models.dart';

class PaymentBackendClient {
  PaymentBackendClient(this._auth, {http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final FirebaseAuth _auth;
  final http.Client _httpClient;

  bool get isConfigured =>
      AppRuntimeConfig.paymentBackendBaseUrl.trim().isNotEmpty;

  Uri _buildUri(String path) {
    final base = AppRuntimeConfig.paymentBackendBaseUrl.trim();
    if (base.isEmpty) {
      throw StateError(
        'Payment backend is not configured. Launch the app with '
        '--dart-define=PAYMENT_BACKEND_BASE_URL=https://your-backend-url',
      );
    }
    final normalizedBase = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$normalizedBase$normalizedPath');
  }

  Future<String> _getIdToken() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('You need to be logged in before starting checkout.');
    }
    final token = await user.getIdToken(true);
    if (token == null || token.isEmpty) {
      throw StateError('Unable to obtain auth token. Please login again.');
    }
    return token;
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final token = await _getIdToken();
    final response = await _httpClient.post(
      _buildUri(path),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );

    Map<String, dynamic> payload = const <String, dynamic>{};
    if (response.body.isNotEmpty) {
      try {
        payload = mapFrom(jsonDecode(response.body));
      } catch (_) {
        payload = const <String, dynamic>{};
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message =
          payload['error']?.toString() ??
          payload['message']?.toString() ??
          'Payment backend request failed (${response.statusCode}).';
      throw StateError(message);
    }

    return payload;
  }

  Future<String?> createCheckoutSession({
    required String therapistId,
    required String productId,
    required String successUrl,
    required String cancelUrl,
  }) async {
    final payload = await _postJson(
      '/api/v1/checkout/session',
      body: {
        'therapistId': therapistId,
        'productId': productId,
        'successUrl': successUrl,
        'cancelUrl': cancelUrl,
      },
    );
    return payload['url']?.toString();
  }

  Future<void> cancelSubscription(String subscriptionId) async {
    await _postJson(
      '/api/v1/subscription/cancel',
      body: {'subscriptionId': subscriptionId},
    );
  }

  Future<void> reactivateSubscription(String subscriptionId) async {
    await _postJson(
      '/api/v1/subscription/reactivate',
      body: {'subscriptionId': subscriptionId},
    );
  }
}
