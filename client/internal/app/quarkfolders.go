//go:build darwin

package app

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/sources"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

// quarkFormUpdate keeps late network replies out of a reopened form.
func (a *application) quarkFormUpdate(v model.SourceFormValues, update func(*model.SourceForm)) {
	a.updateWindow(func() {
		f := a.model.SourceForm()
		if f.Open && f.Token == v.Token {
			update(f)
		}
	})
}
func (a *application) quarkMessage(v model.SourceFormValues, message string) {
	a.quarkFormUpdate(v, func(f *model.SourceForm) { f.Busy = false; f.Message = message })
}

func (a *application) BrowseQuarkFolders(v model.SourceFormValues) { go a.loadQuarkFolders(v) }
func (a *application) loadQuarkFolders(v model.SourceFormValues) {
	if a.sourceMgr == nil || a.creds == nil {
		a.quarkMessage(v, "来源服务不可用")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	folders, cookie, err := readQuarkFolders(ctx, a.sourceMgr.QuarkClient(), a.creds, v)
	message := ""
	if err != nil {
		message = err.Error()
	}
	a.updateWindow(func() { a.model.State().ApplyQuarkFolders(v, folders, cookie, message) })
}

// readQuarkFolders never persists a source or treats an incomplete listing as empty.
func readQuarkFolders(ctx context.Context, client *sources.QuarkClient, creds *sources.Credentials, v model.SourceFormValues) ([]model.QuarkFolder, string, error) {
	if strings.TrimSpace(v.FolderFID) == "" {
		return nil, "", errors.New("请选择一个文件夹")
	}
	cookie := v.Cookie
	if cookie == "" && v.Editing != "" {
		stored, found, err := creds.QuarkCookie(v.Editing)
		if err != nil {
			return nil, "", fmt.Errorf("读取登录凭据失败：%w", err)
		}
		if !found {
			return nil, "", errors.New("没有登录凭据，请先重新登录")
		}
		cookie = stored
	}
	session := sources.NewQuarkSession(sources.ParseQuarkCookie(cookie))
	if session.IsEmpty() {
		return nil, "", errors.New("登录凭据不可用，请先重新登录")
	}
	listing, err := client.ListFolder(ctx, v.FolderFID, session)
	if err != nil {
		return nil, "", err
	}
	if !listing.Complete {
		return nil, "", fmt.Errorf("文件夹未加载完整，请重试：%s", listing.IncompleteReason)
	}
	folders := []model.QuarkFolder{}
	for _, item := range listing.Items {
		if item.IsFolder && item.ID != "" && item.ID != v.FolderFID {
			folders = append(folders, model.QuarkFolder{FID: item.ID, Name: item.Name})
		}
	}
	sort.SliceStable(folders, func(i, j int) bool { return folders[i].Name < folders[j].Name })
	return folders, session.Header(), nil
}

func (a *application) ConfirmQuarkFolder(v model.SourceFormValues) {
	f := a.model.SourceForm()
	if !f.Open || !f.Choosing || !f.FolderReady || f.Busy || f.Token != v.Token || f.FolderRequest != v.FolderRequest {
		return
	}
	f.Busy = true
	f.Message = ""
	// The picker's cancel/escape path also cancels confirmation's network check.
	a.cancelSourceLogin()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	a.sourceLoginMu.Lock()
	seq := a.sourceLoginSeq.Add(1)
	a.sourceLoginCancel = cancel
	a.sourceLoginActive = seq
	a.sourceLoginMu.Unlock()
	go func() {
		defer func() {
			a.sourceLoginMu.Lock()
			if a.sourceLoginActive == seq {
				a.sourceLoginCancel = nil
				a.sourceLoginActive = 0
			}
			a.sourceLoginMu.Unlock()
			cancel()
		}()
		if a.lib == nil || !a.lib.Writable() || a.sourceMgr == nil || a.syncer == nil {
			a.quarkMessage(v, "当前不能保存来源，请使用可写曲库重试")
			return
		}
		if a.scanning.Swap(true) {
			a.quarkMessage(v, "已有同步在进行，请完成或取消后再更换文件夹")
			return
		}
		defer a.scanning.Store(false)
		source, err := saveQuarkFolder(ctx, a.lib, a.creds, a.sourceMgr.QuarkClient(), v)
		if err != nil {
			a.quarkMessage(v, err.Error())
			return
		}
		a.sourceMgr.Invalidate(source.ID)
		a.reloadSources()
		a.quarkFormUpdate(v, func(f *model.SourceForm) { a.model.CloseSourceForm() })
		a.runRemoteSync(source)
	}()
}

// saveQuarkFolder rechecks access before committing. Relogin preserves the
// source's ID, name and library associations; only an explicit choice changes FID.
func saveQuarkFolder(ctx context.Context, lib *library.Library, creds *sources.Credentials, client *sources.QuarkClient, v model.SourceFormValues) (library.Source, error) {
	if lib == nil || !lib.Writable() {
		return library.Source{}, errors.New("曲库只读，不能保存来源")
	}
	_, cookie, err := readQuarkFolders(ctx, client, creds, v)
	if err != nil {
		return library.Source{}, err
	}
	source := library.Source{ID: v.Editing, Kind: sources.KindQuark}
	if v.Editing != "" {
		all, err := lib.Sources(ctx)
		if err != nil {
			return source, err
		}
		found := false
		for _, old := range all {
			if old.ID == v.Editing {
				source = old
				found = true
				break
			}
		}
		if !found || source.Kind != sources.KindQuark {
			return source, errors.New("夸克来源已不存在，请重新添加")
		}
	} else {
		source.ID = newSourceID()
	}
	source.Name = strings.TrimSpace(v.Name)
	if source.Name == "" {
		source.Name = "夸克网盘"
	}
	source.QuarkFolderFID = v.FolderFID
	source.QuarkFolderPath = v.FolderPath
	if v.AccountName != "" {
		source.QuarkAccountName = v.AccountName
	}
	source.SyncStatus = "未同步"
	if err = creds.SetQuarkCookie(source.ID, cookie); err != nil {
		return source, fmt.Errorf("保存登录凭据失败：%w", err)
	}
	if err = lib.UpsertSource(ctx, source); err != nil {
		if v.Editing == "" {
			_ = creds.DeleteQuarkCookie(source.ID)
		}
		return source, err
	}
	return source, nil
}
