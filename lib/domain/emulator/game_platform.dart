/// The console or family of consoles an emulator targets.
enum GamePlatform {
  playStationPortable('PlayStation Portable'),
  gameBoyAdvance('Game Boy Advance'),
  multiSystem('Multi-system');

  const GamePlatform(this.label);

  final String label;
}
