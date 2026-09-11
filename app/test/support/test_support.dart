import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:tingyu/data/db/database.dart';

/// 内存库：测试不碰用户数据，也不需要清理文件。
TingyuDatabase openTestDatabase() => TingyuDatabase(NativeDatabase.memory());

Uint8List asciiBytes(String value) => Uint8List.fromList(value.codeUnits);

/// 生成一段静音 WAV（默认 8kHz 单声道 16bit），用于扫描器测试。
/// 手写容器而不是依赖 ffmpeg，测试才能在任何机器上确定性地跑。
Uint8List buildSilentWav({int seconds = 1, int sampleRate = 8000}) {
  final int dataSize = sampleRate * seconds * 2;
  final BytesBuilder builder = BytesBuilder();

  void ascii(String value) => builder.add(asciiBytes(value));
  void u32(int value) => builder.add(<int>[value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF]);
  void u16(int value) => builder.add(<int>[value & 0xFF, (value >> 8) & 0xFF]);

  ascii('RIFF');
  u32(36 + dataSize);
  ascii('WAVE');
  ascii('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2); // byte rate
  u16(2); // block align
  u16(16); // bits per sample
  ascii('data');
  u32(dataSize);
  builder.add(Uint8List(dataSize));

  return builder.takeBytes();
}

/// 生成带 ID3v2.3 标签的最小 MP3，用于验证标签字段的映射。
Uint8List buildTaggedMp3({required String title, required String artist, required String album}) {
  final BytesBuilder frames = BytesBuilder();

  void frame(String id, String value) {
    // 编码字节 0x01 = UTF-16 + BOM；中文标签在真实文件里就是这么写的。
    final List<int> text = <int>[0x01, 0xFF, 0xFE];
    for (final int unit in value.codeUnits) {
      text.add(unit & 0xFF);
      text.add((unit >> 8) & 0xFF);
    }
    final int size = text.length;
    frames.add(asciiBytes(id));
    frames.add(<int>[(size >> 24) & 0xFF, (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF]);
    frames.add(<int>[0x00, 0x00]); // flags
    frames.add(text);
  }

  frame('TIT2', title);
  frame('TPE1', artist);
  frame('TALB', album);
  final Uint8List body = frames.takeBytes();

  final BytesBuilder builder = BytesBuilder();
  builder.add(asciiBytes('ID3'));
  builder.add(<int>[0x03, 0x00, 0x00]); // v2.3，无额外标志
  final int size = body.length;
  builder.add(<int>[(size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F]);
  builder.add(body);

  // 一帧 128kbps / 44.1kHz 的静音 MPEG-1 Layer III，让文件看起来像真的 MP3。
  builder.add(<int>[0xFF, 0xFB, 0x90, 0x00]);
  builder.add(Uint8List(413));

  return builder.takeBytes();
}

/// 建一个临时目录，调用方负责删除。
Future<Directory> createTempDirectory() => Directory.systemTemp.createTemp('tingyu_test_');
