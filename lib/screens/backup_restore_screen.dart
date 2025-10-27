// lib/screens/backup_restore_screen.dart
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/models/storage_type.dart';
import 'package:aelmamclinic/services/backup_restore_service.dart';

class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  bool _busy = false;

  String _lastBackupSize = '';
  DateTime? _lastBackupDate;
  String? _lastBackupPath;

  final TextEditingController _driveIdController = TextEditingController();

  @override
  void dispose() {
    _driveIdController.dispose();
    super.dispose();
  }

  /*────────────────── النسخ الاحتياطي ──────────────────*/
  Future<void> _backup({required StorageType storageType}) async {
    setState(() => _busy = true);
    try {
      // 1) إنشاء النسخة عبر الخدمة
      final file = await BackupRestoreService.backupDatabase(
        storageType: storageType,
      );

      // 2) عند المحلي على Android: انسخ إلى مجلد التحميلات
      File backupFile = file;
      if (storageType == StorageType.local && Platform.isAndroid) {
        try {
          final aelmamDir =
              Directory('/storage/emulated/0/Download/AelmamClinic');
          if (!await aelmamDir.exists()) {
            await aelmamDir.create(recursive: true);
          }
          final destPath = p.join(aelmamDir.path, p.basename(file.path));
          backupFile = await file.copy(destPath);
        } catch (_) {
          backupFile = file; // fallback
        }
      }

      // 3) تحديث بيانات آخر نسخة
      final info = await backupFile.stat();
      setState(() {
        _lastBackupDate = info.modified;
        _lastBackupSize = _formatFileSize(info.size);
        _lastBackupPath = backupFile.path;
      });

      // 4) حوار تفاصيل
      _showDetailedDialog(
        'تم إنشاء النسخة الاحتياطية بنجاح',
        '''
المسار: ${backupFile.path}
الحجم: $_lastBackupSize
التاريخ: ${DateFormat('yyyy/MM/dd HH:mm').format(_lastBackupDate!)}
المحتويات:
• قاعدة البيانات
• جميع المرفقات
''',
      );
    } catch (e) {
      _showSnack('فشل في النسخ الاحتياطي: ${e.toString()}', error: true);
    } finally {
      setState(() => _busy = false);
    }
  }

  /*────────────────── الاستعادة ──────────────────*/
  Future<void> _restore({required StorageType storageType}) async {
    String source;
    if (storageType == StorageType.local) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'db'],
        dialogTitle: 'اختر ملف النسخة الاحتياطية',
      );
      if (result == null || result.files.single.path == null) return;
      source = result.files.single.path!;
    } else {
      source = await _promptForDriveId();
      if (source.isEmpty) return;
    }

    // اختيار وضع الاستعادة
    final merge = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('اختر نوع الاستعادة'),
        content: const Text(
            'دمج البيانات الجديدة (يحافظ على القديمة) أو استبدال كامل؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('استبدال كامل')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('دمج البيانات')),
        ],
      ),
    );
    if (merge == null) return;

    // تأكيد نهائي
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(merge ? 'تأكيد دمج البيانات' : 'تأكيد الاستبدال الكامل'),
        content: Text(
          merge
              ? 'سيتم إضافة السجلات الجديدة دون مسح القديمة. أكيد؟'
              : 'سيتم مسح جميع البيانات واستيراد النسخة كاملة. أكيد؟',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style:
                ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      await BackupRestoreService.restoreDatabase(
        backupPath: source,
        storageType: storageType,
        merge: merge,
      );
      _showSnack('تمت الاستعادة بنجاح. يُرجى إعادة تشغيل التطبيق.');
    } catch (e) {
      _showSnack('فشل في الاستعادة: ${e.toString()}', error: true);
    } finally {
      setState(() => _busy = false);
    }
  }

  /*────────────────── أدوات مساعدة ──────────────────*/
  Future<String> _promptForDriveId() async {
    _driveIdController.clear();
    return await showDialog<String>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('استعادة من Google Drive'),
            content: TextField(
              controller: _driveIdController,
              decoration: const InputDecoration(
                labelText: 'معرّف الملف (33 حرفًا)',
                hintText: 'أدخل معرّف النسخة الاحتياطية',
              ),
              maxLength: 33,
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, ''),
                  child: const Text('إلغاء')),
              ElevatedButton(
                  onPressed: () =>
                      Navigator.pop(context, _driveIdController.text),
                  child: const Text('استعادة')),
            ],
          ),
        ) ??
        '';
  }

  void _showSnack(String msg, {bool error = false}) {
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? Colors.red.shade700 : scheme.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showDetailedDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(content)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('تم')),
        ],
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = (log(bytes) / log(1024)).floor();
    final value = bytes / pow(1024, i);
    final idx = i.clamp(0, suffixes.length - 1);
    return '${value.toStringAsFixed(value >= 100 ? 0 : value >= 10 ? 1 : 2)} ${suffixes[idx]}';
  }

  /*────────────────── واجهة المستخدم ──────────────────*/
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/logo.png',
                height: 24,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
              const SizedBox(width: 8),
              const Text('ELMAM CLINIC'),
            ],
          ),
          actions: [
            if (_lastBackupDate != null)
              IconButton(
                tooltip: 'تفاصيل آخر نسخة',
                icon: const Icon(Icons.history_rounded),
                onPressed: () => _showDetailedDialog(
                  'آخر نسخة احتياطية',
                  '''
التاريخ: ${DateFormat('yyyy/MM/dd HH:mm').format(_lastBackupDate!)}
الحجم: $_lastBackupSize
المسار: ${_lastBackupPath ?? 'غير متاح'}
''',
                ),
              ),
            if (_lastBackupPath != null)
              IconButton(
                tooltip: 'مشاركة آخر نسخة',
                icon: const Icon(Icons.share_rounded),
                onPressed: () async {
                  try {
                    await SharePlus.instance.shareXFiles(files: [XFile(_lastBackupPath!)],
                        text: 'نسخة ELMAM Clinic');
                  } catch (e) {
                    _showSnack('تعذّرت المشاركة: $e', error: true);
                  }
                },
              ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                children: [
                  const TSectionHeader('آخر نسخة احتياطية'),
                  NeuCard(
                    padding: const EdgeInsets.all(14),
                    child: _lastBackupDate == null
                        ? const Text('لم تُنشأ نسخة احتياطية بعد.',
                            style: TextStyle(fontWeight: FontWeight.w700))
                        : Wrap(
                            spacing: 16,
                            runSpacing: 16,
                            children: [
                              TInfoCard(
                                icon: Icons.calendar_month_rounded,
                                label: 'التاريخ',
                                value: DateFormat('yyyy/MM/dd HH:mm')
                                    .format(_lastBackupDate!),
                              ),
                              TInfoCard(
                                icon: Icons.sd_storage_rounded,
                                label: 'الحجم',
                                value: _lastBackupSize,
                              ),
                              if (_lastBackupPath != null)
                                TInfoCard(
                                  icon: Icons.folder_open_rounded,
                                  label: 'المسار',
                                  value: _lastBackupPath!,
                                  maxLines: 2,
                                ),
                              Row(
                                children: [
                                  Expanded(
                                    child: TOutlinedButton(
                                      icon: Icons.info_outline_rounded,
                                      label: 'تفاصيل',
                                      onPressed: () => _showDetailedDialog(
                                        'آخر نسخة احتياطية',
                                        '''
التاريخ: ${DateFormat('yyyy/MM/dd HH:mm').format(_lastBackupDate!)}
الحجم: $_lastBackupSize
المسار: ${_lastBackupPath ?? 'غير متاح'}
''',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  if (_lastBackupPath != null)
                                    NeuButton.flat(
                                      icon: Icons.share_rounded,
                                      label: 'مشاركة',
                                      onPressed: () async {
                                        try {
                                          await SharePlus.instance.shareXFiles(
                                              [XFile(_lastBackupPath!)],
                                              text: 'نسخة ELMAM Clinic');
                                        } catch (e) {
                                          _showSnack('تعذّرت المشاركة: $e',
                                              error: true);
                                        }
                                      },
                                    ),
                                ],
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 18),
                  const TSectionHeader('إنشاء نسخة احتياطية'),
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      NeuButton.primary(
                        icon: Icons.backup_rounded,
                        label: 'نسخة احتياطية (محلي)',
                        onPressed: _busy
                            ? null
                            : () => _backup(storageType: StorageType.local),
                      ),
                      NeuButton.flat(
                        icon: Icons.cloud_upload_rounded,
                        label: 'نسخة احتياطية (Google Drive)',
                        onPressed: _busy
                            ? null
                            : () =>
                                _backup(storageType: StorageType.googleDrive),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const TSectionHeader('استعادة نسخة'),
                  NeuCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TOutlinedButton(
                                icon: Icons.download_rounded,
                                label: 'استيراد (محلي)',
                                onPressed: _busy
                                    ? null
                                    : () => _restore(
                                        storageType: StorageType.local),
                              ),
                            ),
                            const SizedBox(width: 10),
                            NeuButton.flat(
                              icon: Icons.cloud_download_rounded,
                              label: 'استيراد (Google Drive)',
                              onPressed: _busy
                                  ? null
                                  : () => _restore(
                                      storageType: StorageType.googleDrive),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'ملاحظة: في وضع "استبدال كامل" سيتم حذف البيانات الحالية واستبدالها بالكامل.',
                          style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: .75)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // طبقة انشغال لطيفة
              if (_busy)
                Positioned.fill(
                  child: Container(
                    color: scheme.scrim.withValues(alpha: .06),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
