import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/heatguard_models.dart';
import 'client_factory.dart';

class HeatGuardApi {
  HeatGuardApi({http.Client? client})
    : _client = client ?? createHeatGuardClient();

  final http.Client _client;
  final Map<String, Map<String, String>> _cookieJars = {};
  String? _memberToken;
  String? _memberTokenBase;
  Future<void> Function()? onAuthenticationRequired;

  void setMemberToken(String baseUrl, String? token) {
    _memberTokenBase = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    _memberToken = token;
  }

  static String _dataPath(String path) =>
      path.replaceFirst('/api/', '/api/mobile/data/');
  String _csrfToken = '';

  static String get defaultBaseUrl {
    const configured = String.fromEnvironment('HEATGUARD_API_BASE_URL');
    if (configured.trim().isNotEmpty) return configured.trim();
    if (kIsWeb) return 'http://localhost:5000';
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return 'http://127.0.0.1:5000';
    }
    return 'http://10.0.2.2:5000';
  }

  Future<Map<String, dynamic>> accountSession(String baseUrl) =>
      _request(baseUrl, 'GET', '/api/mobile/auth/session');

  Future<Map<String, dynamic>> fetchRoutines(String baseUrl) =>
      _request(baseUrl, 'GET', '/api/mobile/routines');
  Future<Map<String, dynamic>> saveRoutine(
    String baseUrl,
    Map<String, String> values, {
    int? id,
  }) => _request(
    baseUrl,
    'POST',
    '/api/mobile/routines${id == null ? '' : '/$id'}',
    form: values,
  );
  Future<Map<String, dynamic>> deleteRoutine(String baseUrl, int id) =>
      _request(baseUrl, 'DELETE', '/api/mobile/routines/$id');
  Future<Map<String, dynamic>> previewRoutine(String baseUrl, int id) =>
      _request(baseUrl, 'POST', '/api/mobile/routines/$id/preview');
  Future<Map<String, dynamic>> fetchNotifications(String baseUrl) =>
      _request(baseUrl, 'GET', '/api/mobile/notifications');
  Future<Map<String, dynamic>> readNotification(String baseUrl, {int? id}) =>
      _request(
        baseUrl,
        'POST',
        '/api/mobile/notifications/${id == null ? 'read-all' : '$id/read'}',
      );
  Future<Map<String, dynamic>> registerPushDevice(
    String baseUrl,
    String token,
  ) => _request(
    baseUrl,
    'POST',
    '/api/mobile/devices/register',
    form: {'token': token, 'platform': 'android'},
    timeout: const Duration(seconds: 12),
  );
  Future<Map<String, dynamic>> removePushDevice(String baseUrl, String token) =>
      _request(
        baseUrl,
        'POST',
        '/api/mobile/devices/remove',
        form: {'token': token},
        timeout: const Duration(seconds: 12),
      );

  Future<Map<String, dynamic>> registerAccount(
    String baseUrl, {
    required String name,
    required String email,
    required String password,
  }) => _request(
    baseUrl,
    'POST',
    '/api/mobile/auth/register',
    form: {
      'name': name,
      'email': email,
      'password': password,
      'csrf_token': _csrfToken,
    },
  );

  Future<Map<String, dynamic>> verifyRegistration(
    String baseUrl, {
    required String challengeId,
    required String code,
  }) => _request(
    baseUrl,
    'POST',
    '/api/mobile/auth/verify',
    form: {
      'challenge_id': challengeId,
      'code': code,
      'device': kIsWeb ? 'web' : 'native',
      'csrf_token': _csrfToken,
    },
  );

  Future<Map<String, dynamic>> resendVerification(
    String baseUrl,
    String challengeId,
  ) => _request(
    baseUrl,
    'POST',
    '/api/mobile/auth/resend',
    form: {'challenge_id': challengeId, 'csrf_token': _csrfToken},
  );

  Future<Map<String, dynamic>> loginAccount(
    String baseUrl, {
    required String email,
    required String password,
  }) => _request(
    baseUrl,
    'POST',
    '/api/mobile/auth/login',
    form: {
      'email': email,
      'password': password,
      'device': kIsWeb ? 'web' : 'native',
      'csrf_token': _csrfToken,
    },
  );

  Future<Map<String, dynamic>> logoutAccount(String baseUrl) => _request(
    baseUrl,
    'POST',
    '/api/mobile/auth/logout',
    form: {'csrf_token': _csrfToken},
  );

  Future<List<HeatLocation>> fetchLocations(String baseUrl) async {
    final data = await _request(baseUrl, 'GET', _dataPath('/api/locations'));
    final rawLocations = data['locations'];
    if (rawLocations is! List) {
      throw const HeatGuardApiException('The server returned no locations.');
    }
    return rawLocations
        .whereType<Map<String, dynamic>>()
        .map(HeatLocation.fromJson)
        .toList();
  }

  Future<HeatDashboard> fetchDashboard(
    String baseUrl, {
    required int locationId,
    int hours = 24,
  }) async {
    final data = await _request(
      baseUrl,
      'GET',
      _dataPath('/api/dashboard'),
      queryParameters: {'location': '$locationId', 'hours': '$hours'},
    );
    final dashboard = data['dashboard'];
    if (dashboard is! Map<String, dynamic>) {
      throw const HeatGuardApiException('The server returned no dashboard.');
    }
    return HeatDashboard.fromJson(dashboard);
  }

  Future<Map<String, dynamic>> fetchMobileConfig(String baseUrl) async {
    final data = await _request(baseUrl, 'GET', '/api/mobile/config');
    _csrfToken = (data['csrf_token'] ?? '').toString();
    return data;
  }

  Future<Map<String, dynamic>> login(
    String baseUrl, {
    required String username,
    required String password,
  }) async {
    final data = await _request(
      baseUrl,
      'POST',
      '/api/mobile/login',
      form: {
        'username': username,
        'password': password,
        'csrf_token': _csrfToken,
      },
    );
    _csrfToken = (data['csrf_token'] ?? '').toString();
    return data;
  }

  Future<Map<String, dynamic>> logout(String baseUrl) async {
    final data = await _request(
      baseUrl,
      'POST',
      '/api/mobile/logout',
      form: {'csrf_token': _csrfToken},
    );
    _csrfToken = (data['csrf_token'] ?? '').toString();
    return data;
  }

  Future<Map<String, dynamic>> searchLocations(String baseUrl, String query) =>
      _request(
        baseUrl,
        'GET',
        _dataPath('/api/geocode'),
        queryParameters: {'q': query},
      );

  Future<List<AddressOption>> fetchAddressOptions(
    String baseUrl, {
    required String path,
    required String key,
    Map<String, String>? queryParameters,
  }) async {
    final data = await _request(
      baseUrl,
      'GET',
      _dataPath(path),
      queryParameters: queryParameters,
    );
    final values = data[key];
    if (values is! List) return const [];
    return values
        .whereType<Map<String, dynamic>>()
        .map(AddressOption.fromJson)
        .toList();
  }

  Future<Map<String, dynamic>> createLocation(
    String baseUrl,
    GeocodeResult location,
  ) => _request(
    baseUrl,
    'POST',
    _dataPath('/api/locations'),
    form: {
      'name': location.displayName,
      'latitude': '${location.latitude}',
      'longitude': '${location.longitude}',
      'timezone': location.timezone,
      'csrf_token': _csrfToken,
    },
  );

  Future<Map<String, dynamic>> createAddressLocation(
    String baseUrl, {
    required String regionCode,
    required String provinceCode,
    required String cityCode,
    required String barangayCode,
  }) => _request(
    baseUrl,
    'POST',
    _dataPath('/api/locations/address'),
    form: {
      'region_code': regionCode,
      'province_code': provinceCode,
      'city_code': cityCode,
      'barangay_code': barangayCode,
      'csrf_token': _csrfToken,
    },
  );

  Future<Map<String, dynamic>> deleteLocation(String baseUrl, int locationId) =>
      _request(
        baseUrl,
        'DELETE',
        _dataPath('/api/locations/$locationId'),
        headers: {'X-CSRF-Token': _csrfToken},
      );

  Future<Map<String, dynamic>> refreshNow(
    String baseUrl, {
    required int locationId,
    required int hours,
  }) => _request(
    baseUrl,
    'POST',
    _dataPath('/api/refresh'),
    form: {
      'location_id': '$locationId',
      'hours': '$hours',
      'csrf_token': _csrfToken,
    },
  );

  Future<Map<String, dynamic>> _request(
    String baseUrl,
    String method,
    String path, {
    Map<String, String>? queryParameters,
    Map<String, String>? form,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final normalizedBase = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.parse(
      '$normalizedBase$path',
    ).replace(queryParameters: queryParameters);
    final requestHeaders = <String, String>{
      'Accept': 'application/json',
      ...?headers,
    };
    final cookies = _cookieJars[uri.origin] ?? {};
    if (_memberToken != null && _memberTokenBase == normalizedBase) {
      requestHeaders['Authorization'] = 'Bearer $_memberToken';
    }
    if (method != 'GET' && _csrfToken.isNotEmpty) {
      requestHeaders['X-CSRF-Token'] = _csrfToken;
    }
    if (!kIsWeb && cookies.isNotEmpty) {
      requestHeaders['Cookie'] = cookies.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
    }

    try {
      late http.Response response;
      switch (method) {
        case 'GET':
          response = await _client
              .get(uri, headers: requestHeaders)
              .timeout(const Duration(seconds: 15));
          break;
        case 'POST':
          response = await _client
              .post(
                uri,
                headers: requestHeaders,
                body: form ?? const <String, String>{},
              )
              .timeout(timeout ?? const Duration(seconds: 45));
          break;
        case 'DELETE':
          response = await _client
              .delete(uri, headers: requestHeaders)
              .timeout(const Duration(seconds: 15));
          break;
        default:
          throw ArgumentError.value(
            method,
            'method',
            'Unsupported HTTP method',
          );
      }
      _captureCookies(response, uri.origin);

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw HeatGuardApiException(
          'The server response was invalid.',
          statusCode: response.statusCode,
        );
      }
      if (decoded['csrf_token'] is String) {
        _csrfToken = decoded['csrf_token'] as String;
      }
      if (decoded['error_code'] == 'authentication_required') {
        await onAuthenticationRequired?.call();
      }
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          decoded['ok'] != true) {
        throw HeatGuardApiException(
          (decoded['error'] ??
                  decoded['message'] ??
                  'HeatGuard could not complete this request.')
              .toString(),
          statusCode: response.statusCode,
        );
      }
      return decoded;
    } on HeatGuardApiException {
      rethrow;
    } on FormatException {
      throw const HeatGuardApiException(
        'The server returned unreadable data. Check the API address.',
      );
    } on http.ClientException {
      throw const HeatGuardApiException(
        'HeatGuard could not reach the server. Check the API address and network.',
      );
    } on Exception {
      throw const HeatGuardApiException(
        'The request timed out. Check the API address and try again.',
      );
    }
  }

  void _captureCookies(http.Response response, String origin) {
    if (kIsWeb) return;
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null) return;
    final jar = _cookieJars.putIfAbsent(origin, () => {});
    for (final cookie in setCookie.split(RegExp(r',(?=\s*[^;,=\s]+=)'))) {
      final pair = cookie.split(';').first.trim();
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;
      final name = pair.substring(0, separator);
      final value = pair.substring(separator + 1);
      if (value.isEmpty) {
        jar.remove(name);
      } else {
        jar[name] = value;
      }
    }
  }

  void close() => _client.close();
}

class HeatGuardApiException implements Exception {
  const HeatGuardApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
