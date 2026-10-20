import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/heatguard_models.dart';
import 'client_factory.dart';

class HeatGuardApi {
  HeatGuardApi({http.Client? client}) : _client = client ?? createHeatGuardClient();

  final http.Client _client;
  final Map<String, String> _cookies = {};
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

  Future<List<HeatLocation>> fetchLocations(String baseUrl) async {
    final data = await _request(baseUrl, 'GET', '/api/locations');
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
      '/api/dashboard',
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

  Future<Map<String, dynamic>> searchLocations(
    String baseUrl,
    String query,
  ) => _request(
    baseUrl,
    'GET',
    '/api/geocode',
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
      path,
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
    '/api/locations',
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
    '/api/locations/address',
    form: {
      'region_code': regionCode,
      'province_code': provinceCode,
      'city_code': cityCode,
      'barangay_code': barangayCode,
      'csrf_token': _csrfToken,
    },
  );

  Future<Map<String, dynamic>> deleteLocation(
    String baseUrl,
    int locationId,
  ) => _request(
    baseUrl,
    'DELETE',
    '/api/locations/$locationId',
    headers: {'X-CSRF-Token': _csrfToken},
  );

  Future<Map<String, dynamic>> refreshNow(
    String baseUrl, {
    required int locationId,
    required int hours,
  }) => _request(
    baseUrl,
    'POST',
    '/api/refresh',
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
  }) async {
    final normalizedBase = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.parse('$normalizedBase$path').replace(
      queryParameters: queryParameters,
    );
    final requestHeaders = <String, String>{
      'Accept': 'application/json',
      ...?headers,
    };
    if (!kIsWeb && _cookies.isNotEmpty) {
      requestHeaders['Cookie'] = _cookies.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
    }

    try {
      late http.Response response;
      switch (method) {
        case 'GET':
          response = await _client.get(uri, headers: requestHeaders);
          break;
        case 'POST':
          response = await _client.post(
            uri,
            headers: requestHeaders,
            body: form ?? const <String, String>{},
          );
          break;
        case 'DELETE':
          response = await _client.delete(uri, headers: requestHeaders);
          break;
        default:
          throw ArgumentError.value(method, 'method', 'Unsupported HTTP method');
      }
      _captureCookies(response);

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw HeatGuardApiException(
          'The server response was invalid.',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          decoded['ok'] != true) {
        throw HeatGuardApiException(
          (decoded['error'] ?? decoded['message'] ??
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

  void _captureCookies(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null) return;
    final pair = setCookie.split(';').first.trim();
    final separator = pair.indexOf('=');
    if (separator <= 0) return;
    _cookies[pair.substring(0, separator)] = pair.substring(separator + 1);
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
