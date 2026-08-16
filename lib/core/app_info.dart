/// The version Checkpoint records in every backup manifest.
///
/// Must match `version:` in `pubspec.yaml`. It is duplicated here rather than
/// read at runtime because the alternative — a plugin that parses the app
/// bundle — is a dependency and a platform channel for one string.
const String checkpointVersion = '0.1.0';
