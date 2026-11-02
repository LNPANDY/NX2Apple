# Cloud saves

A Mac game and its iPhone copy keep one save through a folder in iCloud Drive (DM_SAVE_SYNC). Issue #490 is the worked example: an env.txt from 1.0.0 kept the Mac on an old folder while the iPhone used another, and nothing said so.

- cloud-saves-01: On this Mac, every cloud saves folder a game uses (from env.txt or its saved choice) exists and holds <title ID>/save.dmsync.
- cloud-saves-02: The Mac launcher shows the cloud saves folder of a game and when it last synced. (gap: #499)
- cloud-saves-03: On this Mac, no other iCloud Drive folder holds a newer save.dmsync of a game than the folder that game syncs through.
- cloud-saves-04: Given the env.txt of #490 (DM_SAVE_SYNC set to a folder, DM_SAVE in iCloud Drive), when a game starts, then the launcher leaves the file byte for byte as it was.
- cloud-saves-05: Given an older env.txt with DM_SAVE_SYNC=icloud and an NX2Apple Saves folder in iCloud Drive, when a game starts, then the line names that folder and the other lines stay.
- cloud-saves-06: On the iPhone, an env.txt line never moves the save and never overrides a choice made in the shell.
- cloud-saves-07: Given a cloud folder that the iPhone can no longer open, the shell asks for a new folder.
- cloud-saves-08: On this Mac, iCloud Drive is on.
- cloud-saves-09: Given the same folder on both, a save made on the iPhone reaches the Mac, and the Mac log's save sync line names that folder. (manual)
