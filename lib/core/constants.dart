// lib/core/constants.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

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

  static String? _overrideSupabaseUrl;
  static String? _overrideSupabaseAnonKey;
  static bool _overridesLoaded = false;

  static String get supabaseUrl {
    final override = _overrideSupabaseUrl?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return _requireEnv(_envSupabaseUrl, 'SUPABASE_URL');
  }

  static String get supabaseAnonKey {
    final override = _overrideSupabaseAnonKey?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return _requireEnv(_envSupabaseAnonKey, 'SUPABASE_ANON_KEY');
  }

  /// Loads runtime overrides for Supabase configuration from the platform
  /// data directory (e.g. `C:\aelmam_clinic\config.json` on Windows).
  ///
  /// The JSON file supports the keys `supabaseUrl` and `supabaseAnonKey`.
  /// Values in this file take precedence over the compile-time defaults but
  /// are still superseded by `--dart-define` values when provided.
  static Future<void> loadRuntimeOverrides() async {
    if (_overridesLoaded || kIsWeb) {
      _overridesLoaded = true;
      return;
    }
    _overridesLoaded = true;

    final candidatePaths = <String>{};

    String? _normalize(String? path) {
      final trimmed = path?.trim();
      if (trimmed == null || trimmed.isEmpty) return null;
      return trimmed;
    }

    void addFile(String? path) {
      final normalized = _normalize(path);
      if (normalized != null) {
        candidatePaths.add(normalized);
      }
    }

    void addDirConfig(String? dir, {bool expandHome = false}) {
      final base = dir == null ? null : (expandHome ? _expandHome(dir) : dir);
      addFile(base == null ? null : p.join(base, 'config.json'));
    }

    Map<String, String>? env;
    try {
      env = Platform.environment;
    } catch (_) {
      env = null;
    }

    if (env != null) {
      addFile(env['AELMAM_SUPABASE_CONFIG'] ?? env['AELMAM_CONFIG']);
      addFile(env['AELMAM_CLINIC_CONFIG'] ?? env['SUPABASE_CONFIG_PATH']);
      final envDir = env['AELMAM_DIR'] ?? env['AELMAM_CLINIC_DIR'];
      if (envDir != null) {
        addDirConfig(envDir, expandHome: true);
      }
    }

    try {
      if (Platform.isWindows) {
        addDirConfig(windowsDataDir);
        addDirConfig(legacyWindowsDataDir);
        if (env != null) {
          addDirConfig(env['APPDATA'] == null
              ? null
              : p.join(env['APPDATA']!, 'aelmam_clinic'));
          addDirConfig(env['LOCALAPPDATA'] == null
              ? null
              : p.join(env['LOCALAPPDATA']!, 'aelmam_clinic'));
        }
      } else if (Platform.isLinux) {
        addDirConfig(linuxDataDir, expandHome: true);
        addDirConfig('~/.config/aelmam_clinic', expandHome: true);
        if (env != null) {
          final xdg = env['XDG_CONFIG_HOME'];
          if (xdg != null && xdg.trim().isNotEmpty) {
            addDirConfig(
              p.join(_expandHome(xdg), 'aelmam_clinic'),
            );
          }
        }
      } else if (Platform.isMacOS) {
        addDirConfig(macOsDataDir, expandHome: true);
      } else if (Platform.isAndroid) {
        addDirConfig(androidDataDir);
      } else if (Platform.isIOS) {
        addDirConfig(iosLogicalDataDir);
      }
    } catch (_) {
      // ignore platform detection failures
    }

    try {
      addDirConfig(Directory.current.path);
    } catch (_) {
      // ignore inability to resolve current directory (e.g. in tests)
    }

    for (final path in candidatePaths) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final raw = await file.readAsString();
        if (raw.trim().isEmpty) continue;

        final data = jsonDecode(raw);
        if (data is! Map) {
          continue;
        }

        String? readKey(String key) {
          final value = data[key] ?? data[_lowerSnake(key)];
          if (value == null) return null;
          if (value is String) {
            return value.trim();
          }
          return '$value'.trim();
        }

        final url = readKey('supabaseUrl');
        final anonKey = readKey('supabaseAnonKey');

        if ((url == null || url.isEmpty) &&
            (anonKey == null || anonKey.isEmpty)) {
          continue;
        }

        if (url != null && url.isNotEmpty) {
          _overrideSupabaseUrl = url;
        }
        if (anonKey != null && anonKey.isNotEmpty) {
          _overrideSupabaseAnonKey = anonKey;
        }

        debugLog(
          'Loaded Supabase config overrides from ${file.path}',
          tag: 'CONFIG',
        );
        break;
      } catch (e) {
        debugLog('Failed to read config override at $path: $e', tag: 'CONFIG');
      }
    }
  }

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

  static String _expandHome(String value) {
    if (!value.startsWith('~')) return value;
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      return value.replaceFirst('~', '');
    }
    return value.replaceFirst('~', home);
  }

  static String _lowerSnake(String camel) {
    final buffer = StringBuffer();
    for (var i = 0; i < camel.length; i++) {
      final char = camel[i];
      if (char.toUpperCase() == char && char.toLowerCase() != char && i > 0) {
        buffer.write('_');
      }
      buffer.write(char.toLowerCase());
    }
    return buffer.toString();
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
