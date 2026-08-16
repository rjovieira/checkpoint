import 'package:checkpoint/domain/config/app_configuration.dart';

/// In-memory [ConfigurationRepository] for tests.
final class FakeConfigurationRepository implements ConfigurationRepository {
  FakeConfigurationRepository([this._configuration = AppConfiguration.empty]);

  AppConfiguration _configuration;

  AppConfiguration get current => _configuration;

  @override
  Future<AppConfiguration> load() async => _configuration;

  @override
  Future<void> save(AppConfiguration configuration) async {
    _configuration = configuration;
  }
}
