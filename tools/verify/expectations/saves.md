# Saves and the Saves sheet

The Saves sheet copies a game's save between the Mac and a paired iPhone or iPad (#66).

- saves-01: Given a game in a library folder, the Saves sheet reads save/<title ID> beside the app.
- saves-02: When a device save is copied to the Mac, the Mac save goes into a backup folder first.
- saves-03: A save copied to the device never deletes the game data beside it.
- saves-04: Given a device that does not answer, the Saves sheet reports a timeout, never an empty save.
- saves-05: Given a Mac game whose env.txt sets DM_SAVE, when the player copies a save from the iPhone, then the copy lands in that DM_SAVE folder. (gap: #490)
- saves-06: On this Mac, no game's env.txt sets DM_SAVE, so the Saves sheet copies to the folder the game reads.
- saves-07: A save copied from the iPhone with the Saves sheet is the progress the Mac game shows. (manual)
