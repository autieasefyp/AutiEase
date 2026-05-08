class AppRuntimeConfig {
  AppRuntimeConfig._();

  static const paymentBackendBaseUrl = String.fromEnvironment(
    'PAYMENT_BACKEND_BASE_URL',
    defaultValue: '',
  );

  static const paymentSuccessUrl = String.fromEnvironment(
    'PAYMENT_SUCCESS_URL',
    defaultValue: 'https://autiease.app/success',
  );

  static const paymentCancelUrl = String.fromEnvironment(
    'PAYMENT_CANCEL_URL',
    defaultValue: 'https://autiease.app/cancel',
  );

  static const _allowBypassForLocal = bool.fromEnvironment(
    'ALLOW_PRO_SUPPORT_PAYWALL_BYPASS',
    defaultValue: false,
  );
  static const _isProduct = bool.fromEnvironment('dart.vm.product');
  static bool get bypassProSupportPaywall =>
      !_isProduct && _allowBypassForLocal;
}
