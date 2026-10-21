import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/mobile_account.dart';
import 'heatguard_api.dart';
import 'routine_push_service.dart';

abstract class SessionTokenStore {
  Future<String?> read(String server);
  Future<void> write(String server, String token);
  Future<void> delete(String server);
}

class SecureSessionTokenStore implements SessionTokenStore {
  const SecureSessionTokenStore();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );
  String _key(String server) =>
      'heatguard.member.${Uri.encodeComponent(server)}';
  @override
  Future<String?> read(String server) => _storage.read(key: _key(server));
  @override
  Future<void> write(String server, String token) =>
      _storage.write(key: _key(server), value: token);
  @override
  Future<void> delete(String server) => _storage.delete(key: _key(server));
}

class MobileAuthController extends ChangeNotifier {
  MobileAuthController({HeatGuardApi? api, SessionTokenStore? tokenStore})
    : api = api ?? HeatGuardApi(),
      _tokens = tokenStore ?? const SecureSessionTokenStore() {
    this.api.onAuthenticationRequired = _expireSession;
  }

  final HeatGuardApi api;
  final SessionTokenStore _tokens;
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  String baseUrl = HeatGuardApi.defaultBaseUrl;
  MobileAccount? account;
  bool initializing = true;
  String? connectionError;
  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      baseUrl =
          await _preferences.getString('api_base_url') ??
          HeatGuardApi.defaultBaseUrl;
      if (kIsWeb && baseUrl == 'http://127.0.0.1:5000') {
        baseUrl = HeatGuardApi.defaultBaseUrl;
      }
      if (!kIsWeb) api.setMemberToken(baseUrl, await _tokens.read(baseUrl));
      final result = await api.accountSession(baseUrl);
      final user = result['user'];
      account = user is Map<String, dynamic>
          ? MobileAccount.fromJson(user)
          : null;
      if (account == null && !kIsWeb) {
        api.setMemberToken(baseUrl, null);
        await _tokens.delete(baseUrl);
      }
      connectionError = null;
    } catch (error) {
      account = null;
      connectionError = error is HeatGuardApiException
          ? error.message
          : 'We could not restore your session. Please sign in.';
    } finally {
      initializing = false;
      _changed();
    }
  }

  Future<void> _refreshForm() async {
    await api.accountSession(baseUrl);
    connectionError = null;
  }

  Future<RegistrationChallenge> register({
    required String name,
    required String email,
    required String password,
  }) async {
    await _refreshForm();
    final result = await api.registerAccount(
      baseUrl,
      name: name,
      email: email,
      password: password,
    );
    return RegistrationChallenge.fromJson(
      result['challenge'] as Map<String, dynamic>,
    );
  }

  Future<RegistrationChallenge> resend(RegistrationChallenge challenge) async {
    await _refreshForm();
    final result = await api.resendVerification(baseUrl, challenge.id);
    return RegistrationChallenge.fromJson(
      result['challenge'] as Map<String, dynamic>,
    );
  }

  Future<void> verify(RegistrationChallenge challenge, String code) async {
    await _refreshForm();
    await _accept(
      await api.verifyRegistration(
        baseUrl,
        challengeId: challenge.id,
        code: code,
      ),
    );
  }

  Future<void> signIn(String email, String password) async {
    await _refreshForm();
    await _accept(
      await api.loginAccount(baseUrl, email: email, password: password),
    );
  }

  Future<void> _accept(Map<String, dynamic> result) async {
    final verified = MobileAccount.fromJson(
      result['user'] as Map<String, dynamic>,
    );
    if (!kIsWeb) {
      final token = result['token'];
      if (token is! String || token.isEmpty) {
        throw const FormatException(
          'The server did not return a secure session.',
        );
      }
      await _tokens.write(baseUrl, token);
      api.setMemberToken(baseUrl, token);
    }
    account = verified;
    connectionError = null;
    _changed();
  }

  Future<void> signOut() async {
    await _refreshForm();
    await api.logoutAccount(baseUrl);
    await _expireSession();
  }

  Future<void> _expireSession() async {
    account = null;
    initializing = true;
    api.setMemberToken(baseUrl, null);
    _changed();
    try {
      if (!kIsWeb) await _tokens.delete(baseUrl);
      await RoutinePushService.clearAccount();
    } finally {
      initializing = false;
      _changed();
    }
  }

  Future<void> changeServer(String value) async {
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null ||
        !parsed.hasAuthority ||
        !['http', 'https'].contains(parsed.scheme) ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      throw const HeatGuardApiException(
        'Enter a complete http:// or https:// server address.',
      );
    }
    if (account != null) {
      try {
        await api.logoutAccount(baseUrl);
      } catch (_) {
        /* The old server may be offline. */
      }
    }
    await _expireSession();
    baseUrl = value.trim().replaceFirst(RegExp(r'/+$'), '');
    await _preferences.setString('api_base_url', baseUrl);
    initializing = true;
    _changed();
    await initialize();
  }

  @override
  void dispose() {
    _disposed = true;
    api.onAuthenticationRequired = null;
    api.close();
    super.dispose();
  }
}
