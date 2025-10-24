import 'dart:io';

void main() async {
  final pubCachePath =
      Platform.environment['LOCALAPPDATA']! + r'\Pub\Cache\hosted\pub.dev';
  final dir = Directory(pubCachePath);

  if (!await dir.exists()) {
    print('❌ Directory not found: $pubCachePath');
    return;
  }

  final gradleFiles = await dir
      .list(recursive: true)
      .where((f) => f is File && f.path.endsWith('build.gradle'))
      .cast<File>()
      .toList();

  print('📁 Found ${gradleFiles.length} build.gradle files.');

  for (var file in gradleFiles) {
    final original = await file.readAsString();

    final updated = original
        .replaceAll('JavaVersion.VERSION_1_8', 'JavaVersion.VERSION_17')
        .replaceAll('JavaVersion.VERSION_11', 'JavaVersion.VERSION_17')
        .replaceAll("jvmTarget = '1.8'", "jvmTarget = '17'")
        .replaceAll('jvmTarget = "1.8"', 'jvmTarget = "17"')
        .replaceAll("jvmTarget = '11'", "jvmTarget = '17'")
        .replaceAll('jvmTarget = "11"', 'jvmTarget = "17"');

    if (updated != original) {
      final backup = File('${file.path}.bak');
      await backup.writeAsString(original);
      await file.writeAsString(updated);
      print('✅ Updated: ${file.path}');
    }
  }

  print('🎯 All done! Java 8 & 11 upgraded to Java 17 with backup .bak files.');
}
