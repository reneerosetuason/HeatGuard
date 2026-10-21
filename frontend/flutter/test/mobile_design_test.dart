import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:heatguard_mobile/models/heatguard_models.dart';
import 'package:heatguard_mobile/screens/dashboard_screen.dart';
import 'package:heatguard_mobile/services/heatguard_api.dart';
import 'package:heatguard_mobile/theme/heatguard_theme.dart';

class _TestApi extends HeatGuardApi {
  bool stale = false;
  bool unavailable = false;
  bool missing = false;
  int lastHours = 24;
  int lastLocation = 1;

  static const places = [
    HeatLocation(id: 1, name: 'Quezon City'),
    HeatLocation(id: 2, name: 'Cebu City'),
  ];

  @override
  Future<Map<String, dynamic>> fetchMobileConfig(String baseUrl) async => {
    'can_write': true,
    'admin_configured': true,
    'is_admin': false,
  };

  @override
  Future<List<HeatLocation>> fetchLocations(String baseUrl) async {
    if (unavailable) {
      throw const HeatGuardApiException('The server is unavailable.');
    }
    return places;
  }

  @override
  Future<HeatDashboard> fetchDashboard(
    String baseUrl, {
    required int locationId,
    int hours = 24,
  }) async {
    lastHours = hours;
    lastLocation = locationId;
    return HeatDashboard.fromJson({
      'location': {'id': locationId, 'name': places[locationId - 1].name},
      'locations': [
        for (final place in places) {'id': place.id, 'name': place.name},
      ],
      'data_status': missing
          ? 'no_data'
          : stale
          ? 'stale'
          : 'ok',
      'status_message': missing
          ? 'No validated reading is available.'
          : stale
          ? 'This reading is historical. Current conditions are unknown.'
          : 'Weather data is current.',
      if (!missing)
        'current': {
          'temperature_c': 30.2,
          'humidity_pct': 68,
          'heat_index_c': 36.4,
          'risk': {'key': 'extreme_caution', 'label': 'Extreme Caution'},
          'observed_at': '2026-10-21T07:00:00Z',
          'observed_at_display': 'Oct 21, 3:00 PM',
          'source': 'Open-Meteo',
          'is_stale': stale,
        },
      'recommendations': [
        'Drink water regularly and take breaks in a cool, shaded place.',
        'Limit strenuous activity during the hottest part of the day.',
        'Check on children, older adults, and people who need extra care.',
      ],
      'disclaimer': 'Follow official PAGASA and local advisories.',
      if (!stale && !missing)
        'active_alert': {
          'risk_key': 'extreme_caution',
          'risk_label': 'Extreme Caution',
          'heat_index_c': 36.4,
          'message': 'Take extra care during prolonged outdoor activity.',
          'recommendations': [
            'Drink water regularly.',
            'Take breaks in the shade.',
          ],
        },
      'alerts': [],
      'thresholds': [
        {'key': 'low_risk', 'label': 'Low Risk', 'level': 0, 'max_c': 27},
        {'key': 'caution', 'label': 'Caution', 'level': 1, 'min_c': 27},
        {
          'key': 'extreme_caution',
          'label': 'Extreme Caution',
          'level': 2,
          'min_c': 33,
        },
        {'key': 'danger', 'label': 'Danger', 'level': 3, 'min_c': 42},
        {
          'key': 'extreme_danger',
          'label': 'Extreme Danger',
          'level': 4,
          'min_c': 52,
        },
      ],
      'history': {
        'hours': hours,
        'points': [
          for (var i = 0; i < 12; i++)
            {
              'label': '${i + 1}:00 PM',
              'temperature_c': 28.0 + i * 0.2,
              'humidity_pct': 57.0 + i,
              'heat_index_c': 30.9 + i * 0.5,
              'risk_key': i < 5 ? 'caution' : 'extreme_caution',
              'risk_label': i < 5 ? 'Caution' : 'Extreme Caution',
              'risk_level': i < 5 ? 1 : 2,
            },
        ],
      },
    });
  }

  @override
  Future<List<AddressOption>> fetchAddressOptions(
    String baseUrl, {
    required String path,
    required String key,
    Map<String, String>? queryParameters,
  }) async => const [];
}

void main() {
  setUpAll(() async {
    // Exercise real text layout, including styles without an explicit font.
    final config =
        jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
            as Map<String, dynamic>;
    final flutter = (config['packages'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((package) => package['name'] == 'flutter');
    final fonts = Uri.parse(
      '${flutter['rootUri']}/',
    ).resolve('../../bin/cache/artifacts/material_fonts/');
    for (final family in ['Roboto', 'Ahem']) {
      final loader = FontLoader(family);
      for (final weight in ['regular', 'medium', 'bold']) {
        loader.addFont(
          Future.value(
            ByteData.sublistView(
              File.fromUri(
                fonts.resolve('roboto-$weight.ttf'),
              ).readAsBytesSync(),
            ),
          ),
        );
      }
      await loader.load();
    }
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(
            ByteData.sublistView(
              File.fromUri(
                fonts.resolve('materialicons-regular.otf'),
              ).readAsBytesSync(),
            ),
          ),
        ))
        .load();
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

  Future<void> mount(
    WidgetTester tester,
    _TestApi api, {
    double width = 390,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
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
          key: const ValueKey('preview'),
          child: DashboardScreen(api: api),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CAPTURE_MOBILE_PREVIEWS')) return;
    // Asset decoding can outlive pumpAndSettle; wait before exporting a frame.
    await tester.runAsync(() async {
      final context = tester.element(find.byKey(const ValueKey('preview')));
      await precacheImage(
        const AssetImage('assets/branding/heatguard_logo.png'),
        context,
      );
      if (!context.mounted) return;
      await precacheImage(
        const AssetImage('assets/branding/heatguard_mark.png'),
        context,
      );
    });
    await tester.pump();
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('preview')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/design-previews')
        ..createSync(recursive: true);
      File(
        '${directory.path}/$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'navigation, time ranges, chart scrubbing, and metric selection work',
    (tester) async {
      final api = _TestApi();
      await mount(tester, api);
      expect(find.text('Feels like outside'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'today');

      await tab(tester, 'Trends');
      expect(find.text('Conditions over time'), findsOneWidget);
      await capture(tester, 'trends');
      await tester.tap(find.text('7 days'));
      await tester.pumpAndSettle();
      expect(api.lastHours, 168);
      final plot = find.byKey(const ValueKey('history-plot'));
      await tester.ensureVisible(plot);
      await tester.tapAt(tester.getTopLeft(plot) + const Offset(43, 70));
      await tester.pumpAndSettle();
      expect(find.text('30.9\u00b0C'), findsOneWidget);
      await tester.dragFrom(
        tester.getTopLeft(plot) + const Offset(44, 70),
        const Offset(230, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('30.9\u00b0C'), findsNothing);
      expect(find.text('Trends'), findsOneWidget);
      await tester.ensureVisible(find.text('Humidity'));
      await tester.tap(find.text('Humidity'));
      await tester.pumpAndSettle();
      expect(find.text('68.0%'), findsOneWidget);
      await tab(tester, 'Safety');
      expect(find.text('Active heat alert'), findsOneWidget);
      await capture(tester, 'safety');
      await tab(tester, 'Settings');
      expect(find.text('Daily device reminder'), findsOneWidget);
      await capture(tester, 'settings');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('switching monitored location loads its own dashboard', (
    tester,
  ) async {
    final api = _TestApi();
    await mount(tester, api);
    await tester.tap(find.byType(DropdownButtonFormField<int>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cebu City').last);
    await tester.pumpAndSettle();
    expect(api.lastLocation, 2);
    expect(find.text('Cebu City'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final missing in [false, true]) {
    testWidgets(
      '${missing ? 'missing' : 'stale'} readings show current risk as unknown',
      (tester) async {
        await mount(
          tester,
          _TestApi()
            ..stale = !missing
            ..missing = missing,
        );
        expect(find.text('Current risk unknown'), findsOneWidget);
        expect(find.text('Feels like outside'), findsNothing);
        await tab(tester, 'Safety');
        expect(
          find.textContaining('Current heat risk is unknown.'),
          findsOneWidget,
        );
        expect(find.textContaining('No active heat alert.'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'connection settings stay accessible when the server is unavailable',
    (tester) async {
      await mount(tester, _TestApi()..unavailable = true);
      expect(find.text('The server is unavailable.'), findsOneWidget);
      await tab(tester, 'Settings');
      await tester.tap(find.text('HeatGuard server'));
      await tester.pumpAndSettle();
      expect(find.text('API base address'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'connection error opens server settings and recovers when the API returns',
    (tester) async {
      final api = _TestApi()..unavailable = true;
      await mount(tester, api);
      expect(find.textContaining('Server: http://'), findsOneWidget);
      await tester.tap(find.text('Server settings'));
      await tester.pumpAndSettle();
      expect(find.text('API base address'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      api.unavailable = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Feels like outside'), findsOneWidget);
      expect(find.text('The server is unavailable.'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'small phone with large text lays out all four tabs and the location sheet',
    (tester) async {
      await mount(tester, _TestApi(), width: 320, scale: 1.6);
      for (final label in ['Today', 'Trends', 'Safety', 'Settings']) {
        await tab(tester, label);
        expect(
          tester.takeException(),
          isNull,
          reason: '$label at large text size',
        );
        final list = find.byKey(
          PageStorageKey(
            'dashboard-tab-${['Today', 'Trends', 'Safety', 'Settings'].indexOf(label)}',
          ),
        );
        await tester.drag(list, const Offset(0, -1000));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'Scrolled $label at large text size',
        );
      }
      await tester.ensureVisible(find.text('Add location'));
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      expect(find.text('Search places'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
