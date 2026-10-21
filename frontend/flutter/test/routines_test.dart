import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:heatguard_mobile/models/heatguard_models.dart';
import 'package:heatguard_mobile/screens/routines_screen.dart';
import 'package:heatguard_mobile/services/heatguard_api.dart';
import 'package:heatguard_mobile/services/routines_controller.dart';
import 'package:heatguard_mobile/theme/heatguard_theme.dart';

class TestApi extends HeatGuardApi {
  final routines = <Map<String, dynamic>>[];
  bool read = false;
  Map<String, String>? saved;
  @override
  Future<Map<String, dynamic>> accountSession(String baseUrl) async => {
    'ok': true,
  };
  @override
  Future<Map<String, dynamic>> fetchRoutines(String baseUrl) async => {
    'routines': routines,
    'push_available': true,
    'reminders_enabled': true,
  };
  @override
  Future<Map<String, dynamic>> fetchNotifications(String baseUrl) async => {
    'notifications': [
      {
        'id': 7,
        'routine_id': 1,
        'title': 'School soon',
        'body': 'Bring water and an umbrella before school.',
        'event_at': '2026-10-22T00:00:00Z',
        'created_at': '2026-10-21T23:45:00Z',
        'read': read,
        'ai_generated': true,
      },
    ],
    'unread_count': read ? 0 : 1,
  };
  @override
  Future<Map<String, dynamic>> saveRoutine(
    String baseUrl,
    Map<String, String> values, {
    int? id,
  }) async {
    saved = values;
    routines.removeWhere((row) => row['id'] == id);
    routines.add({
      'id': id ?? 1,
      'title': values['title'],
      'time': values['time'],
      'weekdays': values['weekdays']!.split(',').map(int.parse).toList(),
      'timezone': values['timezone'],
      'location_id': 1,
      'location_name': 'Quezon City',
      'enabled': values['enabled'] == 'true',
      'remind_before_minutes': int.parse(values['remind_before_minutes']!),
    });
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> previewRoutine(String baseUrl, int id) async => {
    'preview': {
      'title': 'Go to school at 08:00',
      'body': 'Bring water and use shade.',
      'ai_generated': true,
    },
  };
  @override
  Future<Map<String, dynamic>> readNotification(
    String baseUrl, {
    int? id,
  }) async {
    read = true;
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> deleteRoutine(String baseUrl, int id) async {
    routines.removeWhere((row) => row['id'] == id);
    return {'ok': true};
  }
}

void main() {
  setUpAll(() async {
    final config =
        jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
            as Map<String, dynamic>;
    final package = (config['packages'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((row) => row['name'] == 'flutter');
    final fonts = Uri.parse(
      '${package['rootUri']}/',
    ).resolve('../../bin/cache/artifacts/material_fonts/');
    for (final family in ['Roboto', 'Ahem', 'MaterialIcons']) {
      final loader = FontLoader(family);
      for (final file
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
              File.fromUri(fonts.resolve(file)).readAsBytesSync(),
            ),
          ),
        );
      }
      await loader.load();
    }
  });
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({});
  });
  Future<RoutinesController> mount(
    WidgetTester tester,
    TestApi api, {
    double width = 390,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = RoutinesController(
      api: api,
      baseUrl: 'http://example.test',
      accountId: 1,
    );
    await controller.reload();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHeatGuardTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RoutinesScreen(
          controller: controller,
          locations: const [
            HeatLocation(id: 1, name: 'Quezon City', timezone: 'Asia/Manila'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(controller.dispose);
    return controller;
  }

  testWidgets('create, preview, pause and delete a routine', (tester) async {
    final api = TestApi();
    await mount(tester, api);
    await tester.tap(find.text('Add routine'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('routine-title')),
      'Go to school',
    );
    await tester.ensureVisible(find.text('Save routine'));
    await tester.tap(find.text('Save routine'));
    await tester.pumpAndSettle();
    expect(api.saved?['timezone'], 'Asia/Manila');
    expect(api.saved?['weekdays'], '0,1,2,3,4');
    expect(find.text('Go to school'), findsOneWidget);
    await tester.ensureVisible(find.text('Preview reminder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview reminder'));
    await tester.pumpAndSettle();
    expect(find.text('Bring water and use shade.'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(api.saved?['enabled'], 'false');
    await tester.tap(find.byTooltip('Routine options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(api.routines, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'notification bell opens sidebar and read-all clears unread badge',
    (tester) async {
      final controller = await mount(tester, TestApi());
      await tester.tap(find.byTooltip('Notifications, 1 unread'));
      await tester.pumpAndSettle();
      expect(find.text('School soon'), findsOneWidget);
      expect(
        find.text('Bring water and an umbrella before school.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Mark all read'));
      await tester.pumpAndSettle();
      expect(controller.unread, 0);
      expect(find.text('0 unread'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('routine editor supports small screens and larger text', (
    tester,
  ) async {
    await mount(tester, TestApi(), width: 320, scale: 1.6);
    await tester.ensureVisible(find.text('Add routine'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add routine'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save routine'));
    expect(tester.takeException(), isNull);
  });
}
