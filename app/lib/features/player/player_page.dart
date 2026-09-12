import 'package:flutter/material.dart';

import '../../playback/playback_item.dart';
import '../../playback/playback_snapshot.dart';
import '../../playback/tingyu_audio_handler.dart';

/// M1 播放验证界面：不承担产品 UI 职责，只用于验证
/// 「引擎播放 → 状态快照 → 系统媒体会话」这条链路。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.handler});

  final TingyuAudioHandler handler;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final TextEditingController _sourcesController = TextEditingController();

  @override
  void dispose() {
    _sourcesController.dispose();
    super.dispose();
  }

  Future<void> _loadQueue() async {
    final List<String> sources = _sourcesController.text
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);
    if (sources.isEmpty) {
      return;
    }
    await widget.handler.setQueue(
      sources
          .map((String source) => PlaybackItem.fromUri(
                source.contains('://') ? Uri.parse(source) : Uri.file(source),
              ))
          .toList(growable: false),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('听屿 · 播放链路验证')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _sourcesController,
              maxLines: 3,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                labelText: '播放源（每行一个本地路径或 URL）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: <Widget>[
                FilledButton(onPressed: _loadQueue, child: const Text('载入队列')),
                FilledButton(
                  onPressed: () => widget.handler.play(),
                  child: const Text('播放'),
                ),
                FilledButton(
                  onPressed: () => widget.handler.pause(),
                  child: const Text('暂停'),
                ),
                FilledButton(
                  onPressed: () => widget.handler.skipToPrevious(),
                  child: const Text('上一首'),
                ),
                FilledButton(
                  onPressed: () => widget.handler.skipToNext(),
                  child: const Text('下一首'),
                ),
                FilledButton(
                  onPressed: () => widget.handler.seek(
                    widget.handler.currentSnapshot.position + const Duration(seconds: 5),
                  ),
                  child: const Text('+5s'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            StreamBuilder<PlaybackSnapshot>(
              stream: widget.handler.snapshots,
              initialData: PlaybackSnapshot.initial,
              builder: (BuildContext context, AsyncSnapshot<PlaybackSnapshot> async) {
                final PlaybackSnapshot snapshot = async.data ?? PlaybackSnapshot.initial;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('引擎：${widget.handler.engineName}'),
                    Text('阶段：${snapshot.processing.name}　播放中：${snapshot.playing}'),
                    Text(
                      '进度：${_format(snapshot.position)} / ${_format(snapshot.duration)}'
                      '　缓冲：${_format(snapshot.buffered)}',
                    ),
                    Text('队列下标：${snapshot.index}　倍速：${snapshot.rate}'),
                    Slider(
                      value: snapshot.volume,
                      onChanged: (double value) => widget.handler.setVolume(value),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _format(Duration duration) {
    final String minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
