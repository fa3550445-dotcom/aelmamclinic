// lib/services/sync_service.dart
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:postgrest/postgrest.dart' show PostgrestException;

/// كلاس مساعد اختياري لتحويل الحقول عند الدفع/السحب.
/// ضع أي من الدالتين إن كنت تحتاج مسار تحويل مخصص لهذا الجدول.
class EntityMapper {
  final Map<String, dynamic> Function(Map<String, dynamic> localRow)? toCloudMap;
  final Map<String, dynamic> Function(
      Map<String, dynamic> remoteRow,
      Set<String> allowedLocalColumns,
      )? fromCloudMap;

  const EntityMapper({this.toCloudMap, this.fromCloudMap});
}

class RemoteIdMapping {
  final String accountId;
  final String deviceId;
  final int localId;

  const RemoteIdMapping({
    required this.accountId,
    required this.deviceId,
    required this.localId,
  });
}

class RemoteIdMapper {
  RemoteIdMapper(this._db);

  final Database _db;

  Future<void> saveMapping({
    required String tableName,
    required String accountId,
    required String deviceId,
    required int localId,
    required String remoteUuid,
  }) async {
    if (remoteUuid.isEmpty || localId <= 0) return;
    await _db.insert(
      'remote_id_map',
      {
        'table_name': tableName,
        'account_id': accountId,
        'device_id': deviceId,
        'local_id': localId,
        'remote_uuid': remoteUuid,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> remoteUuidForLocal({
    required String tableName,
    required String accountId,
    required String deviceId,
    required int localId,
  }) async {
    if (localId <= 0) return null;
    final rows = await _db.query(
      'remote_id_map',
      columns: const ['remote_uuid'],
      where: 'table_name = ? AND account_id = ? AND device_id = ? AND local_id = ?',
      whereArgs: [tableName, accountId, deviceId, localId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['remote_uuid'];
    return raw == null ? null : '$raw';
  }

  Future<RemoteIdMapping?> tripleForRemoteUuid({
    required String tableName,
    required String remoteUuid,
  }) async {
    if (remoteUuid.isEmpty) return null;
    final rows = await _db.query(
      'remote_id_map',
      columns: const ['account_id', 'device_id', 'local_id'],
      where: 'table_name = ? AND remote_uuid = ?',
      whereArgs: [tableName, remoteUuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final acc = '${row['account_id'] ?? ''}'.trim();
    final dev = '${row['device_id'] ?? ''}'.trim();
    final loc = row['local_id'];
    final localId = loc is num ? loc.toInt() : int.tryParse('${loc ?? ''}') ?? 0;
    if (localId <= 0) return null;
    return RemoteIdMapping(
      accountId: acc,
      deviceId: dev,
      localId: localId,
    );
  }
}

class MissingRemoteMappingException implements Exception {
  final String remoteTable;
  final String parentTable;
  final String childColumn;
  final int parentLocalId;
  final String reason;

  const MissingRemoteMappingException({
    required this.remoteTable,
    required this.parentTable,
    required this.childColumn,
    required this.parentLocalId,
    required this.reason,
  });

  @override
  String toString() =>
      'MissingRemoteMappingException($remoteTable.$childColumn -> $parentTable#$parentLocalId): $reason';
}

class _LocalSyncTriple {
  final String accountId;
  final String deviceId;
  final int localId;

  const _LocalSyncTriple({
    required this.accountId,
    required this.deviceId,
    required this.localId,
  });
}

/// خدمة للمزامنة بين SQLite المحلي و Supabase.
///
/// المتطلبات السحابية:
/// - أعمدة التزامن: account_id, device_id, local_id, updated_at
/// - فهرس فريد مركّب: unique(account_id,device_id,local_id)
/// - RLS على account_id.
///
/// ملاحظات:
/// - لا نفلتر device_id عند السحب: المالك يرى كل أجهزة حسابه.
/// - لمنع تصادم id محليًا: نركّب id = hash(device_id)*1e9 + local_id.
/// - attachments محلية فقط.
/// - حذف منطقي محلي، مع حذف سحابي فعلي لسجلات هذا الجهاز (id < 1e9).
class SyncService {
  final SupabaseClient _client = Supabase.instance.client;
  final Database _db;
  final RemoteIdMapper _remoteIds;

  /// ⚠️ قابلة لإعادة الربط (rebind) بعد معرفة الحساب/الجهاز.
  String accountId;
  String? deviceId;
  final bool enableLogs;

  /// تأخير دفع التغييرات المتتالية لنفس الجدول (دمجها بعد 1 ثانية).
  final Duration pushDebounce;

  static const String _conflictKey = 'account_id,device_id,local_id';
  static const int _pushChunkSize = 500;
  static const int _pullPageSize = 1000;

  /// نفس الثابت المستخدم في تركيب المعرف محليًا
  static const int _composeBlock = 1000000000; // 1e9

  static const Set<String> _reservedCols = {
    'account_id',
    'local_id',
    'device_id',
    'updated_at',
  };

  final Map<String, Set<String>> _localColsCache = {};
  final Map<String, Map<String, String>> _localColTypeCache = {};

  /// قفل دفع مخصص لكل جدول لمنع تكرار الدفع بالتوازي
  final Map<String, bool> _pushBusy = {};

  /// مؤقّتات دفع مجمّعة لكل جدول (debounce)
  final Map<String, Timer> _pushTimers = {};

  /// allow-list للحقلـات المسموح إرسالها لكل جدول (snake_case على السحابة).
  /// تُستخدم كمسار احتياطي حتى ننتقل كليًا إلى mappers (toCloudMap/fromMap).
  static final Map<String, Set<String>> _remoteAllow = {
    'patients': {
      'name',
      'age',
      'diagnosis',
      'paid_amount',
      'remaining',
      'register_date',
      'phone_number',
      'health_status',
      'preferences',
      'doctor_id',
      'doctor_name',
      'doctor_specialization',
      'notes',
      'service_type',
      'service_id',
      'service_name',
      'service_cost',
      'doctor_share',
      'doctor_input',
      'tower_share',
      'department_share',
    },
    'returns': {
      'date',
      'patient_name',
      'phone_number',
      'diagnosis',
      'remaining',
      'age',
      'doctor',
      'notes',
    },
    'consumptions': {'patient_id', 'item_id', 'quantity', 'date', 'amount', 'note'},
    'drugs': {'name', 'notes', 'created_at'},
    'prescriptions': {'patient_id', 'doctor_id', 'record_date', 'created_at'},
    'prescription_items': {'prescription_id', 'drug_id', 'days', 'times_per_day'},
    'complaints': {'title', 'description', 'status', 'created_at'},
    'appointments': {'patient_id', 'appointment_time', 'status', 'notes'},
    'doctors': {'employee_id', 'name', 'specialization', 'phone_number', 'start_time', 'end_time', 'print_counter'},
    'consumption_types': {'type'},
    'medical_services': {'name', 'cost', 'service_type'},
    'service_doctor_share': {'service_id', 'doctor_id', 'share_percentage', 'tower_share_percentage', 'is_hidden'},
    'employees': {'name', 'identity_number', 'phone_number', 'job_title', 'address', 'marital_status', 'basic_salary', 'final_salary', 'is_doctor'},
    'employees_loans': {'employee_id', 'loan_date_time', 'final_salary', 'ratio_sum', 'loan_amount', 'leftover'},
    'employees_salaries': {'employee_id', 'year', 'month', 'final_salary', 'ratio_sum', 'total_loans', 'net_pay', 'is_paid', 'payment_date'},
    'employees_discounts': {'employee_id', 'discount_date_time', 'amount', 'notes'},
    'items': {'type_id', 'name', 'price', 'stock', 'created_at'},
    'item_types': {'name'},
    // نرسل total بدل unit_price + نضيف date
    'purchases': {'item_id', 'quantity', 'total', 'created_at', 'date'},
    // نضيف notify_time
    'alert_settings': {'item_id', 'threshold', 'is_enabled', 'last_triggered', 'created_at', 'notify_time'},
    'financial_logs': {'transaction_type', 'operation', 'amount', 'employee_id', 'description', 'modification_details', 'timestamp'},
    'patient_services': {'patient_id', 'service_id', 'service_name', 'service_cost'},
  };

  /// أعمدة Boolean على السحابة (نحوّل 0/1 المحلي إلى true/false عند الدفع).
  static final Map<String, Set<String>> _remoteBooleanCols = {
    'service_doctor_share': {'is_hidden'},
    'alert_settings': {'is_enabled'},
    'employees_salaries': {'is_paid'},
    'employees': {'is_doctor'},
  };

  /// خريطة مفاتيح FK لكل جدول (snake_case → parentLocalTable).
  static const Map<String, Map<String, String>> _fkMap = {
    'patients': {
      'doctor_id': 'doctors',
      'service_id': 'medical_services',
    },
    'consumptions': {
      'patient_id': 'patients',
      'item_id': 'items',
    },
    'prescriptions': {
      'patient_id': 'patients',
      'doctor_id': 'doctors',
    },
    'prescription_items': {
      'prescription_id': 'prescriptions',
      'drug_id': 'drugs',
    },
    'appointments': {
      'patient_id': 'patients',
    },
    'doctors': {
      'employee_id': 'employees',
    },
    'service_doctor_share': {
      'service_id': 'medical_services',
      'doctor_id': 'doctors',
    },
    'employees_loans': {
      'employee_id': 'employees',
    },
    'employees_salaries': {
      'employee_id': 'employees',
    },
    'employees_discounts': {
      'employee_id': 'employees',
    },
    'items': {
      'type_id': 'item_types',
    },
    'purchases': {
      'item_id': 'items',
    },
    'alert_settings': {
      'item_id': 'items',
    },
    'patient_services': {
      'patient_id': 'patients',
      'service_id': 'medical_services',
    },
  };

  /// Mapperات اختيارية لكل جدول — إن لم تُضبط، يُستخدم المسار الاحتياطي.
  final Map<String, EntityMapper> _mappers = {
    // purchases: حساب total ...
    'purchases': EntityMapper(
      toCloudMap: (local) {
        final out = <String, dynamic>{}..addAll(local);
        final q = out['quantity'];
        final up = out.containsKey('unitPrice') ? out['unitPrice'] : out['unit_price'];
        double? qty = (q is num) ? q.toDouble() : double.tryParse('${q ?? ''}');
        double? unit = (up is num) ? up.toDouble() : double.tryParse('${up ?? ''}');
        if (qty != null && unit != null) {
          out['total'] = qty * unit;
        }
        out.remove('unitPrice');
        out.remove('unit_price');

        DateTime? parseDate(dynamic v) {
          if (v == null) return null;
          if (v is DateTime) return v.toUtc();
          final s = v.toString().trim();
          if (s.isEmpty) return null;
          return DateTime.tryParse(s)?.toUtc();
        }

        final createdAt = parseDate(out['created_at']);
        if (createdAt != null) {
          out['created_at'] = createdAt.toIso8601String();
        }

        final existingDate = parseDate(out['date']);
        final DateTime effectiveDate = existingDate ?? createdAt ?? DateTime.now().toUtc();
        out['date'] = effectiveDate.toIso8601String();

        return out;
      },
      fromCloudMap: (remote, allowed) {
        final map = <String, dynamic>{}..addAll(remote);
        final hasTotalLocally = allowed.contains('total');
        if (!hasTotalLocally) {
          final rq = remote['quantity'];
          final rt = remote['total'];
          final double? qty = (rq is num) ? rq.toDouble() : double.tryParse('${rq ?? ''}');
          final double? tot = (rt is num) ? rt.toDouble() : double.tryParse('${rt ?? ''}');
          if (tot != null && qty != null && qty > 0) {
            if (allowed.contains('unitPrice')) {
              map['unitPrice'] = tot / qty;
            } else if (allowed.contains('unit_price')) {
              map['unit_price'] = tot / qty;
            }
          }
        }
        return map;
      },
    ),

    // doctors: تحويل HH:mm إلى timestamptz متوافق عند الدفع، والعكس عند السحب.
    'doctors': EntityMapper(
      toCloudMap: (local) {
        final out = <String, dynamic>{}..addAll(local);

        String? timeToTz(dynamic v) {
          final s = v?.toString().trim();
          if (s == null || s.isEmpty) return s;
          final re = RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$'); // HH:mm أو HH:mm:ss
          if (re.hasMatch(s)) {
            final parts = s.split(':');
            final hh = parts[0].padLeft(2, '0');
            final mm = (parts.length > 1 ? parts[1] : '00').padLeft(2, '0');
            final ss = (parts.length > 2 ? parts[2] : '00').padLeft(2, '0');
            // ✅ إصلاح: يجب استخدام ${ss}Z
            return '1970-01-01T$hh:$mm:${ss}Z';
          }
          return s;
        }

        // احترم camel/snake وأعد كتابة snake النهائي
        final st = out.remove('startTime') ?? out['start_time'];
        final et = out.remove('endTime') ?? out['end_time'];
        if (st != null) out['start_time'] = timeToTz(st);
        if (et != null) out['end_time'] = timeToTz(et);
        return out;
      },
      fromCloudMap: (remote, allowed) {
        final map = <String, dynamic>{}..addAll(remote);

        String tzToHHmm(dynamic v) {
          final s = v?.toString() ?? '';
          final dt = DateTime.tryParse(s);
          if (dt != null) {
            final hh = dt.hour.toString().padLeft(2, '0');
            final mm = dt.minute.toString().padLeft(2, '0');
            return '$hh:$mm';
          }
          return s; // إذا كان نص جاهز "14:00" أو لم يُحلّل
        }

        if (allowed.contains('startTime') && map.containsKey('start_time')) {
          map['startTime'] = tzToHHmm(map['start_time']);
        }
        if (allowed.contains('endTime') && map.containsKey('end_time')) {
          map['endTime'] = tzToHHmm(map['end_time']);
        }
        return map;
      },
    ),
  };

  void setMapper(String remoteTable, EntityMapper mapper) {
    _mappers[remoteTable] = mapper;
  }

  SyncService(
      Database database,
      this.accountId, {
        this.deviceId,
        this.enableLogs = false,
        this.pushDebounce = const Duration(seconds: 1),
      })  : _db = database,
            _remoteIds = RemoteIdMapper(database);

  void _log(String msg) {
    if (enableLogs) {
      // ignore: avoid_print
      print('[SYNC] $msg');
    }
  }

  bool get _hasAccount => accountId.trim().isNotEmpty;
  bool get _hasDevice =>
      deviceId != null &&
          deviceId!.trim().isNotEmpty &&
          deviceId!.trim().toLowerCase() != 'app-unknown';

  String get _safeDeviceId =>
      (deviceId != null && deviceId!.trim().isNotEmpty) ? deviceId!.trim() : 'app-unknown';

  /*──────────────────── أدوات مساعدة ────────────────────*/

  // يختار اسم العمود المتاح محليًا (camel أو snake)
  String? _col(Set<String> cols, String camel, String snake) =>
      cols.contains(camel) ? camel : (cols.contains(snake) ? snake : null);

  List<List<T>> _chunkify<T>(List<T> list, int chunkSize) {
    if (list.isEmpty) return const [];
    final chunks = <List<T>>[];
    for (var i = 0; i < list.length; i += chunkSize) {
      final end = (i + chunkSize < list.length) ? i + chunkSize : list.length;
      chunks.add(list.sublist(i, end));
    }
    return chunks;
  }

  Future<Set<String>> _getLocalColumns(String table) async {
    if (_localColsCache.containsKey(table)) return _localColsCache[table]!;
    final rows = await _db.rawQuery("PRAGMA table_info($table)");
    final cols = rows.map((r) => (r['name'] as String)).toSet();
    _localColsCache[table] = cols;
    final types = <String, String>{};
    for (final r in rows) {
      final name = (r['name'] as String);
      final type = (r['type'] ?? '').toString().toUpperCase();
      types[name] = type;
    }
    _localColTypeCache[table] = types;
    return cols;
  }

  Future<String?> _getLocalColumnType(String table, String column) async {
    if (!_localColTypeCache.containsKey(table)) {
      await _getLocalColumns(table);
    }
    return _localColTypeCache[table]?[column];
  }

  Future<_LocalSyncTriple?> _readLocalSyncTriple({
    required String table,
    required int localPrimaryId,
  }) async {
    if (localPrimaryId <= 0) return null;
    final cols = await _getLocalColumns(table);
    final accCol = _col(cols, 'accountId', 'account_id');
    final devCol = _col(cols, 'deviceId', 'device_id');
    final locCol = _col(cols, 'localId', 'local_id');
    final wanted = <String>{};
    if (accCol != null) wanted.add(accCol);
    if (devCol != null) wanted.add(devCol);
    if (locCol != null) wanted.add(locCol);
    final rows = await _db.query(
      table,
      columns: wanted.isEmpty ? null : wanted.toList(),
      where: 'id = ?',
      whereArgs: [localPrimaryId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final accVal = accCol != null ? '${row[accCol] ?? ''}'.trim() : accountId;
    final devVal = devCol != null ? '${row[devCol] ?? ''}'.trim() : _safeDeviceId;
    final locVal = locCol != null ? row[locCol] : null;
    final resolvedLocalId = locVal is num
        ? locVal.toInt()
        : int.tryParse('${locVal ?? ''}') ?? localPrimaryId;
    final acc = accVal.isEmpty ? accountId : accVal;
    final dev = devVal.isEmpty ? _safeDeviceId : devVal;
    return _LocalSyncTriple(accountId: acc, deviceId: dev, localId: resolvedLocalId);
  }

  Future<int?> _findLocalRowIdByTriple({
    required String table,
    required String accountIdForRow,
    required String deviceIdForRow,
    required int remoteLocalId,
  }) async {
    if (remoteLocalId <= 0) return null;
    final cols = await _getLocalColumns(table);
    final accCol = _col(cols, 'accountId', 'account_id');
    final devCol = _col(cols, 'deviceId', 'device_id');
    final locCol = _col(cols, 'localId', 'local_id');
    if (accCol == null || devCol == null || locCol == null) return null;
    final rows = await _db.query(
      table,
      columns: const ['id'],
      where: '$accCol = ? AND $devCol = ? AND $locCol = ?',
      whereArgs: [accountIdForRow, deviceIdForRow, remoteLocalId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['id'];
    if (raw is num) return raw.toInt();
    return int.tryParse('${raw ?? ''}');
  }

  String _toSnake(String key) {
    if (key.contains('_')) return key;
    final sb = StringBuffer();
    for (int i = 0; i < key.length; i++) {
      final c = key[i];
      final isLetter = c.toLowerCase() != c.toUpperCase();
      if (i > 0 && isLetter && c.toUpperCase() == c) sb.write('_');
      sb.write(c.toLowerCase());
    }
    return sb.toString();
  }

  String _toCamel(String key) {
    if (!key.contains('_')) return key;
    final parts = key.split('_');
    if (parts.isEmpty) return key;
    final head = parts.first;
    final tail = parts
        .skip(1)
        .map((p) => p.isEmpty ? '' : (p[0].toUpperCase() + p.substring(1)))
        .join();
    return head + tail;
  }

  Map<String, dynamic> _mapKeysToSnake(Map<String, dynamic> data) {
    final out = <String, dynamic>{};
    data.forEach((k, v) {
      if (_reservedCols.contains(k)) {
        out[k] = v;
      } else {
        out[_toSnake(k)] = v;
      }
    });
    return out;
  }

  String _buildSelectClause(
    Set<String> allowedCols, {
    Iterable<String> extraCols = const [],
    Set<String>? remoteAllowed,
  }) {
    final allowSnake = <String>{};
    for (final col in allowedCols) {
      final snake = _toSnake(col).trim();
      if (snake.isNotEmpty) allowSnake.add(snake);
    }
    for (final col in extraCols) {
      final snake = _toSnake(col).trim();
      if (snake.isNotEmpty) allowSnake.add(snake);
    }

    final cols = <String>{};
    for (final col in allowSnake) {
      if (col.isEmpty) continue;
      if (_reservedCols.contains(col)) continue; // ستُضاف لاحقًا
      if (remoteAllowed != null && !remoteAllowed.contains(col)) continue;
      cols.add(col);
    }

    cols.addAll(_reservedCols);
    cols.add('id');

    if (remoteAllowed != null) {
      cols.retainWhere((c) => _reservedCols.contains(c) || remoteAllowed.contains(c) || c == 'id');
    }

    cols.removeWhere((element) => element.trim().isEmpty);
    if (cols.isEmpty) return '*';
    return cols.join(',');
  }

  dynamic _toRemoteValue(String table, String snakeKey, dynamic value) {
    final boolCols = _remoteBooleanCols[table];
    if (boolCols != null && boolCols.contains(snakeKey)) {
      if (value == null) return null;
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final s = value.trim().toLowerCase();
        return (s == '1' || s == 'true' || s == 't' || s == 'yes');
      }
    }
    return value;
  }

  dynamic _toLocalValue(String table, String key, dynamic value) {
    if (value is bool) return value ? 1 : 0; // sqflite بلا bool
    return value;
  }

  int _hash32(String s) {
    int hash = 0x811c9dc5;
    for (int i = 0; i < s.length; i++) {
      hash ^= s.codeUnitAt(i);
      hash = (hash * 16777619) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  int _composeCrossDeviceId(String remoteDeviceId, int remoteLocalId) {
    final h = _hash32(remoteDeviceId); // 31-bit
    return h * _composeBlock + remoteLocalId;
  }

  /// توليد localId عشوائي (1..1e9-1) مع تحقّق تصادُم بسيط داخل الجدول/الجهاز الحالي.
  /// ✅ يدعم camelCase و snake_case تلقائيًا ولا يحتاج لمعرفة مسبقة بأسماء الأعمدة.
  Future<int> _newLocalId31(
      String table, {
        required String myDeviceId,
      }) async {
    final cols = await _getLocalColumns(table);
    final locCol = cols.contains('local_id')
        ? 'local_id'
        : (cols.contains('localId') ? 'localId' : null);
    final devCol = cols.contains('device_id')
        ? 'device_id'
        : (cols.contains('deviceId') ? 'deviceId' : null);

    final rng = Random.secure();
    for (int i = 0; i < 20; i++) {
      final candidate = 1 + rng.nextInt(_composeBlock - 2); // 1.._composeBlock-1

      if (locCol == null) {
        // لو ما في عمود local_id محليًا، ارجع المرشح مباشرة (لن نكتبه أصلاً لاحقًا).
        return candidate;
      }

      List<Map<String, Object?>> rows;
      if (devCol != null) {
        rows = await _db.query(
          table,
          columns: const ['id'],
          where: 'IFNULL($locCol,0)=? AND IFNULL($devCol,"")=?',
          whereArgs: [candidate, myDeviceId],
          limit: 1,
        );
      } else {
        rows = await _db.query(
          table,
          columns: const ['id'],
          where: 'IFNULL($locCol,0)=?',
          whereArgs: [candidate],
          limit: 1,
        );
      }
      if (rows.isEmpty) return candidate;
    }
    // في أسوأ الأحوال: استخدم جزءًا من الـ timestamp
    final ts = DateTime.now().millisecondsSinceEpoch % (_composeBlock - 1);
    return ts == 0 ? 1 : ts.toInt();
  }

  /// يضمن أن الـ AUTOINCREMENT سيُنتج دائمًا id < 1e9 للصفوف المحلية الجديدة
  Future<void> _clampAutoincrement(String table) async {
    try {
      final r = await _db.rawQuery(
        'SELECT COALESCE(MAX(id),0) AS m FROM $table WHERE id < ?',
        [_composeBlock],
      );
      final maxOwn =
      (r.isNotEmpty && r.first['m'] != null) ? (r.first['m'] as num).toInt() : 0;

      // اضبط عدّاد AUTOINCREMENT ليقف عند آخر id محلي (التالي سيكون maxOwn+1)
      await _db.rawQuery(
        'UPDATE sqlite_sequence SET seq = ? WHERE name = ?',
        [maxOwn, table],
      );

      _log('clamp autoinc [$table] -> $maxOwn');
    } catch (e) {
      // الجدول قد لا يكون AUTOINCREMENT أو sqlite_sequence غير موجودة بعد — نتجاهل
      _log('clamp autoinc [$table] skipped: $e');
    }
  }

  /// ⚠️ Upsert محلي غير مُدمِّر:
  /// - يُحدّث الأعمدة الموجودة فقط (لا يلمس الأعمدة غير الممرَّرة).
  /// - إن لم يوجد الصف، يُدرج (IGNORE لتفادي السباقات) ثم يُحدّث.
  Future<void> _upsertLocalNonDestructive(
      String table,
      Map<String, dynamic> row, {
        required int id,
      }) async {
    final updateMap = Map<String, dynamic>.from(row)..remove('id');

    final updated = await _db.update(
      table,
      updateMap,
      where: 'id = ?',
      whereArgs: [id],
    );

    if (updated == 0) {
      // ⬇️ إصلاح هنا: لا يجوز استخدام cascade مع تعيين بواسطة الفهرس.
      final data = Map<String, dynamic>.from(row);
      data['id'] = id;
      await _db.insert(
        table,
        data,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      await _db.update(
        table,
        updateMap,
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  /// تنفيذ مع إعادة محاولة Backoff بسيطة (3 محاولات إجمالًا).
  Future<T> _withRetry<T>(
      Future<T> Function() action, {
        int maxAttempts = 3,
        Duration firstDelay = const Duration(milliseconds: 350),
      }) async {
    int attempt = 0;
    while (true) {
      try {
        return await action();
      } on PostgrestException catch (e) {
        attempt++;
        if (attempt >= maxAttempts) rethrow;
        final d = firstDelay * attempt;
        _log(
          'Retry after PostgrestException (attempt $attempt/$maxAttempts): code=${e.code} msg=${e.message}',
        );
        await Future.delayed(d);
      } catch (e) {
        attempt++;
        if (attempt >= maxAttempts) rethrow;
        final d = firstDelay * attempt;
        _log(
          'Retry after error (attempt $attempt/$maxAttempts): $e',
        );
        await Future.delayed(d);
      }
    }
  }

  /*──────────────────── Push (رفع) ────────────────────*/

  /// كتابة أعمدة التزامن محليًا (إن وُجدت) قبل الدفع — مع **عدم** الكتابة فوق deviceId/localId إن كانت محفوظة.
  Future<void> _stampLocalSyncMeta({
    required String localTable,
    required int localId,
    required String devId,
  }) async {
    final cols = await _getLocalColumns(localTable);

    final hasAnyMeta = [
      'accountId',
      'account_id',
      'deviceId',
      'device_id',
      'localId',
      'local_id',
      'updatedAt',
      'updated_at',
    ].any(cols.contains);

    if (!hasAnyMeta) return;

    // اقرأ القيم الحالية لتجنب الكتابة فوق origin device/local القادمة من pull
    Map<String, Object?>? existing;
    try {
      existing = (await _db.query(
        localTable,
        columns: [
          if (cols.contains('deviceId')) 'deviceId',
          if (cols.contains('device_id')) 'device_id',
          if (cols.contains('localId')) 'localId',
          if (cols.contains('local_id')) 'local_id',
          if (cols.contains('updatedAt')) 'updatedAt',
          if (cols.contains('updated_at')) 'updated_at',
          if (cols.contains('accountId')) 'accountId',
          if (cols.contains('account_id')) 'account_id',
        ],
        where: 'id = ?',
        whereArgs: [localId],
        limit: 1,
      ))
          .firstOrNull;
    } catch (_) {
      existing = null;
    }

    int? currentLocalId;
    String? currentDeviceId;

    if (existing != null) {
      final vDev = existing['deviceId'] ?? existing['device_id'];
      if (vDev != null) {
        final dv = vDev.toString().trim();
        currentDeviceId = dv.isEmpty || dv.toLowerCase() == 'app-unknown' ? null : dv;
      }

      final vLoc = existing['localId'] ?? existing['local_id'];
      if (vLoc != null) {
        final li = (vLoc is num) ? vLoc.toInt() : int.tryParse('$vLoc');
        if (li != null && li > 0) currentLocalId = li;
      }
    }

    // حدد deviceId المناسب: أبقِ الموجود إن كان صالحًا وإلا استخدم devId الحالي
    final writeDeviceId = currentDeviceId ?? devId;

    // حدد localId المناسب
    int? writeLocalId = currentLocalId;
    if (writeLocalId == null) {
      if (localId > 0 && localId < _composeBlock) {
        writeLocalId = localId;
      } else {
        writeLocalId = await _newLocalId31(
          localTable,
          myDeviceId: writeDeviceId,
        );
      }
    }

    final row = <String, dynamic>{};
    final accCol = _col(cols, 'accountId', 'account_id');
    final devCol = _col(cols, 'deviceId', 'device_id');
    final locCol = _col(cols, 'localId', 'local_id');
    final updCol = _col(cols, 'updatedAt', 'updated_at');

    if (accCol != null) row[accCol] = accountId;
    if (devCol != null) row[devCol] = writeDeviceId;
    if (locCol != null) row[locCol] = writeLocalId ?? localId;
    if (updCol != null) row[updCol] = DateTime.now().toIso8601String();

    if (row.isEmpty) return;

    try {
      await _db.update(localTable, row, where: 'id = ?', whereArgs: [localId]);
    } catch (_) {/* صامت */}
  }

  /// تحويل صف محلي إلى صف سحابي (snake_case) + حقن أعمدة التزامن.
  /// ✅ نرسل **أصل السجل** deviceId/localId إن وُجدا محليًا (قادمين من pull) دون استبدال.
  Future<Map<String, dynamic>> _toRemoteRow({
    required String localTable,
    required String remoteTable,
    required Map<String, dynamic> localRow,
  }) async {
    final data = Map<String, dynamic>.from(localRow);

    // fallback لـ localId عند غيابه
    final dynamic localIdDyn = data['id'];
    int fallbackLocalId =
    (localIdDyn is num) ? localIdDyn.toInt() : int.tryParse('${localIdDyn ?? 0}') ?? 0;
    if (fallbackLocalId <= 0) {
      fallbackLocalId = DateTime.now().millisecondsSinceEpoch % 2147483647;
    }

    // استخدم أصل السجل إن وُجد (من pull السابق)، وإلا fallback لهذا الجهاز
    final String devForRow = (() {
      final dv = (data['deviceId'] ?? data['device_id'])?.toString().trim();
      return (dv != null && dv.isNotEmpty) ? dv : _safeDeviceId;
    })();

    final int locForRow = (() {
      final li = data['localId'] ?? data['local_id'];
      final parsed = (li is num) ? li.toInt() : int.tryParse('${li ?? ''}');
      return parsed ?? fallbackLocalId;
    })();

    // إزالة أعمدة محلية لا نرسلها للسحابة (النسختين camel+snake)
    for (final k in const [
      'id',
      'isDeleted',
      'deletedAt',
      'deviceId',
      'localId',
      'accountId',
      'updatedAt',
      'is_deleted',
      'deleted_at',
      'device_id',
      'local_id',
      'account_id',
      'updated_at',
    ]) {
      data.remove(k);
    }

    // camel->snake (مبدئي)
    var snake = _mapKeysToSnake(data);

    // إن وُجد Mapper مخصص للجدول، طبّقه
    final mapper = _mappers[remoteTable];
    if (mapper?.toCloudMap != null) {
      snake = _mapKeysToSnake(mapper!.toCloudMap!(snake));
    }

    final fkParents = _fkMap[remoteTable];
    if (fkParents != null && fkParents.isNotEmpty) {
      for (final entry in fkParents.entries) {
        final fkSnake = entry.key;
        if (!snake.containsKey(fkSnake)) continue;
        final rawValue = snake[fkSnake];
        if (rawValue == null) {
          snake[fkSnake] = null;
          continue;
        }

        final int parentLocalId = rawValue is num
            ? rawValue.toInt()
            : int.tryParse('${rawValue}') ?? 0;
        if (parentLocalId <= 0) {
          snake[fkSnake] = null;
          continue;
        }

        final parentTable = entry.value;
        final parentTriple = await _readLocalSyncTriple(
          table: parentTable,
          localPrimaryId: parentLocalId,
        );
        if (parentTriple == null) {
          throw MissingRemoteMappingException(
            remoteTable: remoteTable,
            parentTable: parentTable,
            childColumn: fkSnake,
            parentLocalId: parentLocalId,
            reason: 'parent row missing locally',
          );
        }

        final remoteUuid = await _remoteIds.remoteUuidForLocal(
          tableName: parentTable,
          accountId: parentTriple.accountId,
          deviceId: parentTriple.deviceId,
          localId: parentTriple.localId,
        );

        if (remoteUuid == null || remoteUuid.isEmpty) {
          throw MissingRemoteMappingException(
            remoteTable: remoteTable,
            parentTable: parentTable,
            childColumn: fkSnake,
            parentLocalId: parentLocalId,
            reason: 'remote UUID mapping missing',
          );
        }

        snake[fkSnake] = remoteUuid;
      }
    }

    // فلترة allow-list كمسار احتياطي
    final tableAllow = _remoteAllow[remoteTable];
    if (tableAllow != null && tableAllow.isNotEmpty) {
      snake.removeWhere((k, _) => !_reservedCols.contains(k) && !tableAllow.contains(k));
    }

    // حقول التزامن — نرسل أصل السجل
    snake['account_id'] = accountId;
    snake['device_id'] = devForRow;
    snake['local_id'] = locForRow;
    snake['updated_at'] = DateTime.now().toIso8601String();

    // تحويل القيم البوليانية
    final normalized = <String, dynamic>{};
    snake.forEach((k, v) {
      normalized[k] = _toRemoteValue(remoteTable, k, v);
    });

    return normalized;
  }

  Future<void> _pushTable(String localTable, String remoteTable) async {
    if (!_hasAccount) {
      _log('PUSH $remoteTable skipped (no accountId)');
      return;
    }
    if (!_hasDevice) {
      _log(
        'PUSH $remoteTable skipped (no deviceId). Set a real deviceId to avoid cross-device conflicts.',
      );
      return;
    }
    while (_pushBusy[remoteTable] == true) {
      await Future.delayed(const Duration(milliseconds: 120));
    }
    _pushBusy[remoteTable] = true;
    try {
      // 0) دفع حذف السجلات المعلّمة محليًا
      await _pushDeletedRows(localTable, remoteTable);

      // 1) نرفع الصفوف غير المحذوفة منطقيًا
      final cols = await _getLocalColumns(localTable);
      final hasIsDeletedSnake = cols.contains('is_deleted');
      final hasIsDeletedCamel = cols.contains('isDeleted');
      final delCol =
      hasIsDeletedSnake ? 'is_deleted' : (hasIsDeletedCamel ? 'isDeleted' : null);

      final whereClause = delCol != null ? 'IFNULL($delCol,0)=0' : null;

      final localRows = await _db.query(
        localTable,
        where: whereClause,
        whereArgs: null,
      );
      if (localRows.isEmpty) return;

      // وسم أعمدة المزامنة محليًا (إن وُجدت) — دون الكتابة فوق origin device/local
      final devId = _safeDeviceId;
      for (final r in localRows) {
        final int id = (r['id'] as num).toInt();
        await _stampLocalSyncMeta(localTable: localTable, localId: id, devId: devId);
      }

      // تجهيز ودفع
      final prepared = <Map<String, dynamic>>[];
      final fkErrors = <String>[];
      for (final row in localRows) {
        int attempts = 0;
        bool added = false;
        while (attempts < 2 && !added) {
          attempts++;
          try {
            final remoteRow = await _toRemoteRow(
              localTable: localTable,
              remoteTable: remoteTable,
              localRow: row,
            );
            prepared.add(remoteRow);
            added = true;
          } on MissingRemoteMappingException catch (e) {
            if (attempts >= 2) {
              fkErrors.add(
                '${e.childColumn} -> ${e.parentTable}#${e.parentLocalId}: ${e.reason}',
              );
            } else {
              await _pushNow(e.parentTable);
            }
          }
        }
      }

      if (prepared.isEmpty) {
        if (fkErrors.isNotEmpty) {
          _log('PUSH $remoteTable: ${fkErrors.length} FK mapping errors\n  - ${fkErrors.join('\n  - ')}');
        }
        return;
      }

      for (final chunk in _chunkify(prepared, _pushChunkSize)) {
        if (chunk.isEmpty) continue;
        try {
          _log('PUSH $remoteTable: ${chunk.length} rows (acc=$accountId, dev=$_safeDeviceId)');
          final resp = await _withRetry(() async {
            final result = await _client
                .from(remoteTable)
                .upsert(
                  chunk,
                  onConflict: _conflictKey,
                  ignoreDuplicates: false,
                )
                .select('id, account_id, device_id, local_id');
            return result as List<dynamic>;
          });
          for (final dynamic rec in resp) {
            if (rec is! Map) continue;
            final map = Map<String, dynamic>.from(rec as Map);
            final remoteUuid = '${map['id'] ?? ''}'.trim();
            final acc = '${map['account_id'] ?? accountId}'.trim();
            final dev = '${map['device_id'] ?? _safeDeviceId}'.trim();
            final loc = map['local_id'];
            final localId = loc is num ? loc.toInt() : int.tryParse('${loc ?? ''}') ?? 0;
            if (remoteUuid.isEmpty || localId <= 0) continue;
            await _remoteIds.saveMapping(
              tableName: remoteTable,
              accountId: acc.isEmpty ? accountId : acc,
              deviceId: dev.isEmpty ? _safeDeviceId : dev,
              localId: localId,
              remoteUuid: remoteUuid,
            );
          }
        } on PostgrestException catch (e) {
          final String code = e.code ?? '';
          final String msg = e.message;
          final String det = e.details?.toString() ?? '';

          // 1) تعارض الاسم الفريد (drugs)
          final bool isNameUniqueConflict = (remoteTable == 'drugs') &&
              code == '23505' &&
              (msg.contains('uidx_drugs_name_per_account') ||
                  msg.contains('drugs_unique_name_per_account') ||
                  (msg.contains('unique') && msg.contains('name')) ||
                  det.contains('uidx_drugs_name_per_account') ||
                  det.contains('drugs_unique_name_per_account'));

          if (isNameUniqueConflict) {
            _log('PUSH $remoteTable: unique-name conflict -> merging by (account_id,name)');
            await _mergeByNaturalKey(remoteTable, 'name', accountScoped: true, rows: chunk);
            continue;
          }

          // 1-b) تعارض فريد مركّب لعناصر المخزون (type_id,name)
          final bool isItemsCompositeConflict = (remoteTable == 'items') &&
              code == '23505' &&
              ((msg.contains('type_id') && msg.contains('name')) ||
                  msg.contains('items_type_name') ||
                  (det.contains('type_id') && det.contains('name')));

          if (isItemsCompositeConflict) {
            _log(
              'PUSH $remoteTable: composite natural key conflict -> merging by (account_id,type_id,name)',
            );
            await _mergeByCompositeNaturalKeys(remoteTable, ['type_id', 'name'],
                accountScoped: true, rows: chunk);
            continue;
          }

          // 2) تعارض الفهرس المركب (account_id,device_id,local_id)
          final bool looksLikeComposite = code == '23505' &&
              (msg.contains('uix_acc_dev_local') ||
                  msg.contains('account_local_idx') ||
                  msg.contains('account_device_local_idx') ||
                  msg.contains('account_id, device_id, local_id') ||
                  (det.contains('account_id') &&
                      det.contains('device_id') &&
                      det.contains('local_id')));

          if (looksLikeComposite) {
            _log(
              'PUSH $remoteTable: composite-idx conflict -> fallback UPDATE by (account_id,device_id,local_id)',
            );
            await _fallbackUpdateByComposite(remoteTable, chunk);
            continue;
          }

          _log('PUSH FAILED for $remoteTable: code=$code message=$msg details=$det');
          continue; // لا نرمي الاستثناء
        } catch (e) {
          _log('PUSH FAILED for $remoteTable: $e');
          continue;
        }
      }

      if (fkErrors.isNotEmpty) {
        _log('PUSH $remoteTable: ${fkErrors.length} FK mapping errors\n  - ${fkErrors.join('\n  - ')}');
      }
    } finally {
      _pushBusy[remoteTable] = false;
    }
  }

  /// دمج اعتمادًا على مفتاح طبيعي واحد (مثل name) داخل نفس الحساب.
  Future<void> _mergeByNaturalKey(
      String remoteTable,
      String key, {
        required bool accountScoped,
        required List<Map<String, dynamic>> rows,
      }) async {
    for (final row in rows) {
      try {
        final val = (row[key] ?? '').toString();
        if (val.isEmpty) continue;

        final updateMap = Map<String, dynamic>.from(row)
          ..remove('account_id')
          ..remove('device_id')
          ..remove('local_id');

        if (updateMap.isEmpty || (updateMap.keys.length == 1 && updateMap.containsKey(key))) {
          continue;
        }

        final q = _client.from(remoteTable).update(updateMap);
        if (accountScoped) {
          await q.eq('account_id', accountId).eq(key, val);
        } else {
          await q.eq(key, val);
        }
      } catch (e) {
        _log('mergeByNaturalKey($remoteTable) failed: $e');
      }
    }
  }

  /// دمج اعتمادًا على عدة مفاتيح طبيعية (مثلاً items: type_id+name) داخل الحساب.
  Future<void> _mergeByCompositeNaturalKeys(
      String remoteTable,
      List<String> keys, {
        required bool accountScoped,
        required List<Map<String, dynamic>> rows,
      }) async {
    for (final row in rows) {
      try {
        // تحقق من وجود كل المفاتيح
        bool hasAll = true;
        for (final k in keys) {
          if ((row[k] ?? '').toString().isEmpty) {
            hasAll = false;
            break;
          }
        }
        if (!hasAll) continue;

        final updateMap = Map<String, dynamic>.from(row)
          ..remove('account_id')
          ..remove('device_id')
          ..remove('local_id');

        // لا معنى للتحديث إذا لم يبق شيء
        for (final k in keys) {
          updateMap.remove(k);
        }
        if (updateMap.isEmpty) continue;

        var q = _client.from(remoteTable).update(updateMap);
        if (accountScoped) {
          q = q.eq('account_id', accountId);
        }
        for (final k in keys) {
          q = q.eq(k, row[k]);
        }
        await q;
      } catch (e) {
        _log('mergeByCompositeNaturalKeys($remoteTable) failed: $e');
      }
    }
  }

  /// تراجع عند تعارض الفهرس المركَّب: تحديث الصفوف الموجودة بالمفتاح (account_id,device_id,local_id)
  Future<void> _fallbackUpdateByComposite(
      String remoteTable,
      List<Map<String, dynamic>> rows,
      ) async {
    for (final row in rows) {
      try {
        final acc = (row['account_id'] ?? accountId).toString();
        final dev = (row['device_id'] ?? _safeDeviceId).toString();
        final locDyn = row['local_id'];
        final loc = (locDyn is num) ? locDyn.toInt() : int.tryParse('${locDyn ?? 0}') ?? 0;

        // حقول التحديث فقط (بدون مفاتيح التعارض)
        final updateMap = Map<String, dynamic>.from(row)
          ..remove('account_id')
          ..remove('device_id')
          ..remove('local_id');

        if (updateMap.isEmpty) {
          // لا يوجد ما يُحدَّث؛ جرّب الإدراج مباشرة
          try {
            await _withRetry(() async {
              await _client.from(remoteTable).insert(row);
            });
          } catch (e) {
            _log('fallbackUpdateByComposite[$remoteTable]: insert-only failed: $e');
          }
          continue;
        }

        // 1) UPDATE وقراءة عدد الصفوف المتأثرة
        int updatedCount = 0;
        try {
          final res = await _withRetry(() async {
            final List<dynamic> r = await _client
                .from(remoteTable)
                .update(updateMap)
                .eq('account_id', acc)
                .eq('device_id', dev)
                .eq('local_id', loc)
                .select('local_id');
            return r.length;
          });
          updatedCount = res;
        } catch (e) {
          _log('fallbackUpdateByComposite[$remoteTable]: update error → $e');
        }

        // 2) إن لم يوجد سجل لنحدّثه → INSERT كامل
        if (updatedCount == 0) {
          try {
            await _withRetry(() async {
              await _client.from(remoteTable).insert(row);
            });
          } on PostgrestException catch (e) {
            // لو حصل سباق وأعطى duplicate مرة أخرى، أعد UPDATE وتجاوز
            final code = e.code ?? '';
            final msg = e.message;
            if (code == '23505' && msg.contains('acc') && msg.contains('local')) {
              try {
                await _client
                    .from(remoteTable)
                    .update(updateMap)
                    .eq('account_id', acc)
                    .eq('device_id', dev)
                    .eq('local_id', loc);
              } catch (_) {/* تجاهل */}
            } else {
              _log('fallbackUpdateByComposite[$remoteTable]: insert failed: $e');
            }
          } catch (e) {
            _log('fallbackUpdateByComposite[$remoteTable]: insert failed: $e');
          }
        }
      } catch (e) {
        _log('fallbackUpdateByComposite[$remoteTable]: failed for one row: $e');
      }
    }
  }

  /// ✅ حذف الصفوف من Supabase التي وُسمت محليًا isDeleted=1 (بغض النظر عن id < 1e9)
  /// الحذف يتم حسب أصل السجل (deviceId/localId) إن وُجدا محليًا.
  Future<void> _pushDeletedRows(String localTable, String remoteTable) async {
    if (!_hasAccount) return;

    final cols = await _getLocalColumns(localTable);
    final hasIsDeletedSnake = cols.contains('is_deleted');
    final hasIsDeletedCamel = cols.contains('isDeleted');
    final delCol =
    hasIsDeletedSnake ? 'is_deleted' : (hasIsDeletedCamel ? 'isDeleted' : null);
    if (delCol == null) return; // الجدول لا يدعم الحذف المنطقي محليًا

    final rows = await _db.query(
      localTable,
      columns: [
        'id',
        if (cols.contains('deviceId')) 'deviceId',
        if (cols.contains('device_id')) 'device_id',
        if (cols.contains('localId')) 'localId',
        if (cols.contains('local_id')) 'local_id',
      ],
      where: 'IFNULL($delCol,0)=1',
    );
    if (rows.isEmpty) return;

    for (final r in rows) {
      try {
        final String originDev = (() {
          final dv = (r['deviceId'] ?? r['device_id'])?.toString().trim();
          return (dv != null && dv.isNotEmpty) ? dv : _safeDeviceId;
        })();

        final int originLocal = (() {
          final li = r['localId'] ?? r['local_id'];
          final parsed = (li is num) ? li.toInt() : int.tryParse('${li ?? ''}');
          return parsed ?? (r['id'] as num).toInt();
        })();

        _log('PUSH DELETE $remoteTable: (acc=$accountId, dev=$originDev, local=$originLocal)');
        await _withRetry(() async {
          await _client
              .from(remoteTable)
              .delete()
              .eq('account_id', accountId)
              .eq('device_id', originDev)
              .eq('local_id', originLocal);
        });
      } catch (e) {
        _log('PUSH DELETE FAILED for $remoteTable: $e');
      }
    }
  }

  /*──────────────────── Pull (سحب) ────────────────────*/

  /// تطبيق تحويل fromMap على سجل سحابي إلى سجل محلي، مع احترام الأعمدة المتاحة محليًا.
  Map<String, dynamic> _fromRemoteRow({
    required String localTable,
    required String remoteTable,
    required Map<String, dynamic> remoteRowSnake,
    required Set<String> allowedCols,
  }) {
    // مسار Mapper مخصص (يماثل model.fromMap())
    final mapper = _mappers[remoteTable];
    Map<String, dynamic> working = Map<String, dynamic>.from(remoteRowSnake);
    if (mapper?.fromCloudMap != null) {
      working = mapper!.fromCloudMap!(working, allowedCols);
    }

    // تصفية snake/camel + تحويل Bool → 0/1
    final filtered = <String, dynamic>{};
    working.forEach((snakeKey, value) {
      final camelKey = _toCamel(snakeKey);
      if (allowedCols.contains(snakeKey)) {
        filtered[snakeKey] = _toLocalValue(localTable, snakeKey, value);
      } else if (allowedCols.contains(camelKey)) {
        filtered[camelKey] = _toLocalValue(localTable, camelKey, value);
      }
    });
    return filtered;
  }

  Future<void> _pullTable(String localTable, String remoteTable) async {
    if (!_hasAccount) {
      _log('PULL $remoteTable skipped (no accountId)');
      return;
    }

    final allowedCols = await _getLocalColumns(localTable);
    final selectClause = _buildSelectClause(
      allowedCols,
      remoteAllowed: _remoteAllow[remoteTable],
    );

    int from = 0;
    final myDeviceId = _safeDeviceId;

    while (true) {
      final to = from + _pullPageSize - 1;
      List<dynamic> remoteRows;
      try {
        remoteRows = await _withRetry(() async {
          return await _client
              .from(remoteTable)
              .select(selectClause)
              .eq('account_id', accountId)
              .order('local_id', ascending: true)
              .range(from, to);
        });
      } catch (e) {
        _log('PULL FAILED for $remoteTable: $e');
        break;
      }
      if (remoteRows.isEmpty) break;

      _log('PULL $remoteTable: got ${remoteRows.length} rows');

      for (final dynamic row in remoteRows) {
        final raw = Map<String, dynamic>.from(row);

        final dynamic rawLocalId = raw['local_id'];
        final int sourceLocalId =
            rawLocalId is num ? rawLocalId.toInt() : int.tryParse(rawLocalId.toString()) ?? 0;

        final String remoteDeviceIdRaw = (raw['device_id'] ?? '').toString().trim();
        final String remoteDeviceId =
            remoteDeviceIdRaw.isEmpty ? _safeDeviceId : remoteDeviceIdRaw;

        final String? remoteUpdatedAt =
            (raw['updated_at'] ?? '').toString().isNotEmpty ? raw['updated_at'].toString() : null;
        final String remoteUuid = (raw['id'] ?? '').toString();

        int? localId = await _findLocalRowIdByTriple(
          table: localTable,
          accountIdForRow: accountId,
          deviceIdForRow: remoteDeviceId,
          remoteLocalId: sourceLocalId,
        );

        if (localId == null) {
          localId = sourceLocalId;
          if (remoteDeviceId.isNotEmpty &&
              myDeviceId.isNotEmpty &&
              remoteDeviceId != myDeviceId) {
            localId = _composeCrossDeviceId(remoteDeviceId, sourceLocalId);
          }
        }

        raw.remove('account_id');
        raw.remove('local_id');
        raw.remove('device_id');
        raw.remove('id');

        final filtered = _fromRemoteRow(
          localTable: localTable,
          remoteTable: remoteTable,
          remoteRowSnake: raw,
          allowedCols: allowedCols,
        );

        final accCol = _col(allowedCols, 'accountId', 'account_id');
        final devCol = _col(allowedCols, 'deviceId', 'device_id');
        final locCol = _col(allowedCols, 'localId', 'local_id');
        final updCol = _col(allowedCols, 'updatedAt', 'updated_at');

        if (accCol != null) filtered[accCol] = accountId;
        if (devCol != null) filtered[devCol] = remoteDeviceId;
        if (locCol != null) {
          filtered[locCol] = sourceLocalId;
        }
        if (updCol != null && remoteUpdatedAt != null) {
          filtered[updCol] = remoteUpdatedAt;
        }

        await _upsertLocalNonDestructive(localTable, filtered, id: localId);

        if (remoteUuid.isNotEmpty && sourceLocalId > 0) {
          await _remoteIds.saveMapping(
            tableName: remoteTable,
            accountId: accountId,
            deviceId: remoteDeviceId,
            localId: sourceLocalId,
            remoteUuid: remoteUuid,
          );
        }
      }

      await _clampAutoincrement(localTable);

      from += remoteRows.length;
      if (remoteRows.length < _pullPageSize) break;
    }
  }

  Future<int?> _findLocalIdByRawFk(String parentLocalTable, int rawFk) async {
    final direct = await _db.rawQuery(
      'SELECT id FROM $parentLocalTable WHERE id = ? LIMIT 1',
      [rawFk],
    );
    if (direct.isNotEmpty) return (direct.first['id'] as int);

    final mod = await _db.rawQuery(
      'SELECT id FROM $parentLocalTable WHERE (id % $_composeBlock) = ? LIMIT 1',
      [rawFk],
    );
    if (mod.isNotEmpty) return (mod.first['id'] as int);

    return null;
  }

  Future<dynamic> _remapOneFkValue({
    required String parentLocalTable,
    required String childLocalTable,
    required String childLocalColumnName, // camel أو snake
    required String remoteDeviceIdOfRow,
    required String myDeviceId,
    required dynamic currentValue,
  }) async {
    if (currentValue == null) return null;

    final String remoteUuid = currentValue.toString().trim();
    if (remoteUuid.isEmpty) return null;

    final mapping = await _remoteIds.tripleForRemoteUuid(
      tableName: parentLocalTable,
      remoteUuid: remoteUuid,
    );

    int? resolved;
    if (mapping != null) {
      final acc = mapping.accountId.isNotEmpty ? mapping.accountId : accountId;
      final dev = mapping.deviceId.isNotEmpty ? mapping.deviceId : remoteDeviceIdOfRow;
      resolved = await _findLocalRowIdByTriple(
        table: parentLocalTable,
        accountIdForRow: acc,
        deviceIdForRow: dev,
        remoteLocalId: mapping.localId,
      );
      resolved ??= await _findLocalIdByRawFk(parentLocalTable, mapping.localId);
    }

    if (resolved == null && mapping != null) {
      if (remoteDeviceIdOfRow.isNotEmpty &&
          myDeviceId.isNotEmpty &&
          remoteDeviceIdOfRow != myDeviceId) {
        final candidate = _composeCrossDeviceId(remoteDeviceIdOfRow, mapping.localId);
        final rows = await _db.rawQuery(
          'SELECT id FROM $parentLocalTable WHERE id = ? LIMIT 1',
          [candidate],
        );
        if (rows.isNotEmpty) {
          final v = rows.first['id'];
          resolved = v is num ? v.toInt() : int.tryParse('${v ?? ''}');
        }
      }
    }

    if (resolved == null) {
      _log('FK remap failed for $childLocalTable.$childLocalColumnName → $parentLocalTable (uuid=$remoteUuid)');
      return null;
    }

    final colType = (await _getLocalColumnType(childLocalTable, childLocalColumnName)) ?? '';
    final isText = colType.contains('TEXT');
    final dynamic val = isText ? resolved.toString() : resolved;

    return _toLocalValue(childLocalTable, childLocalColumnName, val);
  }

  Future<void> _pullTableRemapFKs(
      String localTable,
      String remoteTable, {
        required Map<String, String> fkParentTables, // fkSnake -> parentLocalTable
      }) async {
    if (!_hasAccount) {
      _log('PULL $remoteTable skipped (no accountId)');
      return;
    }
    final allowedCols = await _getLocalColumns(localTable);
    final selectClause = _buildSelectClause(
      allowedCols,
      extraCols: fkParentTables.keys,
      remoteAllowed: _remoteAllow[remoteTable],
    );

    int from = 0;
    final myDeviceId = _safeDeviceId;

    while (true) {
      final to = from + _pullPageSize - 1;
      List<dynamic> remoteRows;
      try {
        remoteRows = await _withRetry(() async {
          return await _client
              .from(remoteTable)
              .select(selectClause)
              .eq('account_id', accountId)
              .order('local_id', ascending: true)
              .range(from, to);
        });
      } catch (e) {
        _log('PULL FAILED for $remoteTable: $e');
        break;
      }
      if (remoteRows.isEmpty) break;

      _log('PULL $remoteTable: got ${remoteRows.length} rows');

      for (final dynamic row in remoteRows) {
        final raw = Map<String, dynamic>.from(row);

        final dynamic rawLocalId = raw['local_id'];
        final int sourceLocalId =
            rawLocalId is num ? rawLocalId.toInt() : int.tryParse(rawLocalId.toString()) ?? 0;

        final String remoteDeviceIdRaw = (raw['device_id'] ?? '').toString().trim();
        final String remoteDeviceId =
            remoteDeviceIdRaw.isEmpty ? _safeDeviceId : remoteDeviceIdRaw;

        final String? remoteUpdatedAt =
            (raw['updated_at'] ?? '').toString().isNotEmpty ? raw['updated_at'].toString() : null;
        final String remoteUuid = (raw['id'] ?? '').toString();

        int? localId = await _findLocalRowIdByTriple(
          table: localTable,
          accountIdForRow: accountId,
          deviceIdForRow: remoteDeviceId,
          remoteLocalId: sourceLocalId,
        );

        if (localId == null) {
          localId = sourceLocalId;
          if (remoteDeviceId.isNotEmpty &&
              myDeviceId.isNotEmpty &&
              remoteDeviceId != myDeviceId) {
            localId = _composeCrossDeviceId(remoteDeviceId, sourceLocalId);
          }
        }

        raw.remove('account_id');
        raw.remove('local_id');
        raw.remove('device_id');
        raw.remove('id');

        final filtered = _fromRemoteRow(
          localTable: localTable,
          remoteTable: remoteTable,
          remoteRowSnake: raw,
          allowedCols: allowedCols,
        );

        for (final entry in fkParentTables.entries) {
          final fkSnake = entry.key;
          final parentTable = entry.value;
          final fkCamel = _toCamel(fkSnake);

          if (filtered.containsKey(fkSnake)) {
            filtered[fkSnake] = await _remapOneFkValue(
              parentLocalTable: parentTable,
              childLocalTable: localTable,
              childLocalColumnName: fkSnake,
              remoteDeviceIdOfRow: remoteDeviceId,
              myDeviceId: myDeviceId,
              currentValue: filtered[fkSnake],
            );
          } else if (filtered.containsKey(fkCamel)) {
            filtered[fkCamel] = await _remapOneFkValue(
              parentLocalTable: parentTable,
              childLocalTable: localTable,
              childLocalColumnName: fkCamel,
              remoteDeviceIdOfRow: remoteDeviceId,
              myDeviceId: myDeviceId,
              currentValue: filtered[fkCamel],
            );
          }
        }

        final accCol = _col(allowedCols, 'accountId', 'account_id');
        final devCol = _col(allowedCols, 'deviceId', 'device_id');
        final locCol = _col(allowedCols, 'localId', 'local_id');
        final updCol = _col(allowedCols, 'updatedAt', 'updated_at');

        if (accCol != null) filtered[accCol] = accountId;
        if (devCol != null) filtered[devCol] = remoteDeviceId;
        if (locCol != null) {
          filtered[locCol] = sourceLocalId;
        }
        if (updCol != null && remoteUpdatedAt != null) {
          filtered[updCol] = remoteUpdatedAt;
        }

        await _upsertLocalNonDestructive(localTable, filtered, id: localId);

        if (remoteUuid.isNotEmpty && sourceLocalId > 0) {
          await _remoteIds.saveMapping(
            tableName: remoteTable,
            accountId: accountId,
            deviceId: remoteDeviceId,
            localId: sourceLocalId,
            remoteUuid: remoteUuid,
          );
        }
      }

      await _clampAutoincrement(localTable); // ← منع قفزة AUTOINCREMENT بعد السحب (FK)

      from += remoteRows.length;
      if (remoteRows.length < _pullPageSize) break;
    }
  }

  /*──────────────────── Realtime (اشتراك لحظي) ────────────────────*/

  final Map<String, RealtimeChannel> _channels = {};

  RealtimeChannel _ensureChannel(String key) {
    return _channels.putIfAbsent(key, () {
      final ch = _client.channel(key);
      return ch;
    });
  }

  Future<void> _subscribeTableRealtime(
      String localTable,
      String remoteTable, {
        Map<String, String>? fkParentTables,
      }) async {
    if (!_hasAccount) return;
    final key = 'rt:$remoteTable:$accountId';
    // إغلاق القناة القديمة إن وُجدت بنفس المفتاح لتفادي الازدواج
    if (_channels.containsKey(key)) {
      try {
        await _channels[key]!.unsubscribe();
        _client.removeChannel(_channels[key]!);
      } catch (_) {}
      _channels.remove(key);
    }

    final ch = _ensureChannel(key);

    ch.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: remoteTable,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'account_id',
        value: accountId,
      ),
      callback: (payload) async {
        await _applyRealtimeUpsert(
          localTable,
          remoteTable,
          payload.newRecord,
          fkParentTables,
        );
      },
    );

    ch.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: remoteTable,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'account_id',
        value: accountId,
      ),
      callback: (payload) async {
        await _applyRealtimeUpsert(
          localTable,
          remoteTable,
          payload.newRecord,
          fkParentTables,
        );
      },
    );

    ch.onPostgresChanges(
      event: PostgresChangeEvent.delete,
      schema: 'public',
      table: remoteTable,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'account_id',
        value: accountId,
      ),
      callback: (payload) async {
        await _applyRealtimeDelete(localTable, payload.oldRecord);
      },
    );

    try {
      ch.subscribe();
      _log('Realtime subscribed: $remoteTable (acc=$accountId)');
    } catch (e) {
      _log('Realtime subscribe failed for $remoteTable: $e');
    }
  }

  Future<void> _applyRealtimeUpsert(
      String localTable,
      String remoteTable,
      Map<String, dynamic>? newRecord,
      Map<String, String>? fkParentTables,
      ) async {
    if (newRecord == null || !_hasAccount) return;

    final allowedCols = await _getLocalColumns(localTable);
    final myDeviceId = _safeDeviceId;

    final raw = Map<String, dynamic>.from(newRecord);
    final dynamic rawLocalId = raw['local_id'];
    final int sourceLocalId =
        rawLocalId is num ? rawLocalId.toInt() : int.tryParse(rawLocalId.toString()) ?? 0;

    final String remoteDeviceIdRaw = (raw['device_id'] ?? '').toString().trim();
    final String remoteDeviceId =
        remoteDeviceIdRaw.isEmpty ? _safeDeviceId : remoteDeviceIdRaw;

    final String? remoteUpdatedAt =
        (raw['updated_at'] ?? '').toString().isNotEmpty ? raw['updated_at'].toString() : null;
    final String remoteUuid = (raw['id'] ?? '').toString();

    int? localId = await _findLocalRowIdByTriple(
      table: localTable,
      accountIdForRow: accountId,
      deviceIdForRow: remoteDeviceId,
      remoteLocalId: sourceLocalId,
    );

    if (localId == null) {
      localId = sourceLocalId;
      if (remoteDeviceId.isNotEmpty &&
          myDeviceId.isNotEmpty &&
          remoteDeviceId != myDeviceId) {
        localId = _composeCrossDeviceId(remoteDeviceId, sourceLocalId);
      }
    }

    raw.remove('account_id');
    raw.remove('local_id');
    raw.remove('device_id');
    raw.remove('id');

    final filtered = _fromRemoteRow(
      localTable: localTable,
      remoteTable: remoteTable,
      remoteRowSnake: raw,
      allowedCols: allowedCols,
    );

    if (fkParentTables != null) {
      for (final entry in fkParentTables.entries) {
        final fkSnake = entry.key;
        final parentTable = entry.value;
        final fkCamel = _toCamel(fkSnake);

        if (filtered.containsKey(fkSnake)) {
          filtered[fkSnake] = await _remapOneFkValue(
            parentLocalTable: parentTable,
            childLocalTable: localTable,
            childLocalColumnName: fkSnake,
            remoteDeviceIdOfRow: remoteDeviceId,
            myDeviceId: myDeviceId,
            currentValue: filtered[fkSnake],
          );
        } else if (filtered.containsKey(fkCamel)) {
          filtered[fkCamel] = await _remapOneFkValue(
            parentLocalTable: parentTable,
            childLocalTable: localTable,
            childLocalColumnName: fkCamel,
            remoteDeviceIdOfRow: remoteDeviceId,
            myDeviceId: myDeviceId,
            currentValue: filtered[fkCamel],
          );
        }
      }
    }

    final accCol = _col(allowedCols, 'accountId', 'account_id');
    final devCol = _col(allowedCols, 'deviceId', 'device_id');
    final locCol = _col(allowedCols, 'localId', 'local_id');
    final updCol = _col(allowedCols, 'updatedAt', 'updated_at');

    if (accCol != null) filtered[accCol] = accountId;
    if (devCol != null) filtered[devCol] = remoteDeviceId;
    if (locCol != null) {
      filtered[locCol] = sourceLocalId;
    }
    if (updCol != null && remoteUpdatedAt != null) {
      filtered[updCol] = remoteUpdatedAt;
    }

    await _upsertLocalNonDestructive(localTable, filtered, id: localId);

    if (remoteUuid.isNotEmpty && sourceLocalId > 0) {
      await _remoteIds.saveMapping(
        tableName: remoteTable,
        accountId: accountId,
        deviceId: remoteDeviceId,
        localId: sourceLocalId,
        remoteUuid: remoteUuid,
      );
    }

    await _clampAutoincrement(localTable); // ← منع قفزة AUTOINCREMENT بعد Realtime upsert
  }

  Future<void> _applyRealtimeDelete(
      String localTable,
      Map<String, dynamic>? oldRecord,
      ) async {
    if (oldRecord == null || !_hasAccount) return;

    final allowedCols = await _getLocalColumns(localTable);
    final myDeviceId = _safeDeviceId;

    final raw = Map<String, dynamic>.from(oldRecord);
    final dynamic rawLocalId = raw['local_id'];
    final int sourceLocalId =
        rawLocalId is num ? rawLocalId.toInt() : int.tryParse(rawLocalId.toString()) ?? 0;

    final String remoteDeviceIdRaw = (raw['device_id'] ?? '').toString().trim();
    final String remoteDeviceId =
        remoteDeviceIdRaw.isEmpty ? _safeDeviceId : remoteDeviceIdRaw;
    final String remoteUuid = (raw['id'] ?? '').toString();

    int? localId = await _findLocalRowIdByTriple(
      table: localTable,
      accountIdForRow: accountId,
      deviceIdForRow: remoteDeviceId,
      remoteLocalId: sourceLocalId,
    );

    if (localId == null) {
      localId = sourceLocalId;
      if (remoteDeviceId.isNotEmpty &&
          myDeviceId.isNotEmpty &&
          remoteDeviceId != myDeviceId) {
        localId = _composeCrossDeviceId(remoteDeviceId, sourceLocalId);
      }
    }

    if (localId == null) return;

    // لو الجدول يدعم الحذف المنطقي محليًا، علِّمه محذوفًا، وإلا احذف فعليًا
    if (allowedCols.contains('isDeleted')) {
      await _db.update(
        localTable,
        {
          'isDeleted': 1,
          if (allowedCols.contains('deletedAt')) 'deletedAt': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [localId],
      );
    } else if (allowedCols.contains('is_deleted')) {
      await _db.update(
        localTable,
        {
          'is_deleted': 1,
          if (allowedCols.contains('deleted_at')) 'deleted_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [localId],
      );
    } else {
      await _db.delete(localTable, where: 'id = ?', whereArgs: [localId]);
    }

    if (remoteUuid.isNotEmpty && sourceLocalId > 0) {
      await _remoteIds.saveMapping(
        tableName: localTable,
        accountId: accountId,
        deviceId: remoteDeviceId,
        localId: sourceLocalId,
        remoteUuid: remoteUuid,
      );
    }
  }

  /// اشترك في كل الجداول (Realtime) لهذا الحساب.
  Future<void> startRealtime() async {
    // ✅ تفادي ازدواج الاشتراكات عند إعادة التهيئة (مثلاً بعد تغيير المستخدم)
    await stopRealtime();
    if (!_hasAccount) {
      _log('Realtime skipped (no accountId)');
      return;
    }

    // لا نُشغّل Realtime للمرفقات (محلي فقط)
    await _subscribeTableRealtime('drugs', 'drugs');
    await _subscribeTableRealtime('item_types', 'item_types');
    await _subscribeTableRealtime('items', 'items', fkParentTables: _fkMap['items']);
    await _subscribeTableRealtime('medical_services', 'medical_services');
    await _subscribeTableRealtime('doctors', 'doctors', fkParentTables: _fkMap['doctors']);
    await _subscribeTableRealtime(
        'service_doctor_share', 'service_doctor_share', fkParentTables: _fkMap['service_doctor_share']);

    await _subscribeTableRealtime('patients', 'patients', fkParentTables: _fkMap['patients']);
    await _subscribeTableRealtime('returns', 'returns');
    await _subscribeTableRealtime('appointments', 'appointments', fkParentTables: _fkMap['appointments']);

    await _subscribeTableRealtime('prescriptions', 'prescriptions', fkParentTables: _fkMap['prescriptions']);
    await _subscribeTableRealtime(
        'prescription_items', 'prescription_items', fkParentTables: _fkMap['prescription_items']);
    await _subscribeTableRealtime('complaints', 'complaints');

    await _subscribeTableRealtime('consumptions', 'consumptions', fkParentTables: _fkMap['consumptions']);
    await _subscribeTableRealtime('purchases', 'purchases', fkParentTables: _fkMap['purchases']);
    await _subscribeTableRealtime('alert_settings', 'alert_settings', fkParentTables: _fkMap['alert_settings']);

    await _subscribeTableRealtime('employees', 'employees');
    await _subscribeTableRealtime('employees_loans', 'employees_loans', fkParentTables: _fkMap['employees_loans']);
    await _subscribeTableRealtime('employees_salaries', 'employees_salaries', fkParentTables: _fkMap['employees_salaries']);
    await _subscribeTableRealtime('employees_discounts', 'employees_discounts', fkParentTables: _fkMap['employees_discounts']);

    await _subscribeTableRealtime('financial_logs', 'financial_logs');
    await _subscribeTableRealtime('patient_services', 'patient_services', fkParentTables: _fkMap['patient_services']);
  }

  /// إلغاء جميع الاشتراكات.
  Future<void> stopRealtime() async {
    for (final ch in _channels.values) {
      try {
        await ch.unsubscribe();
        _client.removeChannel(ch);
      } catch (_) {}
    }
    _channels.clear();
    _log('Realtime unsubscribed from all tables');
  }

  /// Bootstrap مريح بعد تسجيل الدخول (سحب أولي + اشتراك لحظي)
  Future<void> bootstrap({bool pull = true, bool realtime = true}) async {
    _log('Bootstrap sync (acc=$accountId, dev=$_safeDeviceId) pull=$pull, rt=$realtime');
    if (!_hasAccount) {
      _log('Bootstrap skipped (no accountId)');
      return;
    }
    if (pull) {
      await pullAll();
    }
    if (realtime) {
      await startRealtime();
    }
  }

  /// إعادة ربط الخدمة عند تغيّر الحساب/الجهاز
  Future<void> rebind({
    required String newAccountId,
    String? newDeviceId,
    bool initialPull = false,
    bool restartRealtime = true,
  }) async {
    final changedAcc = (newAccountId != accountId);
    final changedDev = (newDeviceId != null && newDeviceId != deviceId);

    if (!changedAcc && !changedDev) {
      _log('rebind: nothing changed');
      return;
    }

    _log(
      'rebind → acc: $accountId -> $newAccountId, dev: ${deviceId ?? "null"} -> ${newDeviceId ?? deviceId ?? "null"}',
    );

    // أوقف أي اشتراكات قديمة مربوطة على account_id السابق
    await stopRealtime();

    accountId = newAccountId;
    if (newDeviceId != null) {
      deviceId = newDeviceId;
    }

    if (initialPull) {
      await pullAll();
    }
    if (restartRealtime) {
      await startRealtime();
    }
  }

  /// تنظيف سريع
  Future<void> dispose() async {
    await stopRealtime();
    // أوقف كل مؤقّتات الدفع المؤجّل
    for (final t in _pushTimers.values) {
      t.cancel();
    }
    _pushTimers.clear();
  }

  /*──────────────────── جداول محددة (واجهات علنية) ───────────────────*/

  Future<void> pushPatients() => _pushTable('patients', 'patients');
  Future<void> pullPatients() => _pullTableRemapFKs(
    'patients',
    'patients',
    fkParentTables: _fkMap['patients']!,
  );

  Future<void> pushReturns() => _pushTable('returns', 'returns');
  Future<void> pullReturns() => _pullTable('returns', 'returns');

  Future<void> pushConsumptions() => _pushTable('consumptions', 'consumptions');
  Future<void> pullConsumptions() => _pullTableRemapFKs(
    'consumptions',
    'consumptions',
    fkParentTables: _fkMap['consumptions']!,
  );

  Future<void> pushDrugs() => _pushTable('drugs', 'drugs');
  Future<void> pullDrugs() => _pullTable('drugs', 'drugs');

  Future<void> pushPrescriptions() => _pushTable('prescriptions', 'prescriptions');
  Future<void> pullPrescriptions() => _pullTableRemapFKs(
    'prescriptions',
    'prescriptions',
    fkParentTables: _fkMap['prescriptions']!,
  );

  Future<void> pushPrescriptionItems() =>
      _pushTable('prescription_items', 'prescription_items');
  Future<void> pullPrescriptionItems() => _pullTableRemapFKs(
    'prescription_items',
    'prescription_items',
    fkParentTables: _fkMap['prescription_items']!,
  );

  Future<void> pushComplaints() => _pushTable('complaints', 'complaints');
  Future<void> pullComplaints() => _pullTable('complaints', 'complaints');

  Future<void> pushAppointments() => _pushTable('appointments', 'appointments');
  Future<void> pullAppointments() => _pullTableRemapFKs(
    'appointments',
    'appointments',
    fkParentTables: _fkMap['appointments']!,
  );

  Future<void> pushDoctors() => _pushTable('doctors', 'doctors');
  Future<void> pullDoctors() => _pullTableRemapFKs(
    'doctors',
    'doctors',
    fkParentTables: _fkMap['doctors']!,
  );

  Future<void> pushConsumptionTypes() =>
      _pushTable('consumption_types', 'consumption_types');
  Future<void> pullConsumptionTypes() => _pullTable('consumption_types', 'consumption_types');

  Future<void> pushMedicalServices() =>
      _pushTable('medical_services', 'medical_services');
  Future<void> pullMedicalServices() => _pullTable('medical_services', 'medical_services');

  Future<void> pushServiceDoctorShares() =>
      _pushTable('service_doctor_share', 'service_doctor_share');
  Future<void> pullServiceDoctorShares() => _pullTableRemapFKs(
    'service_doctor_share',
    'service_doctor_share',
    fkParentTables: _fkMap['service_doctor_share']!,
  );

  Future<void> pushEmployees() => _pushTable('employees', 'employees');
  Future<void> pullEmployees() => _pullTable('employees', 'employees');

  Future<void> pushEmployeeLoans() => _pushTable('employees_loans', 'employees_loans');
  Future<void> pullEmployeeLoans() => _pullTableRemapFKs(
    'employees_loans',
    'employees_loans',
    fkParentTables: _fkMap['employees_loans']!,
  );

  Future<void> pushEmployeeSalaries() =>
      _pushTable('employees_salaries', 'employees_salaries');
  Future<void> pullEmployeeSalaries() => _pullTableRemapFKs(
    'employees_salaries',
    'employees_salaries',
    fkParentTables: _fkMap['employees_salaries']!,
  );

  Future<void> pushEmployeeDiscounts() =>
      _pushTable('employees_discounts', 'employees_discounts');
  Future<void> pullEmployeeDiscounts() => _pullTableRemapFKs(
    'employees_discounts',
    'employees_discounts',
    fkParentTables: _fkMap['employees_discounts']!,
  );

  Future<void> pushItemTypes() => _pushTable('item_types', 'item_types');
  Future<void> pullItemTypes() => _pullTable('item_types', 'item_types');

  Future<void> pushItems() => _pushTable('items', 'items');
  Future<void> pullItems() => _pullTableRemapFKs(
    'items',
    'items',
    fkParentTables: _fkMap['items']!,
  );

  Future<void> pushPurchases() => _pushTable('purchases', 'purchases');
  Future<void> pullPurchases() => _pullTableRemapFKs(
    'purchases',
    'purchases',
    fkParentTables: _fkMap['purchases']!,
  );

  Future<void> pushAlertSettings() => _pushTable('alert_settings', 'alert_settings');
  Future<void> pullAlertSettings() => _pullTableRemapFKs(
    'alert_settings',
    'alert_settings',
    fkParentTables: _fkMap['alert_settings']!,
  );

  Future<void> pushFinancialLogs() => _pushTable('financial_logs', 'financial_logs');
  Future<void> pullFinancialLogs() => _pullTable('financial_logs', 'financial_logs');

  Future<void> pushPatientServices() =>
      _pushTable('patient_services', 'patient_services');
  Future<void> pullPatientServices() => _pullTableRemapFKs(
    'patient_services',
    'patient_services',
    fkParentTables: _fkMap['patient_services']!,
  );

  /*──────────────────── Bulk (مرتَّبة حسب الاعتمادات) ───────────────────*/

  Future<void> pushAll() async {
    // أسس
    await pushItemTypes();
    await pushItems();
    await pushDrugs();
    await pushMedicalServices();
    await pushEmployees();
    await pushDoctors();

    // نسب الأطباء
    await pushServiceDoctorShares();

    // معاملات مرضى
    await pushPatients();
    await pushPatientServices();
    await pushReturns();
    await pushAppointments();
    await pushPrescriptions();
    await pushPrescriptionItems();
    await pushConsumptions();
    await pushPurchases();
    await pushAlertSettings();

    // مالية/موارد بشرية إضافية
    await pushEmployeeLoans();
    await pushEmployeeSalaries();
    await pushEmployeeDiscounts();

    await pushComplaints();
    await pushFinancialLogs();
  }

  Future<void> pullAll() async {
    // أسس
    await pullItemTypes();
    await pullItems();
    await pullDrugs();
    await pullMedicalServices();
    await pullEmployees();
    await pullDoctors();

    // نسب الأطباء
    await pullServiceDoctorShares();

    // معاملات مرضى
    await pullPatients();
    await pullPatientServices();
    await pullReturns();
    await pullAppointments();
    await pullPrescriptions();
    await pullPrescriptionItems();
    await pullConsumptions();
    await pullPurchases();
    await pullAlertSettings();

    // مالية/موارد بشرية إضافية
    await pullEmployeeLoans();
    await pullEmployeeSalaries();
    await pullEmployeeDiscounts();

    await pullComplaints();
    await pullFinancialLogs();
  }

  /*──────────────────── Triggered Push (لـ onLocalChange) ───────────────────*/

  /// جدولة دفع مؤجّل لجدول معيّن. يُدمج عدة تغييرات خلال نافذة pushDebounce.
  Future<void> _schedulePush(String key, Future<void> Function() action) async {
    // ألغِ مؤقّت سابق إن وجد
    _pushTimers[key]?.cancel();
    _pushTimers[key] = Timer(pushDebounce, () async {
      try {
        await action();
      } finally {
        _pushTimers.remove(key);
      }
    });
  }

  Future<void> _pushNow(String table) async {
    switch (table) {
      case 'patients':
        return pushPatients();
      case 'returns':
        return pushReturns();
      case 'consumptions':
        return pushConsumptions();
      case 'drugs':
        return pushDrugs();
      case 'prescriptions':
        return pushPrescriptions();
      case 'prescription_items':
        return pushPrescriptionItems();
      case 'complaints':
        return pushComplaints();
      case 'appointments':
        return pushAppointments();
      case 'doctors':
        return pushDoctors();
      case 'consumption_types':
        return pushConsumptionTypes();
      case 'medical_services':
        return pushMedicalServices();
      case 'service_doctor_share':
        return pushServiceDoctorShares();
      case 'employees':
        return pushEmployees();
      case 'employees_loans':
        return pushEmployeeLoans();
      case 'employees_salaries':
        return pushEmployeeSalaries();
      case 'employees_discounts':
        return pushEmployeeDiscounts();
      case 'items':
        return pushItems();
      case 'item_types':
        return pushItemTypes();
      case 'purchases':
        return pushPurchases();
      case 'alert_settings':
        return pushAlertSettings();
      case 'financial_logs':
        return pushFinancialLogs();
      case 'patient_services':
        return pushPatientServices();
      case 'attachments':
        _log('attachments is local-only. Skipping push.');
        return Future.value();
      default:
        _log('No push handler for table: $table');
        return Future.value();
    }
  }

  /// استدعِ هذه من `DBService.onLocalChange` — ستُجَدول دفعة بعد 1s لكل جدول.
  Future<void> pushFor(String table) async {
    switch (table) {
      case 'attachments':
        _log('attachments is local-only. Skipping push.');
        return;
      default:
        return _schedulePush(table, () => _pushNow(table));
    }
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
