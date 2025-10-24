// lib/services/sync_orchestrator.dart
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'db_service.dart';
import 'device_id_service.dart';
import 'sync_service.dart';
import 'auth_supabase_service.dart';

/// منسّق علوي لتشغيل المزامنة (Pull/Realtime) وربط أحداث التغيّر المحلية
/// مع دفع سحابي مؤجَّل (debounced) لكل جدول.
class SyncOrchestrator {
  SyncOrchestrator._();
  static final SyncOrchestrator instance = SyncOrchestrator._();

  SyncService? _sync;
  StreamSubscription<String>? _localStreamSub;

  /// مؤقّتات الـ debounce حسب اسم الجدول
  final Map<String, Timer> _pushTimers = {};
  Duration _debounce = const Duration(seconds: 1);

  /// جدولة دفع جدول بعد مهلة Debounce.
  void _scheduleDebouncedPush(String table) {
    // ألغِ أي مؤقّت سابق لنفس الجدول
    _pushTimers[table]?.cancel();
    _pushTimers[table] = Timer(_debounce, () {
      final s = _sync;
      if (s != null) {
        // دفع الجدول المستهدف فقط
        s.pushFor(table);
      }
    });
  }

  /// بدء المزامنة للمستخدم الحالي (يتطلب تسجيل دخول صحيح + صلاحية على الحساب).
  ///
  /// [initialPull] سحب أولي كامل من السحابة.
  /// [realtime] تفعيل Realtime.
  /// [enableLogs] طباعة لوغز تخص المزامنة.
  /// [debounce] مهلة التأجيل لدفع الجداول المتغيرة.
  Future<void> startForCurrentUser({
    bool initialPull = true,
    bool realtime = true,
    bool enableLogs = false,
    Duration debounce = const Duration(seconds: 1),
  }) async {
    // تأكد من وجود حساب فعّال للمستخدم الحالي
    final auth = AuthSupabaseService();
    final active = await auth.resolveActiveAccountOrThrow();

    final devId = await DeviceIdService.getId();
    final db = await DBService.instance.database;

    // إن كان هناك Sync قديم، أوقف الـ Realtime القديم قبل إعادة التهيئة
    try {
      await _sync?.dispose();
    } catch (_) {}

    _sync = SyncService(
      db,
      active.id,
      deviceId: devId,
      enableLogs: enableLogs,
    );

    // خزّن قيمة الـ debounce
    _debounce = debounce;

    // اربط حدث تغيّر محلي → دفع مؤجّل لنفس الجدول
    DBService.instance.onLocalChange = (tbl) async {
      _scheduleDebouncedPush(tbl);
    };

    // (اختياري) استمع لبثّ التغييرات العامة (للغرض التشخيصي)
    await _localStreamSub?.cancel();
    _localStreamSub = DBService.instance.changes.listen((tbl) {
      if (enableLogs) {
        // ignore: avoid_print
        print('[SYNC-ORCH] local change in $tbl');
      }
    });

    // تشغيل Bootstrap (سحب أولي + Realtime)
    await _sync!.bootstrap(pull: initialPull, realtime: realtime);
  }

  /// إعادة ربط المزامنة عند تغيّر الحساب/الجهاز.
  Future<void> rebindIfNeeded({
    required String newAccountId,
    String? newDeviceId,
  }) async {
    if (_sync == null) return;
    await _sync!.rebind(
      newAccountId: newAccountId,
      newDeviceId: newDeviceId,
      initialPull: true,
      restartRealtime: true,
    );
  }

  /// إيقاف كل شيء وتنظيف الموارد.
  Future<void> stop() async {
    // افصل onLocalChange حتى لا تُطلق دفعات أثناء الإيقاف
    DBService.instance.onLocalChange = null;

    // ألغِ بثّ التغييرات
    await _localStreamSub?.cancel();
    _localStreamSub = null;

    // ألغِ المؤقّتات المؤجّلة
    for (final t in _pushTimers.values) {
      t.cancel();
    }
    _pushTimers.clear();

    // أوقف Realtime وازِل المرجع
    try {
      await _sync?.stopRealtime();
    } catch (_) {}
    _sync = null;
  }

  SyncService? get sync => _sync;
}

/// امتداد مريح على AuthSupabaseService ليقدّم دالة
/// bootstrapSyncForCurrentUser(...) التي استُخدمت في login_screen.dart
extension AuthSupabaseSyncBootstrap on AuthSupabaseService {
  /// يفعّل المزامنة للمستخدم الحالي عبر SyncOrchestrator.
  ///
  /// [pull] سحب أولي كامل إن رغبت (true بعد تسجيل الدخول، false عند وجود جلسة سابقة).
  /// [realtime] تفعيل Realtime.
  /// [enableLogs] طباعة لوغز.
  /// [debounce] مهلة تأجيل الدفع لكل جدول عند تغيّره محليًا.
  Future<void> bootstrapSyncForCurrentUser({
    bool pull = true,
    bool realtime = true,
    bool enableLogs = false,
    Duration debounce = const Duration(seconds: 1),
  }) async {
    await SyncOrchestrator.instance.startForCurrentUser(
      initialPull: pull,
      realtime: realtime,
      enableLogs: enableLogs,
      debounce: debounce,
    );
  }
}
