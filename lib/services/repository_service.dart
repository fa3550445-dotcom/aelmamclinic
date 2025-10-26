// lib/services/repository_service.dart

import 'package:sqflite/sqflite.dart';

import '../models/item_type.dart';
import '../models/item.dart';
import '../models/purchase.dart';
import '../models/consumption.dart'; // ← أضفنا هذا السطر
import '../models/alert_setting.dart';
import '../services/db_service.dart';
import '../utils/notifications_helper.dart';

/// طبقة الأعمال للمستودع.
/// تعتمد على DBService للوصول إلى SQLite، وعلى NotificationsHelper
/// لإرسال تنبيهات النظام عند انخفاض المخزون.
class RepositoryService {
  RepositoryService._();
  static final RepositoryService instance = RepositoryService._();

  /*────────── موارد داخليّة ──────────*/
  final DBService _db = DBService.instance;
  final NotificationsHelper _notifier = NotificationsHelper.instance;

  /*──────── منفذ عام إلى قاعدة البيانات ────────*/
  Future<Database> get database async => _db.database;
  DBService get db => _db;

  /*────────── جلب البيانات ──────────*/
  Future<List<ItemType>> fetchItemTypes() async {
    final db = await _db.database;
    final maps = await db.query(ItemType.table, orderBy: 'name');
    return maps.map(ItemType.fromMap).toList();
  }

  Future<List<Item>> fetchItemsByType(int typeId) async {
    final db = await _db.database;
    final maps = await db.query(
      Item.table,
      where: 'type_id = ?',
      whereArgs: [typeId],
      orderBy: 'name',
    );
    return maps.map(Item.fromMap).toList();
  }

  Future<Item?> fetchItem(int id) async {
    final db = await _db.database;
    final maps = await db.query(
      Item.table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return maps.isEmpty ? null : Item.fromMap(maps.first);
  }

  /*──────── إنشاء / تحديث / حذف ────────*/
  Future<ItemType> createItemType(String name) async {
    final db = await _db.database;
    final id = await db.insert(ItemType.table, {'name': name});
    return ItemType(id: id, name: name);
  }

  Future<Item> createItem({
    required int typeId,
    required String name,
    required double price,
    required int initialStock,
  }) async {
    final db = await _db.database;
    final id = await db.insert(Item.table, {
      'type_id': typeId,
      'name': name,
      'price': price,
      'stock': initialStock,
      'created_at': DateTime.now().toIso8601String(),
    });
    return Item(
      id: id,
      typeId: typeId,
      name: name,
      price: price,
      stock: initialStock,
    );
  }

  Future<void> updateItem(Item item) async {
    final db = await _db.database;
    await db.update(
      Item.table,
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<void> deleteItem(int id) async {
    final db = await _db.database;
    await db.delete(Item.table, where: 'id = ?', whereArgs: [id]);
    await db.delete(
      AlertSetting.table,
      where: 'itemId = ?',
      whereArgs: [id],
    );
  }

  /*────────── مشتريات ──────────*/
  Future<void> createPurchase({
    required int itemId,
    required int quantity,
    required double unitPrice,
  }) async {
    final db = await _db.database;

    // إدخال الشراء
    await db.insert(Purchase.table, {
      'itemId': itemId,
      'quantity': quantity,
      'unit_price': unitPrice,
      'created_at': DateTime.now().toIso8601String(),
    });

    // تحديث المخزون
    await db.rawUpdate(
      'UPDATE ${Item.table} SET stock = stock + ? WHERE id = ?',
      [quantity, itemId],
    );

    // فحص وتنفيذ التنبيه بعد التحديث
    await _evaluateAlertForItem(itemId);
  }

  /*────────── استهلاك (مرتبط بمريض أو عام) ──────────*/
  Future<void> recordConsumption({
    required int itemId,
    required int quantity,
    String? patientId,
  }) async {
    final db = await _db.database;

    // هات سعر الصنف لحساب المبلغ
    final item = await fetchItem(itemId);
    final unitPrice = item?.price ?? 0.0;
    final amount = unitPrice * quantity;

    // سجل الاستهلاك (مربوط بمريض أو عام)
    await db.insert(Consumption.table, {
      'patientId': patientId, // ممكن يكون null
      'itemId': itemId.toString(), // متوافقًا مع بياناتك الحالية
      'quantity': quantity,
      'date': DateTime.now().toIso8601String(),
      'amount': amount, // ← المهم
      'note': null, // اتركها null لو ما عندك ملاحظة
    });

    // حدّث المخزون
    await db.rawUpdate(
      'UPDATE ${Item.table} SET stock = stock - ? WHERE id = ?',
      [quantity, itemId],
    );

    // فحص وتنبيه انخفاض المخزون
    await _evaluateAlertForItem(itemId);
  }

  /*────────── تنبيه انخفاض المخزون ──────────*/
  Future<void> setAlert({
    required int itemId,
    required double threshold,
  }) async {
    final db = await _db.database;

    final exists = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM ${AlertSetting.table} WHERE itemId = ?',
          [itemId],
        )) ??
        0;

    if (exists == 0) {
      await db.insert(AlertSetting.table, {
        'itemId': itemId,
        'threshold': threshold,
        'is_enabled': 1,
        'created_at': DateTime.now().toIso8601String(),
      });
    } else {
      await db.update(
        AlertSetting.table,
        {'threshold': threshold, 'is_enabled': 1},
        where: 'itemId = ?',
        whereArgs: [itemId],
      );
    }

    await _evaluateAlertForItem(itemId);
  }

  /*────────── فحص وتنفيذ التنبيه ──────────*/
  Future<void> _evaluateAlertForItem(int itemId) async {
    final db = await _db.database;
    final item = await fetchItem(itemId);
    if (item == null) return;

    final maps = await db.query(
      AlertSetting.table,
      where: 'itemId = ? AND is_enabled = 1',
      whereArgs: [itemId],
      limit: 1,
    );
    if (maps.isEmpty) return;
    final alert = AlertSetting.fromMap(maps.first);

    if (item.stock <= alert.threshold) {
      final today = DateTime.now();
      final last = alert.lastTriggered;

      final triggeredToday = last != null &&
          last.year == today.year &&
          last.month == today.month &&
          last.day == today.day;

      if (!triggeredToday) {
        // إرسال إشعار
        await _notifier.triggerLowStock(item);

        // تحديث last_triggered
        await db.update(
          AlertSetting.table,
          {'last_triggered': today.toIso8601String()},
          where: 'id = ?',
          whereArgs: [alert.id],
        );
      }
    }
  }

  /*────────── الأصناف منخفضة المخزون ──────────*/
  Future<List<Item>> fetchLowStockItems() async {
    final db = await _db.database;
    final rows = await db.rawQuery('''
      SELECT i.*
      FROM ${Item.table}         AS i
      JOIN ${AlertSetting.table} AS a ON a.itemId = i.id
      WHERE a.is_enabled = 1
        AND i.stock     <= a.threshold
      ORDER BY i.stock ASC
    ''');
    return rows.map(Item.fromMap).toList();
  }

  /*────────── تحقُّق سريع للشارة ──────────*/
  Future<bool> anyLowStockAlert() async {
    final db = await _db.database;
    final result = await db.rawQuery('''
      SELECT 1
      FROM ${AlertSetting.table} AS a
      JOIN ${Item.table}         AS i ON i.id = a.itemId
      WHERE a.is_enabled = 1
        AND i.stock     <= a.threshold
      LIMIT 1
    ''');
    return result.isNotEmpty;
  }
}
