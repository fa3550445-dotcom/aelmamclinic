import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/services/db_service.dart';

void main() {
  late Directory tempDir;
  late String testDbPath;

  setUpAll(() {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('db_service_test_');
    databaseFactoryFfi.setDatabasesPath(tempDir.path);
    testDbPath = p.join(tempDir.path, 'clinic.db');
    await DBService.instance.resetForTesting(databasePath: testDbPath);
  });

  tearDown(() async {
    DBService.instance.onLocalChange = null;
    await DBService.instance.flushAndClose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    DBService.setTestDatabasePath(null);
  });

  test('insertPatient persists and emits change notification', () async {
    final events = <String>[];
    DBService.instance.onLocalChange = (table) async {
      events.add(table);
    };

    final resolvedPath = await DBService.instance.getDatabasePath();
    expect(resolvedPath, equals(testDbPath));

    final patient = Patient(
      name: 'Test Patient',
      age: 30,
      diagnosis: 'Initial',
      paidAmount: 100,
      remaining: 50,
      registerDate: DateTime.utc(2024, 1, 1),
      phoneNumber: '123456789',
    );

    final id = await DBService.instance.insertPatient(patient);
    final db = await DBService.instance.database;
    final rows =
        await db.query(Patient.table, where: 'id = ?', whereArgs: [id]);

    expect(rows, isNotEmpty);
    expect(rows.first['name'], equals('Test Patient'));

    // allow debounce (220ms) inside DBService to trigger.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(events.contains(Patient.table), isTrue);
  });
}
