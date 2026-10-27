package shell

import (
	"github.com/egoist/mygo/ui"
	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"testing"
)

type folderActions struct {
	fakeActions
	state     *model.State
	browsed   []model.SourceFormValues
	confirmed []model.SourceFormValues
}

func (a *folderActions) BrowseQuarkFolders(v model.SourceFormValues) {
	a.browsed = append(a.browsed, v)
	folders := []model.QuarkFolder{}
	if v.FolderFID == "0" {
		folders = []model.QuarkFolder{{FID: "music", Name: "音乐"}, {FID: "other", Name: "其他"}}
	}
	a.state.ApplyQuarkFolders(v, folders, "test-cookie", "")
}
func (a *folderActions) ConfirmQuarkFolder(v model.SourceFormValues) {
	a.confirmed = append(a.confirmed, v)
}

func TestQuarkFolderPickerNavigationConfirmationAndCancel(t *testing.T) {
	for _, size := range [][2]int{{900, 600}, {1200, 760}} {
		m := newModel(t)
		s := m.State()
		a := &folderActions{state: s}
		m.SetActions(a)
		s.SetSources([]library.Source{{ID: "q", Name: "夸克音乐", Kind: model.SourceKindQuark, QuarkFolderFID: "0"}})
		s.OpenPage(model.PageSources)
		tt := ui.NewTester(m.View, size[0], size[1])
		frame(tt)
		if err := tt.Click("来源操作"); err != nil {
			t.Fatal(err)
		}
		if err := tt.ChooseMenuItem("更换文件夹…"); err != nil {
			t.Fatal(err)
		}
		frame(tt)
		visibleControl(t, tt, "选择音乐文件夹", size[0], size[1], 100, 15)
		visibleControl(t, tt, "确认夸克文件夹", size[0], size[1], 80, 25)
		visibleControl(t, tt, "取消夸克文件夹", size[0], size[1], 40, 25)
		if err := tt.Click("打开文件夹：音乐"); err != nil {
			t.Fatal(err)
		}
		frame(tt)
		if s.SourceForm().CurrentFolder().FID != "music" || !tt.HasText("当前位置：/音乐") {
			t.Fatal("folder navigation failed")
		}
		if err := tt.Click("上一级"); err != nil {
			t.Fatal(err)
		}
		frame(tt)
		if s.SourceForm().CurrentFolder().FID != "0" {
			t.Fatal("back did not return to root")
		}
		if err := tt.Click("打开文件夹：音乐"); err != nil {
			t.Fatal(err)
		}
		frame(tt)
		if err := tt.Click("使用此文件夹并同步"); err != nil {
			t.Fatal(err)
		}
		if len(a.confirmed) != 1 || a.confirmed[0].FolderFID != "music" || a.confirmed[0].Editing != "q" {
			t.Fatalf("wrong folder confirmed: %+v", a.confirmed)
		}
		a.confirmed = nil
		if err := tt.Click("取消选择"); err != nil {
			t.Fatal(err)
		}
		frame(tt)
		if s.SourceForm().Open || s.SourceForm().Cookie != "" || len(a.confirmed) != 0 {
			t.Fatal("cancel saved or kept picker credentials")
		}
	}
}

func TestQuarkFolderPickerDoesNotConfirmFailedOrPendingListing(t *testing.T) {
	m := newModel(t)
	s := m.State()
	a := &folderActions{state: s}
	m.SetActions(a)
	s.OpenPage(model.PageSources)
	pending := s.OpenQuarkFolders("")
	tt := ui.NewTester(m.View, 900, 600)
	frame(tt)
	if err := tt.Click("使用此文件夹并同步"); err != nil {
		t.Fatal(err)
	}
	if len(a.confirmed) != 0 {
		t.Fatal("pending listing was confirmed")
	}
	s.ApplyQuarkFolders(pending, nil, "", "网络错误")
	frame(tt)
	if err := tt.Click("使用此文件夹并同步"); err != nil {
		t.Fatal(err)
	}
	if len(a.confirmed) != 0 {
		t.Fatal("failed listing was confirmed")
	}
	tt.Key(0, ui.KeyEscape)
	frame(tt)
	if s.SourceForm().Open || s.SourceForm().Cookie != "" {
		t.Fatal("escape did not close and clear picker")
	}
}
