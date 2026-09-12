import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/models/library_summaries.dart';
import 'package:tingyu/data/models/scanned_track.dart';
import 'package:tingyu/data/repositories/playlist_repository.dart';
import 'package:tingyu/data/repositories/track_repository.dart';

import 'support/test_support.dart';

void main() {
  late TingyuDatabase db;
  late TrackRepository tracks;

  setUp(() {
    db = openTestDatabase();
    tracks = TrackRepository(db);
  });

  tearDown(() => db.close());

  ScannedTrack scan(
    String path, {
    String title = '歌曲',
    String artist = '歌手',
    String album = '专辑',
    double duration = 180,
    int size = 1000,
    String? coverArtPath,
    String? lyrics,
  }) {
    return ScannedTrack(
      filePathOrUrl: path,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      fileSize: size,
      fileFormat: 'flac',
      coverArtPath: coverArtPath,
      lyrics: lyrics,
    );
  }

  test('mergeScan 首次扫描写入曲目并保留文件事实', () async {
    final MergeResult result = await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[scan('/music/a.flac'), scan('/music/b.flac', title: '另一首')],
    );

    expect(result.added, 2);
    expect(result.updated, 0);
    expect(result.removed, 0);

    final List<Track> stored = await tracks.bySource('src-1');
    expect(stored.length, 2);
    final Track first = stored.firstWhere((Track t) => t.filePathOrUrl == '/music/a.flac');
    expect(first.title, '歌曲');
    expect(first.fileSize, 1000);
    expect(first.fileFormat, 'flac');
    expect(first.id, TrackRepository.idFor(sourceId: 'src-1', filePathOrUrl: '/music/a.flac'));
  });

  test('重复扫描只更新变化的文件事实，保留封面/歌词/收藏/播放统计', () async {
    await tracks.mergeScan(sourceId: 'src-1', scanned: <ScannedTrack>[scan('/music/a.flac')]);
    final Track original = (await tracks.bySource('src-1')).single;

    await tracks.setFavorite(original.id, value: true);
    await tracks.updateLyrics(original.id, '歌词');
    await tracks.recordPlay(original.id);
    await tracks.updateCoverArt(original.id, path: 'cover.jpg');

    final MergeResult unchanged = await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[scan('/music/a.flac')],
    );
    expect(unchanged.updated, 0, reason: '没有变化就不应写库');

    final MergeResult changed = await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[scan('/music/a.flac', size: 2048, duration: 200)],
    );
    expect(changed.updated, 1);

    final Track merged = (await tracks.bySource('src-1')).single;
    expect(merged.fileSize, 2048);
    expect(merged.duration, 200);
    expect(merged.isFavorite, isTrue, reason: '用户资产不能被扫描覆盖');
    expect(merged.lyrics, '歌词');
    expect(merged.playCount, 1);
    expect(merged.coverArtPath, 'cover.jpg');
  });

  test('扫描中消失的曲目被删除，并从播放列表中摘除', () async {
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[scan('/music/a.flac'), scan('/music/b.flac')],
    );
    final String removedId = TrackRepository.idFor(sourceId: 'src-1', filePathOrUrl: '/music/b.flac');

    final PlaylistRepository playlists = PlaylistRepository(db);
    await playlists.create(id: 'pl-1', name: '收藏夹');
    await playlists.addTrack('pl-1', removedId);
    await playlists.addTrack('pl-1', TrackRepository.idFor(sourceId: 'src-1', filePathOrUrl: '/music/a.flac'));

    final MergeResult result = await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[scan('/music/a.flac')],
    );

    expect(result.removed, 1);
    expect((await tracks.bySource('src-1')).length, 1);
    final List<Track> playlistTracks = await playlists.tracksOf('pl-1');
    expect(playlistTracks.length, 1);
    expect(playlistTracks.single.filePathOrUrl, '/music/a.flac');
  });

  test('占位元数据会被后到的真实值替换，但不会覆盖已有值', () async {
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        ScannedTrack(filePathOrUrl: '/music/c.flac', title: '', album: '夸克曲库', duration: 10),
      ],
    );

    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        scan('/music/c.flac', title: '真标题', artist: '真歌手', album: '真专辑'),
      ],
    );
    Track stored = (await tracks.bySource('src-1')).single;
    expect(stored.title, '真标题');
    expect(stored.artist, '真歌手');
    expect(stored.album, '真专辑');

    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        ScannedTrack(
          filePathOrUrl: '/music/c.flac',
          title: '  ',
          artist: ScannedTrack.unknownArtist,
          album: '夸克曲库',
          duration: 10,
        ),
      ],
    );
    stored = (await tracks.bySource('src-1')).single;
    expect(stored.title, '真标题', reason: '空标题不能覆盖已有标题');
    expect(stored.artist, '真歌手', reason: '占位艺术家不能覆盖已有艺术家');
    expect(stored.album, '真专辑', reason: '占位专辑名不能覆盖已有专辑');
  });

  test('search 命中标题/艺术家/专辑', () async {
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        scan('/music/1.flac', title: '晴天', artist: '周杰伦', album: '叶惠美'),
        scan('/music/2.flac', title: 'Hello', artist: 'Adele', album: '25'),
      ],
    );

    expect((await tracks.search('周杰伦')).single.title, '晴天');
    expect((await tracks.search('hello')).single.album, '25');
    expect(await tracks.search('不存在'), isEmpty);
  });

  test('artists/albums 聚合：计数、年份取最大、占位名排最后', () async {
    await tracks.mergeScan(
      sourceId: 'src-1',
      scanned: <ScannedTrack>[
        scan('/music/1.flac', artist: '周杰伦', album: '叶惠美', duration: 1, coverArtPath: null),
        scan('/music/2.flac', artist: '周杰伦', album: '叶惠美', duration: 1, coverArtPath: 'c1.jpg'),
        ScannedTrack(
          filePathOrUrl: '/music/3.flac',
          title: 'x',
          artist: '周杰伦',
          album: '七里香',
          duration: 1,
        ),
        ScannedTrack(filePathOrUrl: '/music/4.flac', title: 'y', duration: 1, year: 2004),
        ScannedTrack(filePathOrUrl: '/music/5.flac', title: 'z', duration: 1, year: 2011),
      ],
    );

    final List<ArtistSummary> artists = await tracks.artists();
    expect(artists.map((ArtistSummary a) => a.name).toList(), <String>['周杰伦', ScannedTrack.unknownArtist]);
    expect(artists.first.trackCount, 3);
    expect(artists.last.trackCount, 2);

    final List<AlbumSummary> albums = await tracks.albums();
    expect(albums.map((AlbumSummary a) => a.album).toList(),
        <String>['七里香', '叶惠美', ScannedTrack.unknownAlbum]);
    final AlbumSummary album = albums.firstWhere((AlbumSummary a) => a.album == '叶惠美');
    expect(album.trackCount, 2);
    expect(album.coverArtPath, 'c1.jpg');
    final AlbumSummary unknown = albums.last;
    expect(unknown.year, 2011, reason: '未知专辑合并后年份取最大值');
    expect(unknown.trackCount, 2);
  });
}
