// Web fallback for the release console sink — no `dart:io` there, and the
// browser console has no line-length cap, so print() is already line-atomic.
// ignore_for_file: avoid_print

/// Line-atomic release console sink (web): `print` maps to `console.log`,
/// which never splits a line.
void writeConsoleLine(String line) => print(line);
