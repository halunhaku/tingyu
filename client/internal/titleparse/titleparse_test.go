package titleparse

import "testing"

func TestSmartTitleParserMatchesTheDartRules(t *testing.T) {
	cases := []struct {
		name                 string
		title, artist, album string
	}{
		{"01. 花海-周杰伦-魔杰座.wav", "花海", "周杰伦", "魔杰座"},
		{"周杰伦 - 晴天 - 叶惠美.flac", "晴天", "周杰伦", "叶惠美"},
		{"明明就 - 周杰伦.mp3", "明明就", "周杰伦", "未知专辑"},
		{"周杰伦 - 园游会 (Live).mp3", "园游会", "周杰伦", "未知专辑"},
		{"01. 晴天 - 周杰伦 [320k].mp3", "晴天", "周杰伦", "未知专辑"},
		{"song.flac", "song", "未知艺术家", "未知专辑"},
		{"无扩展名", "无扩展名", "未知艺术家", "未知专辑"},
	}
	for _, testCase := range cases {
		parsed := ParseFilename(testCase.name)
		if parsed.Title != testCase.title || parsed.Artist != testCase.artist || parsed.Album != testCase.album {
			t.Errorf("ParseFilename(%q) = %+v, want title=%q artist=%q album=%q",
				testCase.name, parsed, testCase.title, testCase.artist, testCase.album)
		}
	}
}
