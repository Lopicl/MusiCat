# MusiCat (placeholder)

A music player for FileCat's library, built with `FileCatKit`. Bundle ID `com.lopicl.MusiCat`,
URL scheme `musicat://` (FileCat's *Settings › Companion Apps* opens it).

What's there so far:
- **Settings**: connect FileCat's Local Storage (folder picker, remembered with a bookmark), add
  other folders, and see the folders added in FileCat (from its library manifest). iOS gives each
  app its own access, so FileCat's folders have to be picked once in MusiCat too.
- **FileCat's servers** (SMB, NFS, WebDAV, Nextcloud): *Import Servers from FileCat* opens
  FileCat, which asks before handing over the servers and their passwords (kept in MusiCat's own
  keychain). With FileCat's library connected, MusiCat then follows FileCat's list: renamed or
  edited servers update, removed ones disappear, and after a password change *Update from FileCat*
  fetches the new one. NFS servers come over without asking, having no password. Browse a server,
  play songs straight from a folder, or *Use for Music* to put a folder's songs (and its
  subfolders') in the library. Tags are read over the network, only the parts of each file that
  hold them, and cached. Songs download before they play, since hi-res playback needs the whole
  file; the next song in the queue downloads meanwhile, and up to 3 GB stay cached.
  The protocol code is FileCat's own (`FileCat/FileCat/Network` in the FileCat repository, the
  "FileCat Network" group).
- **Songs, Artists, Albums**: tags are read with AVFoundation. Artist tags are split into every
  credited artist ("A feat. B", "A & B", "A, B"), so a song shows under each of them.
- **Playlists**: create, rename, reorder, delete; saved as JSON in Application Support.
- **Hi-res playback**: WAV, FLAC and ALAC (and MP3/AAC) through AVAudioEngine. Before each song
  the audio session asks the output for the file's own sample rate, so a USB DAC runs at 44.1 to
  192 kHz without resampling; *Settings › Hi-Res Audio* shows the file's format and whether the
  output matches it. At the end of Settings is the same long cat as in FileCat, which meows
  when you pull hard past the end.

## Building

MusiCat builds against code in the [FileCat repository](https://github.com/Lopicl/FileCat)
(`Packages/FileCatKit` and `FileCat/FileCat/Network`), so clone it inside a FileCat checkout:

```
git clone https://github.com/Lopicl/FileCat.git
git clone https://github.com/Lopicl/MusiCat.git FileCat/MusiCat
```

Then open `FileCat/MusiCat/MusiCat.xcodeproj`. The icon is drawn by `Tools/make-musicat-icon.swift`
in the FileCat repository.
