// lib/core/constants.dart
import 'package:flutter/foundation.dart';

class AppConstants {
  AppConstants._();

  static const String appName = 'Elmam Clinic';

  // -------------------- Supabase --------------------
  static const String _envSupabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://wiypiofuyrayywciovoo.supabase.co',
  );
  static const String _envSupabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndpeXBpb2Z1eXJheXl3Y2lvdm9vIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTQ1NjczOTcsImV4cCI6MjA3MDE0MzM5N30.TwveOqJJfM3eDVwsxaL76YkyVAAzZxeMVxGzLT8EC3E',
  );

  static String get supabaseUrl =>
      _requireEnv(_envSupabaseUrl, 'SUPABASE_URL');

  static String get supabaseAnonKey =>
      _requireEnv(_envSupabaseAnonKey, 'SUPABASE_ANON_KEY');

  // -------------------- مخازن محلية --------------------
  static const String windowsDataDir = r'C:\aelmam_clinic';
  static const String legacyWindowsDataDir = r'D:\aelmam_clinic';
  static const String linuxDataDir = r'~/.aelmam_clinic';
  static const String macOsDataDir =
      r'~/Library/Application Support/aelmam_clinic';
  static const String androidDataDir =
      r'/sdcard/Android/data/com.aelmam.clinic/files';
  static const String iosLogicalDataDir = r'Documents';

  static const String attachmentsSubdir = 'attachments';

  // -------------------- مزامنة --------------------
  static const bool syncInitialPull = true;
  static const bool syncRealtime = true;
  static const Duration syncPushDebounce = Duration(seconds: 1);

  // -------------------- دردشة/تخزين --------------------
  static const String chatBucketName = 'chat-attachments';
  static const int storageSignedUrlTTLSeconds = 60 * 60; // 1 ساعة
  static const int chatPageSize = 30;

  static const String tableChatConversations = 'chat_conversations';
  static const String tableChatParticipants = 'chat_participants';
  static const String tableChatMessages = 'chat_messages';
  static const String tableChatReads = 'chat_reads';
  static const String tableChatAttachments = 'chat_attachments';
  static const String tableClinics = 'clinics';
  static const String tableAccountUsers = 'account_users';

  static const bool chatPreferPublicUrls = false;
  static const int? chatMaxAttachmentBytes = 20 * 1024 * 1024; // 20 MB إجمالي (null لإلغاء القيود)
  static const int? chatMaxSingleAttachmentBytes = 10 * 1024 * 1024; // 10 MB لكل ملف (null لإلغاء القيود)

  // -------------------- أقسام UI --------------------
  static const String secBackup = 'نسخ احتياطي وإستعادة البيانات';

  // -------------------- Debug --------------------
  static void debugLog(Object msg, {String tag = 'APP'}) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[$tag] $msg');
    }
  }

  static String _requireEnv(String value, String key) {
    if (value.isNotEmpty) return value;
    final msg =
        'Missing $key. Provide it via --dart-define or secure environment variables.';
    if (kDebugMode) {
      // ignore: avoid_print
      print('[APP] $msg');
    }
    throw StateError(msg);
  }
}
