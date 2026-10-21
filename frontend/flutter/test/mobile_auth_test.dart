import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:heatguard_mobile/models/heatguard_models.dart';
import 'package:heatguard_mobile/screens/auth_gate.dart';
import 'package:heatguard_mobile/services/heatguard_api.dart';
import 'package:heatguard_mobile/services/mobile_auth_controller.dart';
import 'package:heatguard_mobile/theme/heatguard_theme.dart';

class _MemoryTokens implements SessionTokenStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String server) async => values[server];
  @override
  Future<void> write(String server, String token) async {
    values[server] = token;
  }

  @override
  Future<void> delete(String server) async {
    values.remove(server);
  }
}

class _AuthApi extends HeatGuardApi {
  Map<String, dynamic>? user;
  bool verified = false;
  bool registrationRequested = false;
  int weatherReads = 0;
  bool emptyPlaces = false;
  static const account = {
    'id': 1,
    'name': 'Alex',
    'email': 'alex@example.com',
    'email_verified': true,
  };
  static const challenge = {
    'challenge_id': 'test-registration-challenge',
    'email': 'alex@example.com',
    'resend_after': 60,
  };

  @override
  Future<Map<String, dynamic>> accountSession(String baseUrl) async => {
    'ok': true,
    'user': user,
  };
  @override
  Future<Map<String, dynamic>> registerAccount(
    String baseUrl, {
    required String name,
    required String email,
    required String password,
  }) async {
    registrationRequested = true;
    return {'ok': true, 'challenge': challenge};
  }

  @override
  Future<Map<String, dynamic>> verifyRegistration(
    String baseUrl, {
    required String challengeId,
    required String code,
  }) async {
    if (code != '123456') {
      throw const HeatGuardApiException(
        'That code is incorrect.',
        statusCode: 400,
      );
    }
    verified = true;
    user = account;
    return {'ok': true, 'user': account, 'token': 'opaque-test-session-token'};
  }

  @override
  Future<Map<String, dynamic>> loginAccount(
    String baseUrl, {
    required String email,
    required String password,
  }) async {
    if (!verified || password != 'a good long password') {
      throw const HeatGuardApiException(
        'Email or password is incorrect.',
        statusCode: 401,
      );
    }
    user = account;
    return {'ok': true, 'user': account, 'token': 'opaque-test-session-token'};
  }

  @override
  Future<Map<String, dynamic>> logoutAccount(String baseUrl) async {
    user = null;
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> resendVerification(
    String baseUrl,
    String challengeId,
  ) async => {'ok': true, 'challenge': challenge};
  @override
  Future<Map<String, dynamic>> fetchMobileConfig(String baseUrl) async => {
    'can_write': false,
    'can_manage_personal_locations': true,
    'admin_configured': false,
    'is_admin': false,
  };
  @override
  Future<List<HeatLocation>> fetchLocations(String baseUrl) async {
    weatherReads++;
    return emptyPlaces ? [] : const [HeatLocation(id: 1, name: 'Quezon City')];
  }

  @override
  Future<List<AddressOption>> fetchAddressOptions(
    String baseUrl, {
    required String path,
    required String key,
    Map<String, String>? queryParameters,
  }) async => [];

  @override
  Future<Map<String, dynamic>> fetchRoutines(String baseUrl) async => {
    'routines': [],
    'push_available': false,
    'reminders_enabled': true,
  };
  @override
  Future<Map<String, dynamic>> fetchNotifications(String baseUrl) async => {
    'notifications': [],
    'unread_count': 0,
  };

  @override
  Future<HeatDashboard> fetchDashboard(
    String baseUrl, {
    required int locationId,
    int hours = 24,
  }) async => HeatDashboard.fromJson({
    'location': {'id': 1, 'name': 'Quezon City'},
    'data_status': 'ok',
    'status_message': 'Weather data is current.',
    'current': {
      'temperature_c': 30,
      'humidity_pct': 60,
      'heat_index_c': 33,
      'risk': {'key': 'extreme_caution', 'label': 'Extreme Caution'},
    },
    'recommendations': ['Drink water regularly.'],
  });
}

void main() {
  setUpAll(() async {
    final config =
        jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
            as Map<String, dynamic>;
    final package = (config['packages'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['name'] == 'flutter');
    final fonts = Uri.parse(
      '${package['rootUri']}/',
    ).resolve('../../bin/cache/artifacts/material_fonts/');
    for (final family in ['Roboto', 'Ahem', 'MaterialIcons']) {
      final loader = FontLoader(family);
      for (final filename
          in family == 'MaterialIcons'
              ? ['materialicons-regular.otf']
              : [
                  'roboto-regular.ttf',
                  'roboto-medium.ttf',
                  'roboto-bold.ttf',
                ]) {
        loader.addFont(
          Future.value(
            ByteData.sublistView(
              File.fromUri(fonts.resolve(filename)).readAsBytesSync(),
            ),
          ),
        );
      }
      await loader.load();
    }
  });

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({'daily_reminder': false});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_timezone'),
      (_) async => 'UTC',
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (_) async => true,
    );
  });

  Future<MobileAuthController> mount(
    WidgetTester tester,
    _AuthApi api,
    _MemoryTokens tokens, {
    double width = 390,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = MobileAuthController(api: api, tokenStore: tokens);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHeatGuardTheme().copyWith(
          textTheme: buildHeatGuardTheme().textTheme.apply(
            fontFamily: 'Roboto',
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: const ValueKey('auth-preview'),
          child: AuthGate(controller: auth),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return auth;
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> credentials(
    WidgetTester tester, {
    bool registration = false,
  }) async {
    if (registration) {
      await tester.enterText(find.byKey(const ValueKey('auth-name')), 'Alex');
    }
    await tester.enterText(
      find.byKey(const ValueKey('auth-email')),
      'alex@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-password')),
      'a good long password',
    );
    if (registration) {
      await tester.enterText(
        find.byKey(const ValueKey('auth-confirmation')),
        'a good long password',
      );
    }
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CAPTURE_MOBILE_PREVIEWS')) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('auth-preview')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/design-previews').createSync(recursive: true);
      File(
        'build/design-previews/auth-$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'registration stays locked until OTP verification and logout returns to login',
    (tester) async {
      final api = _AuthApi();
      final tokens = _MemoryTokens();
      final auth = await mount(tester, api, tokens);
      expect(find.text('Welcome back.'), findsOneWidget);
      expect(api.weatherReads, 0);
      await capture(tester, 'login');
      await tap(tester, 'Create account');
      await capture(tester, 'register');
      await credentials(tester, registration: true);
      await tap(tester, 'Send verification code');
      expect(find.text('Check your inbox.'), findsOneWidget);
      expect(auth.account, isNull);
      expect(tokens.values, isEmpty);
      expect(api.weatherReads, 0);
      await tester.enterText(find.byKey(const ValueKey('auth-code')), '000000');
      await tap(tester, 'Verify & continue');
      expect(find.text('That code is incorrect.'), findsOneWidget);
      expect(auth.account, isNull);
      expect(api.weatherReads, 0);
      await tester.enterText(find.byKey(const ValueKey('auth-code')), '123456');
      await tap(tester, 'Verify & continue');
      expect(find.text('Feels like outside'), findsOneWidget);
      expect(tokens.values.values, contains('opaque-test-session-token'));
      expect(api.weatherReads, greaterThan(0));
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Settings'),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'Sign out of HeatGuard');
      expect(find.text('Welcome back.'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tokens.values, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('password confirmation prevents sending a registration request', (
    tester,
  ) async {
    final api = _AuthApi();
    await mount(tester, api, _MemoryTokens());
    await tap(tester, 'Create account');
    await credentials(tester, registration: true);
    await tester.enterText(
      find.byKey(const ValueKey('auth-confirmation')),
      'a different password',
    );
    await tap(tester, 'Send verification code');
    expect(find.text('Your passwords do not match.'), findsOneWidget);
    expect(api.registrationRequested, isFalse);
    expect(api.weatherReads, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'incorrect login stays gated and verified login opens the dashboard',
    (tester) async {
      final api = _AuthApi()..verified = true;
      await mount(tester, api, _MemoryTokens());
      await credentials(tester);
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'incorrect password',
      );
      await tap(tester, 'Sign in');
      expect(find.text('Email or password is incorrect.'), findsOneWidget);
      expect(api.weatherReads, 0);
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'a good long password',
      );
      await tap(tester, 'Sign in');
      expect(find.text('Feels like outside'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'expired sessions immediately remove dashboard access and stored credentials',
    (tester) async {
      final api = _AuthApi()..user = _AuthApi.account;
      final tokens = _MemoryTokens()
        ..values[HeatGuardApi.defaultBaseUrl] = 'restored-session';
      final auth = await mount(tester, api, tokens);
      expect(find.text('Feels like outside'), findsOneWidget);
      await tester.tap(find.byTooltip('My routines'));
      await tester.pumpAndSettle();
      await tap(tester, 'Add routine');
      expect(find.byKey(const ValueKey('routine-title')), findsOneWidget);
      await auth.api.onAuthenticationRequired!();
      await tester.pumpAndSettle();
      expect(find.text('Welcome back.'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byKey(const ValueKey('routine-title')), findsNothing);
      expect(tokens.values, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('invalid stored session cannot open the dashboard', (
    tester,
  ) async {
    final api = _AuthApi();
    final tokens = _MemoryTokens()
      ..values[HeatGuardApi.defaultBaseUrl] = 'expired-session';
    await mount(tester, api, tokens);
    expect(find.text('Welcome back.'), findsOneWidget);
    expect(api.weatherReads, 0);
    expect(tokens.values, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'members with no saved addresses can open the address picker without admin access',
    (tester) async {
      final api = _AuthApi()
        ..user = _AuthApi.account
        ..emptyPlaces = true;
      await mount(tester, api, _MemoryTokens());
      expect(find.text('Your places. Your weather.'), findsOneWidget);
      await tap(tester, 'Add your first address');
      expect(find.text('Browse address'), findsOneWidget);
      expect(find.textContaining('Changes are restricted'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('small screens and large text support all authentication steps', (
    tester,
  ) async {
    final api = _AuthApi();
    await mount(tester, api, _MemoryTokens(), width: 320, scale: 1.6);
    expect(tester.takeException(), isNull);
    await tap(tester, 'Create account');
    await credentials(tester, registration: true);
    await tap(tester, 'Send verification code');
    expect(find.text('Check your inbox.'), findsOneWidget);
    await tester.ensureVisible(find.text('Check your inbox.'));
    await tester.pumpAndSettle();
    await capture(tester, 'verification');
    expect(tester.takeException(), isNull);
    expect(api.weatherReads, 0);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'mobile requests use protected routes and never send credentials to a different server',
    () async {
      final requests = <http.Request>[];
      final api = HeatGuardApi(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode({'ok': true, 'locations': []}), 200);
        }),
      );
      api.setMemberToken('http://localhost:5000', 'private-token');
      await api.fetchLocations('http://localhost:5000');
      await api.fetchLocations('https://another.example');
      expect(requests[0].url.path, '/api/mobile/data/locations');
      expect(requests[0].headers['Authorization'], 'Bearer private-token');
      expect(requests[1].headers.containsKey('Authorization'), isFalse);
      api.close();
    },
  );
}
