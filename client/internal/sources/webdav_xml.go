package sources

// PROPFIND multistatus parsing, ported from webdav_xml_parser.dart.
//
// encoding/xml matches by local name, so namespace prefixes do not matter, and
// a scalar field keeps the last value seen — the same last-wins rule the Dart
// tree walk has. Response entries without an href are dropped, as there.

import (
	"encoding/xml"
	"strings"
)

// davItem is one PROPFIND response entry.
type davItem struct {
	Href        string
	DisplayName *string // nil when the element is absent
	IsDir       bool
	ContentLen  int64
	ETag        string
	LastMod     string
}

type davMultistatus struct {
	// Requiring the multistatus root is a deliberate tightening over the Dart
	// parser, which walks descendants and would read a well-formed HTML error
	// page as an empty directory — and an empty, authoritative snapshot deletes
	// every track of the source (plan §2.1 #2). The root name is the protocol
	// contract; a different document is unreadable, not empty.
	XMLName   xml.Name      `xml:"multistatus"`
	Responses []davResponse `xml:"response"`
}

type davResponse struct {
	Href     string        `xml:"href"`
	Propstat []davPropstat `xml:"propstat"`
}

type davPropstat struct {
	Prop davProp `xml:"prop"`
}

type davProp struct {
	DisplayName   *string         `xml:"displayname"`
	ContentLength string          `xml:"getcontentlength"`
	ETag          string          `xml:"getetag"`
	LastModified  string          `xml:"getlastmodified"`
	ResourceType  davResourceType `xml:"resourcetype"`
}

type davResourceType struct {
	Collection *struct{} `xml:"collection"`
}

// parseMultistatus returns the entries of a PROPFIND response. A body that is
// not a multistatus document is an error, which the scan counts as skipped
// rather than treating as "the folder is empty".
func parseMultistatus(body []byte) ([]davItem, error) {
	var document davMultistatus
	if err := xml.Unmarshal(body, &document); err != nil {
		return nil, err
	}
	items := make([]davItem, 0, len(document.Responses))
	for _, response := range document.Responses {
		href := strings.TrimSpace(response.Href)
		if href == "" {
			continue
		}
		item := davItem{Href: href}
		for _, propstat := range response.Propstat {
			prop := propstat.Prop
			if prop.DisplayName != nil {
				text := strings.TrimSpace(*prop.DisplayName)
				item.DisplayName = &text
			}
			if value := strings.TrimSpace(prop.ContentLength); value != "" {
				item.ContentLen = parseInt64(value)
			}
			if value := strings.TrimSpace(prop.ETag); value != "" {
				item.ETag = strings.Trim(value, `"`)
			}
			if value := strings.TrimSpace(prop.LastModified); value != "" {
				item.LastMod = value
			}
			if prop.ResourceType.Collection != nil {
				item.IsDir = true
			}
		}
		items = append(items, item)
	}
	return items, nil
}

// parseInt64 reads a decimal byte count, 0 when the server said something else.
func parseInt64(text string) int64 {
	var value int64
	for i := 0; i < len(text); i++ {
		if text[i] < '0' || text[i] > '9' {
			return 0
		}
		value = value*10 + int64(text[i]-'0')
		if value < 0 {
			return 0
		}
	}
	return value
}
