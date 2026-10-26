package sources

// The placeholder metadata both clients write when a source cannot know a
// field. The values are titleparse's (and the library schema's); they are
// aliased here because the remote adapters build their rows from these names
// and callers outside this package already read sources.WebDAVAlbum.
const (
	UnknownArtist = "未知艺术家"
	UnknownAlbum  = "未知专辑"
	WebDAVAlbum   = "WebDAV 曲库"
	QuarkAlbum    = "夸克曲库"
)
