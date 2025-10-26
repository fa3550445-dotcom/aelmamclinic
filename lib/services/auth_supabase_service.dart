// lib/services/auth_supabase_service.dart
//
// خدمة المصادقة وإدارة الحسابات عبر Supabase + تشغيل المزامنة المحلية.
// - تسجيل الدخول/الخروج + Bootstrap للمزامنة (SQLite) وفق الحساب الفعّال.
// - حراسة Realtime: تجميد الحساب/تعطيل الموظف ⇒ تسجيل خروج قسري.
// - وظائف مساعدة: إنشاء مالك/موظف، أذونات الميزات، العيادات، السجلات.
// - توابع إضافية صغيرة (تحديث كلمة المرور/جلسة، مستمع تغيّر جلسة).
//
// ملاحظات مهمة:
// * الكود يتسامح مع اختلافات المخططات القديمة/الجديدة: يحاول Functions → RPC → وصول مباشر.
// * عند تبدّل الحساب بين تشغيلين، يتم تصفير الجداول المحلية (parity v3 تجهّز المخطط).
// * SuperAdmin يتجاوز المزامنة وحراسة الحساب (قراءة مباشرة).
//
// يعتمد على:
//   - supabase_flutter
//   - ./device_id_service.dart
//   - ./db_service.dart
//   - ./sync_service.dart
//   - ./db_parity_v3.dart
//   - ./realtime_hub.dart   ← NEW (قناة موحّدة لتغييرات الشات) — اختياري
//   - ./chat_service.dart   ← NEW (لتنظيف قناة typing الموحّدة) — اختياري

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/clinic.dart';

import './device_id_service.dart';
import './db_service.dart';
import './sync_service.dart';
import './db_parity_v3.dart'; // مواءمة محليّة مع السحابة (parity v3)
// ملاحظة: استيراد realtime_hub/chat_service اختياريان. إن لم تكن الملفات موجودة فلا تستوردها.
// import './realtime_hub.dart';
// import './chat_service.dart';

// ───────────────────── نماذج داخلية ─────────────────────

/// تمثيل الحساب الفعّال للمستخدم الحالي (مالك/موظف) مع صلاحية الكتابة.
class ActiveAccount {
  final String id;
  final String role;
  final bool canWrite;
  const ActiveAccount({
    required this.id,
    required this.role,
    required this.canWrite,
  });
}

/// تمثيل صلاحيات الميزات وعمليات CRUD لموظف ضمن حساب.
class FeaturePermissions {
  final Set<String> allowedFeatures;
  final bool canCreate;
  final bool canUpdate;
  final bool canDelete;

  const FeaturePermissions({
    required this.allowedFeatures,
    required this.canCreate,
    required this.canUpdate,
    required this.canDelete,
  });

  FeaturePermissions copyWith({
    Set<String>? allowedFeatures,
    bool? canCreate,
    bool? canUpdate,
    bool? canDelete,
  }) {
    return FeaturePermissions(
      allowedFeatures: allowedFeatures ?? this.allowedFeatures,
      canCreate: canCreate ?? this.canCreate,
      canUpdate: canUpdate ?? this.canUpdate,
      canDelete: canDelete ?? this.canDelete,
    );
  }

  static FeaturePermissions defaultsAllAllowed() => const FeaturePermissions(
    allowedFeatures: <String>{},
    canCreate: true,
    canUpdate: true,
    canDelete: true,
  );

  factory FeaturePermissions.fromRpcPayload(dynamic payload) {
    Map<String, dynamic>? row;
    if (payload is Map) {
      row = Map<String, dynamic>.from(payload as Map);
    } else if (payload is List && payload.isNotEmpty) {
      row = Map<String, dynamic>.from(payload.first as Map);
    }
    if (row == null) return FeaturePermissions.defaultsAllAllowed();

    final list =
        (row['allowed_features'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    return FeaturePermissions(
      allowedFeatures: Set<String>.from(list),
      canCreate: (row['can_create'] as bool?) ?? true,
      canUpdate: (row['can_update'] as bool?) ?? true,
      canDelete: (row['can_delete'] as bool?) ?? true,
    );
  }
}

/// سجل تدقيق واحد (Audit Log) كما في جدول audit_logs.
class AuditLogEntry {
  final int id;
  final String accountId;
  final String? actorUid;
  final String? actorEmail;
  final String tableName;
  final String op; // insert/update/delete
  final String? rowPk;
  final Map<String, dynamic>? beforeRow;
  final Map<String, dynamic>? afterRow;
  final Map<String, dynamic>? diff;
  final DateTime createdAt;

  AuditLogEntry({
    required this.id,
    required this.accountId,
    required this.actorUid,
    required this.actorEmail,
    required this.tableName,
    required this.op,
    required this.rowPk,
    required this.beforeRow,
    required this.afterRow,
    required this.diff,
    required this.createdAt,
  });

  factory AuditLogEntry.fromJson(Map<String, dynamic> m) => AuditLogEntry(
    id: (m['id'] as num).toInt(),
    accountId: m['account_id'] as String,
    actorUid: m['actor_uid'] as String?,
    actorEmail: m['actor_email'] as String?,
    tableName: m['table_name'] as String,
    op: m['op'] as String,
    rowPk: m['row_pk']?.toString(),
    beforeRow:
    m['before_row'] is Map ? Map<String, dynamic>.from(m['before_row'] as Map) : null,
    afterRow:
    m['after_row'] is Map ? Map<String, dynamic>.from(m['after_row'] as Map) : null,
    diff: m['diff'] is Map ? Map<String, dynamic>.from(m['diff'] as Map) : null,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}

// ───────────────────── الخدمة الرئيسية ─────────────────────

class AuthSupabaseService {
  final SupabaseClient _client = Supabase.instance.client;

  /// بريد السوبر أدمن (يُستخدم في عدة أماكن)
  static const String superAdminEmail = 'aelmam.app@gmail.com';

  SupabaseClient get client => _client;

  // مرجع SyncService + تجميعة دفع مؤجلة لكل جدول
  SyncService? _sync;
  String? _boundAccountId; // آخر حساب تم ربط المزامنة عليه
  final Map<String, Timer> _pushTimers = {};
  Duration _debounce = const Duration(seconds: 1);

  // 🔒 قنوات Realtime للحراسة (تجميد الحساب/تعطيل الموظف)
  RealtimeChannel? _guardAccountsChannel;
  RealtimeChannel? _guardAccountUsersChannel;
  RealtimeChannel? _guardClinicsChannel; // لمخططات قديمة تحفظ frozen في clinics

  // مستمع تغيّر حالة المصادقة (اختياري)
  StreamSubscription<AuthState>? _authListener;

  // ───── ربط دفع المزامنة عند تغيّر DB المحلي ─────

  void _bindDbPush(SyncService sync) {
    DBService.instance.onLocalChange = (String table) async {
      _pushTimers.remove(table)?.cancel();
      _pushTimers[table] = Timer(_debounce, () {
        if (_sync == sync) {
          dev.log('Sync push (debounced) → $table');
          sync.pushFor(table);
        }
        _pushTimers.remove(table);
      });
      return;
    };
  }

  void _clearPushBinds() {
    for (final t in _pushTimers.values) {
      t.cancel();
    }
    _pushTimers.clear();
    DBService.instance.onLocalChange = null;
  }

  Future<void> _disposeSync() async {
    try {
      await _sync?.dispose();
    } catch (_) {}
    _sync = null;
    _boundAccountId = null;
    _clearPushBinds();
    return;
  }

  Future<void> _stopRealtimeAccountGuards() async {
    try {
      await _guardAccountsChannel?.unsubscribe();
    } catch (_) {}
    try {
      await _guardAccountUsersChannel?.unsubscribe();
    } catch (_) {}
    try {
      await _guardClinicsChannel?.unsubscribe();
    } catch (_) {}
    _guardAccountsChannel = null;
    _guardAccountUsersChannel = null;
    _guardClinicsChannel = null;
  }

  /// تنظيف شامل لقنوات Realtime العامة.
  Future<void> _cleanupGlobalRealtime() async {
    // 1) (اختياري) إغلاق قنوات الشات الموحّدة إن كانت لديك RealtimeHub
    // try { RealtimeHub.instance.close(); } catch (_) {}

    // 2) (اختياري) تنظيف قناة typing إن كانت موجودة في ChatService
    // try { await ChatService.instance.disposeTyping(); } catch (_) {}

    // 3) كنس أي قنوات متبقية على العميل
    try {
      final client = Supabase.instance.client;
      try {
        for (final ch in client.getChannels()) {
          try {
            await ch.unsubscribe();
          } catch (_) {}
        }
      } catch (_) {}
      client.removeAllChannels();
    } catch (_) {}
  }

  Future<void> _forceLogout(String reason) async {
    dev.log('Force logout: $reason');
    await _disposeSync();
    await _stopRealtimeAccountGuards();
    await _cleanupGlobalRealtime();
    try {
      await _client.auth.signOut();
    } catch (e) {
      dev.log('signOut during forceLogout failed: $e');
    }
  }

  Future<void> _startRealtimeAccountGuards({
    required String accountId,
    required String userUid,
  }) async {
    // أوقف القديم إن وجد
    await _stopRealtimeAccountGuards();

    // مراقبة تجميد الحساب على accounts.frozen (المخطط الحديث)
    _guardAccountsChannel = _client
        .channel('guards:accounts:$accountId')
        .onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'accounts',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'id',
        value: accountId,
      ),
      callback: (payload) {
        try {
          final newRec = payload.newRecord ?? const <String, dynamic>{};
          final id = (newRec['id'] ?? '').toString();
          final frozen = (newRec['frozen'] == true);
          if (id == accountId && frozen) {
            _forceLogout('account frozen');
          }
        } catch (e) {
          dev.log('accounts guard callback err: $e');
        }
      },
    )
        .subscribe();

    // مراقبة تعطيل الموظف ضمن الحساب
    _guardAccountUsersChannel = _client
        .channel('guards:account_users:$accountId')
        .onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'account_users',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'account_id',
        value: accountId,
      ),
      callback: (payload) {
        try {
          final newRec = payload.newRecord ?? const <String, dynamic>{};
          final acc = (newRec['account_id'] ?? '').toString();
          final uid = (newRec['user_uid'] ?? '').toString();
          final disabled = (newRec['disabled'] == true);
          if (acc == accountId && uid == userUid && disabled) {
            _forceLogout('employee disabled');
          }
        } catch (e) {
          dev.log('account_users guard callback err: $e');
        }
      },
    )
        .subscribe();

    // راقب clinics.frozen أيضًا (لبعض البيئات)
    _guardClinicsChannel = _client
        .channel('guards:clinics:$accountId')
        .onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: Clinic.table, // عادة "clinics"
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'id',
        value: accountId,
      ),
      callback: (payload) {
        try {
          final m = payload.newRecord ?? const <String, dynamic>{};
          final id = (m['id'] ?? '').toString();
          final frozen = (m['frozen'] == true);
          if (id == accountId && frozen) {
            _forceLogout('clinic frozen');
          }
        } catch (e) {
          dev.log('clinics guard callback err: $e');
        }
      },
    )
        .subscribe();
  }

  // يضمن وجود sync_identity ثم يحدّثها بالقيم الحالية
  Future<void> _upsertSyncIdentity(
      dynamic db, {
        required String accountId,
        required String deviceId,
      }) async {
    try {
      await db.execute('CREATE TABLE IF NOT EXISTS sync_identity(account_id TEXT, device_id TEXT)');
      await db.rawInsert(
        'INSERT INTO sync_identity(account_id, device_id) '
            'SELECT ?, ? WHERE NOT EXISTS(SELECT 1 FROM sync_identity)',
        [accountId, deviceId],
      );
      await db.rawUpdate(
        'UPDATE sync_identity SET account_id = ?, device_id = ?',
        [accountId, deviceId],
      );
    } catch (e) {
      dev.log('sync_identity write failed: $e');
    }
  }

  /// يقرأ account_id المخزّن آخر مرة محليًا (إن وجد) من sync_identity.
  Future<String?> _readLastSyncedAccountId(dynamic db) async {
    try {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
        ['sync_identity'],
      );
      if (rows is List && rows.isNotEmpty) {
        final r = await db.rawQuery('SELECT account_id FROM sync_identity LIMIT 1');
        if (r is List && r.isNotEmpty) {
          final v = r.first['account_id']?.toString();
          return (v != null && v.isNotEmpty) ? v : null;
        }
      }
    } catch (e) {
      dev.log('_readLastSyncedAccountId failed: $e');
    }
    return null;
  }

  // ─────────────────── Helpers: Functions/RPC ───────────────────

  Future<Map<String, dynamic>> _invokeFunction(
      String name, {
        required Map<String, dynamic> body,
      }) async {
    final resp = await _client.functions.invoke(
      name,
      body: body,
      headers: {'Content-Type': 'application/json'},
    );

    final data = resp.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        return Map<String, dynamic>.from(jsonDecode(data));
      } catch (_) {
        return {'ok': true, 'raw': data};
      }
    }
    return {'ok': true, 'raw': data};
  }

  Future<Map<String, dynamic>> _invokeTryMany({
    required List<String> names,
    required Map<String, dynamic> body,
  }) async {
    Object? lastErr;
    for (final n in names) {
      try {
        final data = await _invokeFunction(n, body: body);
        dev.log('Function "$n" executed.');
        return data;
      } catch (e, st) {
        lastErr = e;
        Object? status;
        try {
          status = (e as dynamic).status ?? (e as dynamic).statusCode;
        } catch (_) {}
        dev.log('Function "$n" failed (${status ?? 'unknown'}). Trying next...',
            error: e, stackTrace: st);
      }
    }
    throw lastErr ?? Exception('No callable function found for ${names.join(", ")}');
  }

  Future<String?> _resolveAccountIdForUid(String uid) async {
    try {
      final prof =
      await _client.from('profiles').select('account_id, role').eq('id', uid).maybeSingle();
      final pAcc = prof?['account_id'] as String?;
      if (pAcc != null && pAcc.isNotEmpty) return pAcc;
    } catch (e) {
      dev.log('profiles lookup failed: $e');
    }

    try {
      final au = await _client
          .from('account_users')
          .select('account_id')
          .eq('user_uid', uid)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final aAcc = au?['account_id'] as String?;
      if (aAcc != null && aAcc.isNotEmpty) return aAcc;
    } catch (e) {
      dev.log('account_users lookup failed: $e');
    }

    final u = _client.auth.currentUser;
    final appMeta = u?.appMetadata;
    final mAcc = (appMeta?['account_id'] as String?);
    if (mAcc != null && mAcc.isNotEmpty) return mAcc;

    return null;
  }

  // ─────────────────── مصادقة أساسية ───────────────────

  Future<AuthResponse> signIn(String email, String password) {
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signOut() async {
    await _disposeSync();
    await _stopRealtimeAccountGuards();
    await _cleanupGlobalRealtime();
    await _client.auth.signOut();
    return;
  }

  /// تحديث كلمة المرور للمستخدم الحالي.
  Future<void> changePassword(String newPassword) async {
    await _client.auth.updateUser(UserAttributes(password: newPassword));
  }

  /// إرسال بريد إعادة تعيين كلمة المرور.
  Future<void> requestPasswordReset(String email, {String? redirectTo}) async {
    await _client.auth.resetPasswordForEmail(
      email,
      redirectTo: redirectTo,
    );
  }

  /// تحديث جلسة مبدئي بسيط (مفيد بعد تغيير كلمة المرور).
  Future<void> refreshSession() async {
    try {
      await _client.auth.refreshSession();
    } catch (e) {
      dev.log('refreshSession failed: $e');
    }
  }

  /// مستمع تغيّر حالة المصادقة (اختياري للاستخدام من الـ Provider).
  /// - عند SIGNED_OUT: يوقف المزامنة والحراسة + ينظّف كل قنوات Realtime.
  /// - عند SIGNED_IN: لا يشغّل المزامنة تلقائيًا (اتركها لـ bootstrapSyncForCurrentUser).
  void attachAuthStateListener() {
    _authListener?.cancel();
    _authListener = _client.auth.onAuthStateChange.listen((event) async {
      final t = event.event;
      dev.log('Auth state: $t');
      if (t == AuthChangeEvent.signedOut || t == AuthChangeEvent.userDeleted) {
        await _disposeSync();
        await _stopRealtimeAccountGuards();
        await _cleanupGlobalRealtime();
      }
    });
  }

  void detachAuthStateListener() {
    _authListener?.cancel();
    _authListener = null;
  }

  bool get isSuperAdmin {
    final email = _client.auth.currentUser?.email?.toLowerCase();
    final metaRole =
    (_client.auth.currentUser?.appMetadata['role'] as String?)?.toLowerCase();
    return email == superAdminEmail.toLowerCase() || metaRole == 'superadmin';
  }

  bool get isSignedIn => _client.auth.currentUser != null;

  // ─────────────────── تحديد الحساب الفعّال ───────────────────

  Future<String?> resolveAccountId() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      dev.log('resolveAccountId: no current user.');
      return null;
    }

    try {
      final res = await _client.rpc('my_account_id');
      if (res != null) {
        final acc = res.toString();
        if (acc.isNotEmpty && acc != 'null') {
          dev.log('resolveAccountId: using my_account_id → $acc');
          return acc;
        }
      }
    } catch (e) {
      dev.log('resolveAccountId: my_account_id RPC failed: $e');
    }

    try {
      final list = await _client.rpc('my_accounts');
      if (list is List && list.isNotEmpty) {
        final acc = '${list.first}';
        if (acc.isNotEmpty && acc != 'null') {
          dev.log('resolveAccountId: using my_accounts[0] → $acc');
          return acc;
        }
      }
    } catch (e) {
      dev.log('resolveAccountId: my_accounts RPC failed: $e');
    }

    final fb = await _resolveAccountIdForUid(user.id);
    if (fb != null && fb.isNotEmpty) {
      dev.log('resolveAccountId: fallback(uid) → $fb');
      return fb;
    }

    dev.log('resolveAccountId: could not resolve account_id.');
    return null;
  }

  Future<String> requireAccountId() async {
    final acc = await resolveAccountId();
    if (acc == null || acc.isEmpty) {
      throw StateError('Unable to resolve account_id for current user.');
    }
    return acc;
  }

  /// مسار صارم وآمن (profiles فقط) لتحديد الحساب الفعّال.
  Future<ActiveAccount> resolveActiveAccountOrThrow() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('Not signed in.');
    }

    try {
      final prof =
      await _client.from('profiles').select('account_id, role').eq('id', user.id).maybeSingle();
      final pAcc = (prof?['account_id'] as String?)?.trim();
      if (pAcc != null && pAcc.isNotEmpty) {
        final role = (prof?['role'] as String?) ?? 'employee';
        return ActiveAccount(id: pAcc, role: role, canWrite: true);
      }
    } catch (e) {
      dev.log('resolveActiveAccountOrThrow: profiles lookup failed: $e');
    }

    try {
      final acc = await _client.rpc('my_account_id');
      if (acc != null && '$acc' != 'null' && '$acc'.toString().isNotEmpty) {
        String role = 'employee';
        try {
          final au = await _client
              .from('account_users')
              .select('role')
              .eq('user_uid', user.id)
              .eq('account_id', '$acc')
              .order('created_at', ascending: false)
              .limit(1)
              .maybeSingle();
          role = (au?['role'] as String?) ?? role;
        } catch (_) {}
        return ActiveAccount(id: '$acc', role: role, canWrite: true);
      }
    } catch (e) {
      dev.log('resolveActiveAccountOrThrow: my_account_id fallthrough: $e');
    }

    final fb = await _resolveAccountIdForUid(user.id);
    if (fb != null && fb.isNotEmpty) {
      return ActiveAccount(id: fb, role: 'employee', canWrite: true);
    }

    throw StateError('No active clinic found for this user.');
  }

  // ─────────────────── Bootstrap للمزامنة ───────────────────

  Future<void> signInAndBootstrapSync({
    required String email,
    required String password,
    bool pull = true,
    bool realtime = true,
    bool enableLogs = false,
    Duration debounce = const Duration(seconds: 1),
    bool wipeLocalFirst = false,
  }) async {
    await signIn(email, password);

    if (isSuperAdmin) {
      dev.log('SuperAdmin signed in: skip sync bootstrap.');
      return;
    }

    await bootstrapSyncForCurrentUser(
      pull: pull,
      realtime: realtime,
      enableLogs: enableLogs,
      debounce: debounce,
      wipeLocalFirst: wipeLocalFirst,
    );
    return;
  }

  Future<void> bootstrapSyncForCurrentUser({
    bool pull = true,
    bool realtime = true,
    bool enableLogs = false,
    Duration debounce = const Duration(seconds: 1),
    bool wipeLocalFirst = false,
  }) async {
    if (isSuperAdmin) {
      dev.log('SuperAdmin: skip sync bootstrap.');
      await _disposeSync();
      await _stopRealtimeAccountGuards();
      return;
    }

    final acc = await resolveActiveAccountOrThrow();
    final devId = await DeviceIdService.getId();
    final db = await DBService.instance.database;

    try {
      final lastAcc = await _readLastSyncedAccountId(db);
      final accountChangedBetweenLaunches =
      (lastAcc != null && lastAcc.isNotEmpty && lastAcc != acc.id);
      if (accountChangedBetweenLaunches) {
        dev.log('Detected account change since last launch → clearing local tables.');
        await DBService.instance.clearAllLocalTables();
      }
    } catch (e) {
      dev.log('read last sync_identity failed: $e');
    }

    if (_sync != null) {
      final accountChanged = (_boundAccountId != null && _boundAccountId != acc.id);
      if (wipeLocalFirst && accountChanged) {
        await DBService.instance.clearAllLocalTables();
      }
      await _disposeSync();
    }

    await _upsertSyncIdentity(db, accountId: acc.id, deviceId: devId);

    // parity v3 يضمن وجود الجداول/الأعمدة محليًا (تحمّل المخططات الأقدم)
    try {
      await DBParityV3().run(db, accountId: acc.id, verbose: enableLogs);
    } catch (e, st) {
      dev.log('DBParityV3.run failed (continue anyway)', error: e, stackTrace: st);
    }

    _debounce = debounce;
    _sync = SyncService(db, acc.id, deviceId: devId, enableLogs: enableLogs);
    _boundAccountId = acc.id;

    _bindDbPush(_sync!);

    await _sync!.bootstrap(pull: pull, realtime: realtime);

    try {
      final userUid = _client.auth.currentUser?.id;
      if (userUid != null && userUid.isNotEmpty) {
        await _startRealtimeAccountGuards(accountId: acc.id, userUid: userUid);
      }
    } catch (e) {
      dev.log('startRealtimeAccountGuards failed: $e');
    }

    return;
  }

  /// أعد تشغيل المزامنة فقط إذا اختلف الحساب الحالي عن الحساب المربوط.
  Future<void> rebootstrapIfAccountChanged({
    bool pull = true,
    bool realtime = true,
    bool enableLogs = false,
  }) async {
    if (isSuperAdmin) return;
    final acc = await resolveAccountId();
    if (acc == null || acc.isEmpty) return;
    if (_boundAccountId == null || _boundAccountId != acc) {
      dev.log('Account changed at runtime → re-bootstrap sync.');
      await bootstrapSyncForCurrentUser(
        pull: pull,
        realtime: realtime,
        enableLogs: enableLogs,
        debounce: _debounce,
      );
    }
  }

  // ─────────────────── إنشاء حساب رئيسي/موظف ───────────────────

  Future<void> createClinicAccount({
    required String clinicName,
    required String ownerEmail,
    required String ownerPassword,
    String? ownerRole,
  }) =>
      registerOwner(
        clinicName: clinicName,
        email: ownerEmail,
        password: ownerPassword,
        ownerRole: ownerRole,
      );

  Future<void> registerOwner({
    required String clinicName,
    required String email,
    required String password,
    String? ownerRole,
  }) async {
    if (!isSuperAdmin) {
      dev.log('registerOwner called by non-super admin. This may fail due to RLS.');
    }

    try {
      final res = await _client.rpc('admin_create_owner_full', params: {
        'p_clinic_name': clinicName,
        'p_owner_email': email,
        'p_owner_password': password,
      });
      if (res is Map) {
        final ok = (res['ok'] == true);
        if (ok) return;
        dev.log('admin_create_owner_full returned non-ok: $res');
      } else if (res != null) {
        return;
      }
    } catch (e, st) {
      dev.log('admin_create_owner_full RPC failed, trying functions...',
          error: e, stackTrace: st);
    }

    final body = {
      'clinic_name': clinicName,
      'owner_email': email,
      'owner_password': password,
      // حقول توافقية
      'name': clinicName,
      'ownerEmail': email,
      'ownerPassword': password,
    };

    if (ownerRole != null && ownerRole.isNotEmpty) {
      body['owner_role'] = ownerRole;
    }

    try {
      final data = await _invokeTryMany(
        names: const [
          'admin__create_clinic_owner',
          'admin_create_clinic_owner',
          'create_clinic_owner',
          'create_owner',
        ],
        body: body,
      );
      final ok = (data['ok'] == true) || (data['success'] == true);
      if (ok) {
        return;
      }
      dev.log('registerOwner: function returned non-ok, using RPC old. data=$data');
    } catch (e) {
      dev.log('registerOwner: function(s) failed. Will use old RPC. err=$e');
    }

    try {
      final params = <String, dynamic>{
        'clinic_name': clinicName,
        'owner_email': email,
      };
      if (ownerRole != null && ownerRole.isNotEmpty) {
        params['owner_role'] = ownerRole;
      }
      final res = await _client.rpc(
        'admin_bootstrap_clinic_for_email',
        params: params,
      );
      if (res != null && '$res'.isNotEmpty && '$res' != 'null') {
        return;
      }
      throw Exception('RPC returned null/empty result.');
    } catch (rpcErr, st) {
      dev.log('registerOwner RPC fallback failed', error: rpcErr, stackTrace: st);
      rethrow;
    }
  }

  Future<void> createEmployeeAccount({
    required String clinicId,
    required String email,
    required String password,
  }) =>
      registerEmployee(accountId: clinicId, email: email, password: password);

  Future<void> registerEmployee({
    required String accountId,
    required String email,
    required String password,
  }) async {
    if (!isSuperAdmin) {
      dev.log('registerEmployee called by non-super admin. This may fail due to RLS.');
    }

    try {
      final res = await _client.rpc('admin_create_employee_full', params: {
        'p_account': accountId,
        'p_email': email,
        'p_password': password,
      });

      if (res is Map) {
        final ok = (res['ok'] == true);
        if (ok) return;
        dev.log('admin_create_employee_full returned non-ok: $res');
      } else if (res != null) {
        return;
      }
    } catch (e, st) {
      dev.log('admin_create_employee_full RPC failed, trying functions...',
          error: e, stackTrace: st);
    }

    final body = {
      'account_id': accountId,
      'email': email,
      'password': password,
      'accountId': accountId, // توافقية
    };

    try {
      final data = await _invokeTryMany(
        names: const [
          'admin__create_employee',
          'admin_create_employee',
          'create_employee',
        ],
        body: body,
      );
      final ok = (data['ok'] == true) || (data['success'] == true);
      if (!ok) {
        throw Exception('Failed to create employee: ${data.toString()}');
      }
      return;
    } catch (e, st) {
      dev.log('registerEmployee failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// (اختياري / للبيئات الداخلية فقط) — يتطلب Service Role؛ قد يفشل بسبب RLS في الكلاينت.
  Future<void> registerEmployeeDirect({
    required String accountId,
    required String email,
    required String password,
  }) async {
    final res =
    await _client.auth.admin.createUser(AdminUserAttributes(email: email, password: password));
    final userId = res.user!.id;

    await _client.from('profiles').insert({
      'id': userId,
      'role': 'employee',
      'account_id': accountId,
    });

    await _client.from('account_users').insert({
      'account_id': accountId,
      'user_uid': userId,
      'role': 'employee',
      'disabled': false,
    });
    return;
  }

  // ─────────────────── إدارة العيادات / القراءة ───────────────────

  Future<List<Clinic>> fetchClinics() async {
    final user = _client.auth.currentUser;
    if (user == null) return [];

    if (isSuperAdmin) {
      try {
        final res = await _client.rpc('admin_list_clinics');
        final rows = (res as List? ?? const [])
            .map<Clinic>((r) => Clinic.fromJson(Map<String, dynamic>.from(r)))
            .toList();
        return rows;
      } catch (e, st) {
        dev.log('admin_list_clinics RPC failed, fallback to direct select',
            error: e, stackTrace: st);
        try {
          final rows = await _client
              .from(Clinic.table)
              .select('id, name, frozen, created_at')
              .order('created_at', ascending: false);
          return (rows as List)
              .map<Clinic>((r) => Clinic.fromJson(Map<String, dynamic>.from(r)))
              .toList();
        } catch (e2, st2) {
          dev.log('super-admin direct select failed', error: e2, stackTrace: st2);
          return [];
        }
      }
    }

    // مستخدم عادي: استعمل my_accounts() أولًا
    List<String> accountIds = [];
    try {
      final res = await _client.rpc('my_accounts');
      if (res is List) {
        accountIds = res.map((e) => e.toString()).cast<String>().toList();
      }
    } catch (e) {
      dev.log('my_accounts RPC failed, fallback to legacy resolver: $e');
      final one = await _resolveAccountIdForUid(user.id);
      if (one != null) accountIds = [one];
    }

    if (accountIds.isEmpty) return [];

    if (accountIds.length == 1) {
      final rows = await _client
          .from(Clinic.table)
          .select('id, name, frozen, created_at')
          .eq('id', accountIds.first)
          .order('created_at', ascending: false);
      return (rows as List)
          .map<Clinic>((r) => Clinic.fromJson(Map<String, dynamic>.from(r)))
          .toList();
    }

    final rows = await _client
        .from(Clinic.table)
        .select('id, name, frozen, created_at')
        .inFilter('id', accountIds)
        .order('created_at', ascending: false);

    return (rows as List)
        .map<Clinic>((r) => Clinic.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  // ─────────────────── إدارة العيادات / تجميد وحذف ───────────────────

  /// تجميد/إلغاء تجميد: Function → RPC → تحديث مباشر (accounts ثم clinics).
  Future<void> freezeClinic(String clinicId, bool freeze) async {
    try {
      final data = await _invokeTryMany(
        names: const ['admin__freeze_clinic', 'admin_freeze_clinic'],
        body: {
          'account_id': clinicId,
          'frozen': freeze,
          // أسماء بديلة
          'clinicId': clinicId,
          'isFrozen': freeze,
        },
      );
      if (data['ok'] == true) {
        return;
      }
      dev.log('admin__freeze_clinic returned non-ok, will fallback: $data');
    } catch (e) {
      dev.log('admin__freeze_clinic failed, trying RPC...', error: e);
    }

    try {
      await _client.rpc('admin_set_clinic_frozen', params: {
        'p_account_id': clinicId,
        'p_frozen': freeze,
      });
      return;
    } catch (e) {
      dev.log('admin_set_clinic_frozen RPC failed, falling back: $e');
    }

    // تحديث مباشر مرن
    try {
      await _client.from('accounts').update({'frozen': freeze}).eq('id', clinicId);
      return;
    } catch (_) {}
    await _client.from(Clinic.table).update({'frozen': freeze}).eq('id', clinicId);
    return;
  }

  /// حذف عيادة: Function → RPC → حذف مباشر (accounts ثم clinics).
  Future<void> deleteClinic(String clinicId) async {
    try {
      final data = await _invokeTryMany(
        names: const ['admin__delete_clinic', 'admin_delete_clinic'],
        body: {
          'account_id': clinicId,
          'clinicId': clinicId,
        },
      );
      if (data['ok'] == true) {
        return;
      }
      dev.log('admin__delete_clinic returned non-ok, will fallback: $data');
    } catch (e) {
      dev.log('admin__delete_clinic failed, trying RPC...', error: e);
    }

    try {
      await _client.rpc('admin_delete_clinic', params: {
        'p_account_id': clinicId,
      });
      return;
    } catch (e) {
      dev.log('admin_delete_clinic RPC failed, falling back: $e');
    }

    // حذف مباشر مرن
    try {
      await _client.from('accounts').delete().eq('id', clinicId);
      return;
    } catch (_) {}
    await _client.from(Clinic.table).delete().eq('id', clinicId);
    return;
  }

  // ─────────────────── إدارة الموظفين ───────────────────

  Future<void> setEmployeeDisabled({
    required String accountId,
    required String userUid,
    required bool disabled,
  }) async {
    try {
      await _client.rpc('set_employee_disabled', params: {
        'p_account': accountId,
        'p_user_uid': userUid,
        'p_disabled': disabled,
      });
      return;
    } catch (e) {
      dev.log('set_employee_disabled RPC failed: $e');
      rethrow;
    }
  }

  Future<void> deleteEmployee({
    required String accountId,
    required String userUid,
  }) async {
    try {
      await _client.rpc('delete_employee', params: {
        'p_account': accountId,
        'p_user_uid': userUid,
      });
      return;
    } catch (e) {
      dev.log('delete_employee RPC failed: $e');
      rethrow;
    }
  }

  // ─────────────────── أدوات مساعدة للهوية ───────────────────

  Future<Map<String, dynamic>?> fetchCurrentUser() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;

    try {
      final res = await _client.rpc('my_profile');
      Map<String, dynamic>? row;
      if (res is Map) {
        row = Map<String, dynamic>.from(res as Map);
      } else if (res is List && res.isNotEmpty) {
        row = Map<String, dynamic>.from(res.first as Map);
      }

      if (row != null) {
        final email = (row['email'] as String?) ?? user.email;
        final role = (row['role'] as String?) ??
            ((email ?? '').toLowerCase() == superAdminEmail.toLowerCase()
                ? 'superadmin'
                : null);
        return {
          'uid': user.id,
          'email': email,
          'accountId': row['account_id'] as String?,
          'role': role,
          'isSuperAdmin': role == 'superadmin' ||
              (email ?? '').toLowerCase() == superAdminEmail.toLowerCase(),
        };
      }
    } catch (e) {
      dev.log('fetchCurrentUser: my_profile RPC failed: $e');
    }

    String? accountId;
    String? role;

    try {
      final prof =
      await _client.from('profiles').select('account_id, role').eq('id', user.id).maybeSingle();
      accountId = (prof?['account_id'] as String?) ?? accountId;
      role = (prof?['role'] as String?) ?? role;
    } catch (e) {
      dev.log('fetchCurrentUser: profiles read failed: $e');
    }

    if (accountId == null || role == null) {
      try {
        final au = await _client
            .from('account_users')
            .select('account_id, role')
            .eq('user_uid', user.id)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();

        accountId ??= au?['account_id'] as String?;
        role ??= au?['role'] as String?;
      } catch (e) {
        dev.log('fetchCurrentUser: account_users read failed: $e');
      }
    }

    role ??= _client.auth.currentUser?.appMetadata['role'] as String?;
    final emailLower = (user.email ?? '').toLowerCase();
    final isSuper =
        emailLower == superAdminEmail.toLowerCase() || (role?.toLowerCase() == 'superadmin');

    return {
      'uid': user.id,
      'email': user.email,
      'accountId': accountId,
      'role': role,
      'isSuperAdmin': isSuper,
    };
  }

  Future<Map<String, dynamic>?> getMyProfileViaRpc() async {
    try {
      final res = await _client.rpc('my_profile');
      if (res is Map) return Map<String, dynamic>.from(res as Map);
      if (res is List && res.isNotEmpty) {
        return Map<String, dynamic>.from(res.first as Map);
      }
    } catch (e) {
      dev.log('my_profile RPC failed: $e');
    }
    return null;
  }

  // ─────────────────── صلاحيات الميزات + CRUD ───────────────────

  Future<FeaturePermissions> fetchMyFeaturePermissions({
    required String accountId,
  }) async {
    if (isSuperAdmin) {
      // سوبر أدمن: كل شيء مسموح
      return FeaturePermissions.defaultsAllAllowed();
    }
    try {
      final res = await _client.rpc('my_feature_permissions', params: {
        'p_account': accountId,
      });
      return FeaturePermissions.fromRpcPayload(res);
    } catch (e, st) {
      dev.log('fetchMyFeaturePermissions failed', error: e, stackTrace: st);
      return FeaturePermissions.defaultsAllAllowed();
    }
  }

  Future<FeaturePermissions> fetchFeaturePermissionsForUser({
    required String accountId,
    required String userUid,
  }) async {
    try {
      final row = await _client
          .from('account_feature_permissions')
          .select('allowed_features, can_create, can_update, can_delete')
          .eq('account_id', accountId)
          .eq('user_uid', userUid)
          .maybeSingle();

      if (row == null) return FeaturePermissions.defaultsAllAllowed();

      final list =
          (row['allowed_features'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
      return FeaturePermissions(
        allowedFeatures: Set<String>.from(list),
        canCreate: (row['can_create'] as bool?) ?? true,
        canUpdate: (row['can_update'] as bool?) ?? true,
        canDelete: (row['can_delete'] as bool?) ?? true,
      );
    } catch (e, st) {
      dev.log('fetchFeaturePermissionsForUser failed', error: e, stackTrace: st);
      return FeaturePermissions.defaultsAllAllowed();
    }
  }

  Future<void> upsertFeaturePermissions({
    required String accountId,
    required String userUid,
    required Set<String> allowedFeatures,
    required bool canCreate,
    required bool canUpdate,
    required bool canDelete,
  }) async {
    try {
      await _client.from('account_feature_permissions').upsert({
        'account_id': accountId,
        'user_uid': userUid,
        'allowed_features': allowedFeatures.toList(),
        'can_create': canCreate,
        'can_update': canUpdate,
        'can_delete': canDelete,
      }, onConflict: 'account_id,user_uid').select().maybeSingle();
      return;
    } catch (e, st) {
      dev.log('upsertFeaturePermissions failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  Future<void> deleteFeaturePermissions({
    required String accountId,
    required String userUid,
  }) async {
    try {
      await _client
          .from('account_feature_permissions')
          .delete()
          .eq('account_id', accountId)
          .eq('user_uid', userUid);
      return;
    } catch (e, st) {
      dev.log('deleteFeaturePermissions failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  // ─────────────────── السجلات (Audit Logs) ───────────────────

  Future<({List<AuditLogEntry> items, int? totalCount})> fetchAuditLogs({
    required String accountId,
    DateTime? createdAtFrom,
    DateTime? createdAtTo,
    String? op,
    String? tableName,
    String? actorUid,
    String? actorEmailLike,
    int limit = 30,
    int offset = 0,
    bool withCount = false,
  }) async {
    dynamic q =
    _client.from('audit_logs').select('*').order('created_at', ascending: false);

    q = q.eq('account_id', accountId);

    if (op != null && op.isNotEmpty) {
      q = q.eq('op', op);
    }
    if (tableName != null && tableName.isNotEmpty) {
      q = q.eq('table_name', tableName);
    }
    if (actorUid != null && actorUid.isNotEmpty) {
      q = q.eq('actor_uid', actorUid);
    }
    if (actorEmailLike != null && actorEmailLike.isNotEmpty) {
      q = q.ilike('actor_email', '%$actorEmailLike%');
    }
    if (createdAtFrom != null) {
      q = q.gte('created_at', createdAtFrom.toIso8601String());
    }
    if (createdAtTo != null) {
      q = q.lte('created_at', createdAtTo.toIso8601String());
    }

    final end = offset + limit - 1;
    final rows = await q.range(offset, end);

    final items = (rows as List)
        .map((m) => AuditLogEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList();

    // مبدئيًا بدون total count (يمكن إضافته لاحقًا عبر count(*) إن لزم)
    return (items: items, totalCount: null);
  }

  Future<List<String>> fetchAuditTables({
    required String accountId,
  }) async {
    try {
      final rows = await _client
          .from('audit_logs')
          .select('table_name')
          .eq('account_id', accountId)
          .order('table_name', ascending: true);
      final set = <String>{};
      for (final r in rows as List) {
        final name = (r['table_name'] as String?)?.trim();
        if (name != null && name.isNotEmpty) set.add(name);
      }
      final list = set.toList()..sort((a, b) => a.compareTo(b));
      return list;
    } catch (e, st) {
      dev.log('fetchAuditTables failed', error: e, stackTrace: st);
      return const <String>[];
    }
  }

  Future<List<Map<String, String>>> fetchAuditActors({
    required String accountId,
  }) async {
    try {
      final rows =
      await _client.from('audit_logs').select('actor_uid, actor_email').eq('account_id', accountId);

      final Map<String, String> m = {};
      for (final r in rows as List) {
        final uid = (r['actor_uid'] as String?)?.trim();
        final email = (r['actor_email'] as String?)?.trim() ?? '';
        if (uid == null || uid.isEmpty) continue;

        if (email.isNotEmpty) {
          m[uid] = email;
        } else {
          m[uid] = m[uid] ?? '';
        }
      }
      return m.entries.map((e) => {'uid': e.key, 'email': e.value}).toList();
    } catch (e, st) {
      dev.log('fetchAuditActors failed', error: e, stackTrace: st);
      return const <Map<String, String>>[];
    }
  }

  // ─────────────────── تنظيف ───────────────────

  Future<void> dispose() async {
    detachAuthStateListener();
    await _disposeSync();
    await _stopRealtimeAccountGuards();
    await _cleanupGlobalRealtime();
  }
}