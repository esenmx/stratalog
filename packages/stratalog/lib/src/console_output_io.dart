import 'dart:io';

/// Line-atomic release console sink: one record = one `stdout.writeln`, no
/// length cap — bypasses `print()`'s mobile chunking entirely.
void writeConsoleLine(String line) => stdout.writeln(line);
