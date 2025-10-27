// lib/utils/excel_export_helper.dart

import 'dart:io';
import 'package:excel/excel.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/models/purchase.dart';

/// ‎ExcelExportHelper‎:
/// • يُولّد ملفات ‎.xlsx‎ بتنسيقٍ يُناسب "إحصاءات وكشوفات المستودع".
/// • يحفظ الملفات في مجلّد "Downloads" إن وُجد.
///
class ExcelExportHelper {
  ExcelExportHelper._();

  /// مسار مجلّد التنزيلات حسب المنصة
  static Future<String> _defaultDir() async {
    if (Platform.isAndroid) {
      // حاول مجلّد التنزيلات القياسي أولاً
      const androidDL = '/storage/emulated/0/Download';
      if (Directory(androidDL).existsSync()) return androidDL;
      // وإلا استخدم External Storage الخاص بالتطبيق
      final dir = await getExternalStorageDirectory();
      return dir?.path ?? androidDL;
    } else if (Platform.isIOS) {
      // لا يوجد Downloads قياسي في iOS، نستخدم Documents
      final dir = await getApplicationDocumentsDirectory();
      return dir.path;
    } else {
      // Windows / macOS / Linux
      final dir = await getDownloadsDirectory();
      return dir?.path ?? Directory.current.path;
    }
  }

  /// ⬇️ exportItemStatistics
  static Future<String> exportItemStatistics({
    required ItemType type,
    required List<Item> items,
    String? exportsDir,
  }) async {
    final excel = Excel.createExcel();
    final sheet = excel['Statistics'];

    // رأس الجدول
    sheet.appendRow([
      'نوع الصنف',
      'اسم الصنف',
      'عدد المستخدم',
      'المتبقي في المخزون',
      'السعر للوحدة',
    ]);

    // تعبئة البيانات
    for (final item in items) {
      // تجمع الاستخدام من جدول consumption مثلاً، لكن هنا نستخدم stock سالب كـ used
      final used = item.stock < 0 ? -item.stock : 0;
      final remaining = item.stock < 0 ? 0 : item.stock;
      sheet.appendRow([
        type.name,
        item.name,
        used,
        remaining,
        item.price,
      ]);
    }

    // حفظ في Downloads
    final dir = exportsDir ?? await _defaultDir();
    final fileName =
        '${type.name}_statistics_${DateTime.now().millisecondsSinceEpoch}.xlsx';
    final path = p.join(dir, fileName);

    final bytes = excel.encode();
    if (bytes == null) throw Exception('فشل في إنشاء ملف Excel.');
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// ⬇️ exportItemConsumptions
  static Future<String> exportItemConsumptions({
    required Item item,
    required List<Consumption> consumptions,
    String? exportsDir,
  }) async {
    final excel = Excel.createExcel();
    final sheet = excel['Consumptions'];

    sheet.appendRow([
      'اسم الصنف',
      'تاريخ ووقت الاستهلاك',
      'المريض (patientId)',
      'الكمية المستهلكة',
    ]);

    consumptions.sort((a, b) => a.consumedAt.compareTo(b.consumedAt));
    for (final c in consumptions) {
      sheet.appendRow([
        item.name,
        c.consumedAt.toString(),
        c.patientId,
        c.quantity,
      ]);
    }

    final dir = exportsDir ?? await _defaultDir();
    final fileName =
        '${item.name}_consumptions_${DateTime.now().millisecondsSinceEpoch}.xlsx';
    final path = p.join(dir, fileName);

    final bytes = excel.encode();
    if (bytes == null) throw Exception('فشل في إنشاء ملف Excel.');
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// ⬇️ exportPurchases
  static Future<String> exportPurchases({
    required List<Purchase> purchases,
    required Map<int, Item> lookupItems,
    String? exportsDir,
  }) async {
    final excel = Excel.createExcel();
    final sheet = excel['Purchases'];

    sheet.appendRow([
      'اسم الصنف',
      'الكمية',
      'سعر الوحدة',
      'الإجمالي',
      'التاريخ/الوقت',
    ]);

    purchases.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final pch in purchases) {
      final item = lookupItems[pch.itemId];
      sheet.appendRow([
        item?.name ?? 'ID ${pch.itemId}',
        pch.quantity,
        pch.unitPrice,
        pch.totalPrice,
        pch.createdAt.toString(),
      ]);
    }

    final dir = exportsDir ?? await _defaultDir();
    final fileName = 'purchases_${DateTime.now().millisecondsSinceEpoch}.xlsx';
    final path = p.join(dir, fileName);

    final bytes = excel.encode();
    if (bytes == null) throw Exception('فشل في إنشاء ملف Excel.');
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }
}
