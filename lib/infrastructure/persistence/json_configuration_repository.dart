import 'dart:convert';
import 'dart:io';

import 'package:checkpoint/domain/config/app_configuration.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Stores [AppConfiguration] as a JSON document in app-private storage.
///
/// Why a file and not a database: the configuration is a handful of folder
/// grants and is always read and written whole. A relational store would add a
/// schema, migrations and a code generator to buy indexing and partial queries
/// that nothing here needs. The [ConfigurationRepository] interface is what
/// makes that reversible — the day a feature needs to *query* this data, the
/// implementation changes and nothing else does.
///
/// Writes go to a temporary file and are then renamed over the target, so an
/// interrupted write cannot leave a half-written configuration that would lose
/// the user's folder grants.
final class JsonConfigurationRepository implements ConfigurationRepository {
  JsonConfigurationRepository({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  static const String fileName = 'configuration.json';

  AppConfiguration? _cached;

  @override
  Future<AppConfiguration> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    try {
      final file = await _file();
      if (!file.existsSync()) {
        return _cached = AppConfiguration.empty;
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, Object?>) {
        return _cached = AppConfiguration.empty;
      }
      return _cached = AppConfiguration.fromJson(raw);
    } on FormatException {
      // A corrupt configuration must not stop the app from starting. The user
      // re-picks their folders, which is recoverable; a crash loop is not.
      return _cached = AppConfiguration.empty;
    } on FileSystemException {
      return _cached = AppConfiguration.empty;
    }
  }

  @override
  Future<void> save(AppConfiguration configuration) async {
    final file = await _file();
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(configuration.toJson()),
      flush: true,
    );
    await temporary.rename(file.path);
    _cached = configuration;
  }

  Future<File> _file() async {
    final directory = await _directory();
    await directory.create(recursive: true);
    return File(p.join(directory.path, fileName));
  }
}
