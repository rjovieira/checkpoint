/// What a set of save files actually is.
///
/// The reference implementation this project learned from modelled these only
/// as "different folders", which meant the UI could not tell the user whether a
/// restore was about to overwrite hours of in-game progress or a scratch
/// savestate. Making the distinction a first-class value is deliberate.
enum SaveKind {
  /// Saves written by the game itself — memory cards, `.srm`, save data
  /// directories. Losing these loses real progress.
  saveData('Save data', 'In-game saves written by the game'),

  /// Emulator snapshots of machine state. Tied to a specific emulator build
  /// and often to a specific ROM revision, so they are far less portable.
  saveState('Save states', 'Emulator snapshots of the exact machine state');

  const SaveKind(this.label, this.description);

  final String label;
  final String description;
}
