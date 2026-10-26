package model

// The M3 source UI state. It is deliberately minimal (plan §6 M3 allows the
// smallest usable login/progress surface): a WebDAV credential form and a Quark
// login (QR image or pasted Cookie) on the sources page, plus one error line per
// source that turns into a "重新登录" button. No new visual design was invented;
// every widget used here already exists in the design tokens.

import (
	"github.com/egoist/mygo/ui"
)

// Source kinds, mirroring the strings in music_sources.kind.
const (
	SourceKindWebDAV = "webdav"
	SourceKindQuark  = "quark"
)

// SourceFormValues is what the form holds when a button is pressed. Passing it
// by value keeps the background worker from reading state the UI may be editing.
type SourceFormValues struct {
	Editing  string // source id when re-logging in, empty when adding
	Name     string
	URL      string
	Username string
	Password string
	Cookie   string
}

// SourceForm is the add/re-login panel.
type SourceForm struct {
	Open     bool
	Kind     string
	Editing  string
	Name     string
	URL      string
	Username string
	Password string
	Cookie   string
	Busy     bool
	Message  string
	// QR is the rendered QR code and QRPhase its state sentence.
	QR      *ui.Bitmap
	QRPhase string
}

// SourceActions are the remote-source side effects. It is a separate interface
// from Actions so the local-only UI tests keep their existing fake.
type SourceActions interface {
	AddWebDAVSource(values SourceFormValues)
	AddQuarkSource(values SourceFormValues)
	LoginQuark(values SourceFormValues)
	CancelSourceLogin()
	CancelSourceSync()
}

// SourceActionsOf returns the source actions when the app installed them.
func (s *State) SourceActionsOf() SourceActions {
	actions, _ := s.actions.(SourceActions)
	return actions
}

// SourceForm returns the form for the view to edit in place.
func (s *State) SourceForm() *SourceForm { return &s.sourceForm }

// OpenSourceForm opens the form for a kind, optionally for an existing source
// (re-login), prefilled from that source's row.
func (s *State) OpenSourceForm(kind, editing string) {
	form := SourceForm{Open: true, Kind: kind, Editing: editing}
	if editing != "" {
		for _, source := range s.sources {
			if source.ID != editing {
				continue
			}
			form.Name = source.Name
			form.Kind = source.Kind
			if source.Kind == SourceKindWebDAV {
				form.URL = source.WebDAVURL
				form.Username = source.WebDAVUsername
			}
			break
		}
	}
	s.sourceForm = form
}

// CloseSourceForm hides the form and drops the QR image.
func (s *State) CloseSourceForm() {
	s.sourceForm = SourceForm{}
}

// SetSourceFormBusy marks the form as waiting and shows a message.
func (s *State) SetSourceFormBusy(busy bool, message string) {
	s.sourceForm.Busy = busy
	if message != "" {
		s.sourceForm.Message = message
	}
}

// SetSourceFormMessage updates the form's own message line.
func (s *State) SetSourceFormMessage(message string) {
	s.sourceForm.Message = message
}

// SetSourceQR shows the QR image and its phase.
func (s *State) SetSourceQR(bitmap *ui.Bitmap, phase string) {
	s.sourceForm.QR = bitmap
	s.sourceForm.QRPhase = phase
}

// SourceError returns the re-login sentence of a source, if it has one.
func (s *State) SourceError(sourceID string) string {
	return s.sourceErrors[sourceID]
}

// SetSourceError records that a source needs attention (credential failure).
func (s *State) SetSourceError(sourceID, message string) {
	if s.sourceErrors == nil {
		s.sourceErrors = map[string]string{}
	}
	s.sourceErrors[sourceID] = message
}

// ClearSourceError drops a source's error after a successful sync.
func (s *State) ClearSourceError(sourceID string) {
	delete(s.sourceErrors, sourceID)
}

// Values snapshots the form for an action. The background worker then never
// reads a field the UI thread may be editing.
func (f SourceForm) Values() SourceFormValues {
	return SourceFormValues{
		Editing:  f.Editing,
		Name:     f.Name,
		URL:      f.URL,
		Username: f.Username,
		Password: f.Password,
		Cookie:   f.Cookie,
	}
}
