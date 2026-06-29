# Third-Party Notices

J-MKV-subMuxer can bundle command-line media tools into the macOS DMG so users do not need to install Homebrew, MKVToolNix, or FFmpeg separately.

The application source code in this repository is licensed under GPL-2.0-or-later. Bundled third-party tools remain under their own licenses.

## MKVToolNix / mkvmerge

- Project: MKVToolNix
- Website: https://mkvtoolnix.download/
- Tool used: `mkvmerge`
- Version bundled in v0.1.3 release: `mkvmerge v99.0 ('Buka')`
- License: GPL v2, according to MKVToolNix project licensing information.

## FFmpeg / ffprobe

- Project: FFmpeg
- Website: https://ffmpeg.org/
- Tools used: `ffmpeg`, `ffprobe`
- Version bundled in v0.1.3 release: `ffmpeg version 8.1.2`
- License: FFmpeg is distributed under LGPL or GPL depending on build configuration. The v0.1.3 macOS bundle uses a Homebrew build with `--enable-gpl` and `--enable-version3`, so the bundled FFmpeg binaries should be treated as GPL-versioned binaries.

## Dynamic Libraries

The DMG build script copies the dynamic libraries required by the Homebrew `mkvmerge`, `ffmpeg`, and `ffprobe` binaries into `J-MKV-subMuxer.app/Contents/Resources/Tools/lib`.

Run the following after building a DMG to inspect the bundled libraries:

```bash
find J-MKV-subMuxer.app/Contents/Resources/Tools/lib -maxdepth 1 -type f -print
```
