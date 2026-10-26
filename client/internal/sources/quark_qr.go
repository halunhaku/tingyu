package sources

// Quark QR login: ask for a token, poll it, then exchange the service ticket
// for cookies. Ported from app/lib/sources/quark/quark_qr_login.dart.
//
// These endpoints have no official third-party documentation. The flow follows
// the current web login: client_id 532, the CAS cookie from the token request
// travels through the poll and the exchange, and redirects are followed by hand
// so every intermediate Set-Cookie is collected (a normal redirect-following
// client drops them, which is why the ticket exchange failed in the Flutter
// client before it did this).

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// QR login defaults.
const (
	quarkQRUserAgent     = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
	quarkQRClientID      = "532"
	quarkQRClientVersion = "1.2"
	quarkQRUOPBase       = "https://uop.quark.cn/cas/ajax"
	quarkQRScanPage      = "https://su.quark.cn/4_eMHBJ"
	quarkQRPanBase       = "https://pan.quark.cn"
	quarkQRDriveBase     = "https://drive-pc.quark.cn"
	quarkQRMaxHops       = 6
)

// QuarkQROptions configure the login flow. Every host is overridable so tests
// and the acceptance harness never reach the real service.
type QuarkQROptions struct {
	HTTP      *http.Client
	UOPBase   string
	ScanPage  string
	PanBase   string
	DriveBase string
	Clock     func() time.Time
	Logf      func(string, ...any)
}

// QuarkQRLogin runs one login attempt at a time.
type QuarkQRLogin struct {
	http      *http.Client
	uopBase   string
	scanPage  string
	panBase   string
	driveBase string
	logf      func(string, ...any)
}

// NewQuarkQRLogin builds the client.
func NewQuarkQRLogin(options QuarkQROptions) *QuarkQRLogin {
	base := func(value, fallback string) string {
		if strings.TrimSpace(value) == "" {
			return strings.TrimRight(fallback, "/")
		}
		return strings.TrimRight(value, "/")
	}
	httpClient := options.HTTP
	if httpClient == nil {
		httpClient = &http.Client{Transport: newTransport(), Timeout: 30 * time.Second}
	}
	// Redirects are followed by hand so intermediate Set-Cookie headers are not
	// lost (see the file comment); an injected client is copied rather than
	// mutated so the caller's client keeps its own behaviour.
	copied := *httpClient
	copied.CheckRedirect = func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}
	httpClient = &copied
	return &QuarkQRLogin{
		http:      httpClient,
		uopBase:   base(options.UOPBase, quarkQRUOPBase),
		scanPage:  base(options.ScanPage, quarkQRScanPage),
		panBase:   base(options.PanBase, quarkQRPanBase),
		driveBase: base(options.DriveBase, quarkQRDriveBase),
		logf:      options.Logf,
	}
}

// QuarkQRSession is one QR login in progress.
type QuarkQRSession struct {
	Token     string
	QRContent string
	jar       *QuarkCookieJar
}

// Jar returns the CAS cookies carried through the flow.
func (s *QuarkQRSession) Jar() *QuarkCookieJar { return s.jar }

// QuarkQRPhase is where a poll stands.
type QuarkQRPhase int

const (
	// QuarkQRWaiting means the phone has not scanned yet.
	QuarkQRWaiting QuarkQRPhase = iota
	// QuarkQRScanned means the login completed and Cookie is set.
	QuarkQRScanned
	// QuarkQRExpired means the code must be refreshed.
	QuarkQRExpired
	// QuarkQRFailed means the attempt ended with an error message.
	QuarkQRFailed
)

// QuarkQRPoll is one poll result.
type QuarkQRPoll struct {
	Phase   QuarkQRPhase
	Cookie  string
	Message string
}

// Start asks for a token and builds the QR content.
func (l *QuarkQRLogin) Start(ctx context.Context) (*QuarkQRSession, error) {
	requestID, err := randomRequestID()
	if err != nil {
		return nil, wrapError(KindOther, err, "生成登录请求编号失败")
	}
	values := url.Values{}
	values.Set("client_id", quarkQRClientID)
	values.Set("v", quarkQRClientVersion)
	values.Set("request_id", requestID)
	values.Set("uc_param_str", "")
	endpoint := l.uopBase + "/getTokenForQrcodeLogin?" + values.Encode()
	jar := NewQuarkCookieJar()
	response, err := l.doFollow(ctx, endpoint, jar, nil)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, wrapError(KindNetwork, err, "申请二维码失败")
	}
	body := decodeQuarkJSON(response.body)
	token := nestedString(body, "data", "members", "token")
	status := statusOf(body)
	if response.status != 200 || status != 2000000 || token == "" {
		return nil, newError(KindOther, "申请二维码失败（HTTP %d，status=%d %s）",
			response.status, status, messageOf(body))
	}
	businessParameters := "S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0"
	// The empty `uc_param_str=` must keep its equals sign: the Dart client
	// documents that a bare `uc_param_str` makes the short link drop the token
	// parameters on redirect, and the phone then says the login expired.
	qrContent := fmt.Sprintf("%s?token=%s&client_id=%s&ssb=weblogin&uc_param_str=&uc_biz_str=%s",
		l.scanPage, url.QueryEscape(token), quarkQRClientID, url.QueryEscape(businessParameters))
	return &QuarkQRSession{Token: token, QRContent: qrContent, jar: jar}, nil
}

// Poll asks once whether the phone confirmed. On confirmation it exchanges the
// ticket for the Cookie.
func (l *QuarkQRLogin) Poll(ctx context.Context, session *QuarkQRSession) (QuarkQRPoll, error) {
	if session == nil || session.Token == "" {
		return QuarkQRPoll{Phase: QuarkQRFailed, Message: "登录会话已丢失，请刷新二维码"}, nil
	}
	requestID, err := randomRequestID()
	if err != nil {
		return QuarkQRPoll{Phase: QuarkQRFailed, Message: "生成登录请求编号失败"}, nil
	}
	values := url.Values{}
	values.Set("client_id", quarkQRClientID)
	values.Set("v", quarkQRClientVersion)
	values.Set("token", session.Token)
	values.Set("request_id", requestID)
	values.Set("uc_param_str", "")
	endpoint := l.uopBase + "/getServiceTicketByQrcodeToken?" + values.Encode()
	response, err := l.doFollow(ctx, endpoint, session.jar, nil)
	if err != nil {
		if ctx.Err() != nil {
			return QuarkQRPoll{}, ctx.Err()
		}
		return QuarkQRPoll{Phase: QuarkQRFailed, Message: "查询扫码状态失败：" + err.Error()}, nil
	}
	body := decodeQuarkJSON(response.body)
	status := statusOf(body)
	ticket := nestedString(body, "data", "members", "service_ticket")
	switch status {
	case 2000000:
		if ticket == "" {
			return QuarkQRPoll{Phase: QuarkQRFailed, Message: "已扫码但未拿到登录票据，请重试"}, nil
		}
		cookie, exchangeErr := l.exchangeTicket(ctx, ticket, session.jar)
		if exchangeErr != nil {
			return QuarkQRPoll{Phase: QuarkQRFailed, Message: exchangeErr.Error()}, nil
		}
		if cookie == "" {
			return QuarkQRPoll{Phase: QuarkQRFailed, Message: "换取登录凭证失败，请重试"}, nil
		}
		return QuarkQRPoll{Phase: QuarkQRScanned, Cookie: cookie}, nil
	case 50004001:
		return QuarkQRPoll{Phase: QuarkQRWaiting, Message: "等待手机扫码"}, nil
	case 50004002:
		return QuarkQRPoll{Phase: QuarkQRExpired, Message: "二维码已过期，请刷新"}, nil
	case 50004003:
		message := messageOf(body)
		if message == "" {
			message = "扫码登录失败，请重试"
		}
		return QuarkQRPoll{Phase: QuarkQRFailed, Message: message}, nil
	case 50004004:
		return QuarkQRPoll{Phase: QuarkQRFailed, Message: "已在夸克 App 中取消登录"}, nil
	}
	return QuarkQRPoll{Phase: QuarkQRWaiting, Message: fmt.Sprintf("等待手机扫码（status=%d）", status)}, nil
}

// exchangeTicket trades the service ticket for the pan cookies and bootstraps
// the drive-pc domain cookies. Only a session that received `__pus` counts as
// logged in, which is the check the Flutter client learned to make.
func (l *QuarkQRLogin) exchangeTicket(ctx context.Context, ticket string, jar *QuarkCookieJar) (string, error) {
	trace := make([]string, 0, 6)
	infoURL := fmt.Sprintf("%s/account/info?st=%s&lw=scan&fr=pc&platform=pc",
		l.panBase, url.QueryEscape(ticket))
	response, err := l.doFollow(ctx, infoURL, jar, nil, trace)
	if err != nil {
		return "", fmt.Errorf("换取登录凭证失败：%v", err)
	}
	exchangeStatus := response.status

	// Visiting the home page and the cheap listing endpoint fills in the
	// drive-pc/.quark.cn domain cookies. A failure here is recorded in the trace
	// and does not abort: the ticket itself may already have delivered `__pus`.
	bootstrapHeaders := map[string]string{
		"Accept":                    "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
		"Upgrade-Insecure-Requests": "1",
	}
	if _, err := l.doFollow(ctx, l.panBase+"/", jar, bootstrapHeaders, trace); err != nil {
		trace = append(trace, "bootstrap:error")
	}
	driveHeaders := map[string]string{"Origin": l.panBase, "Referer": l.panBase + "/"}
	driveURL := fmt.Sprintf("%s/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=0&_page=1&_size=1&_fetch_total=1", l.driveBase)
	if _, err := l.doFollow(ctx, driveURL, jar, driveHeaders, trace); err != nil {
		trace = append(trace, "drive:error")
	}

	if !jar.Has("__pus") {
		return "", fmt.Errorf("未收到 __pus（HTTP %d；cookies=%s；%s）",
			exchangeStatus, firstNonEmpty(strings.Join(jar.Names(), ","), "none"), strings.Join(trace, " → "))
	}
	return jar.HeaderExcept("push_vurl", "logout_id"), nil
}

// quarkHTTPResponse is one final response of a hand-followed redirect chain.
type quarkHTTPResponse struct {
	status int
	body   string
	header http.Header
	url    string
}

// doFollow follows up to six redirects, merging Set-Cookie at every hop.
func (l *QuarkQRLogin) doFollow(ctx context.Context, initial string, jar *QuarkCookieJar, extra map[string]string, trace ...[]string) (*quarkHTTPResponse, error) {
	var traceLog *[]string
	if len(trace) > 0 {
		traceLog = &trace[0]
	}
	current := initial
	for hop := 0; hop < quarkQRMaxHops; hop++ {
		requestCtx, cancel := context.WithTimeout(ctx, requestTimeout)
		req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, current, nil)
		if err != nil {
			cancel()
			return nil, err
		}
		req.Header.Set("User-Agent", quarkQRUserAgent)
		req.Header.Set("Accept", "application/json, text/plain, */*")
		req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
		req.Header.Set("Referer", l.panBase+"/")
		if header := jar.Header(); header != "" {
			req.Header.Set("Cookie", header)
		}
		for name, value := range extra {
			req.Header.Set(name, value)
		}
		response, err := l.http.Do(req)
		if err != nil {
			cancel()
			return nil, err
		}
		data, readErr := io.ReadAll(io.LimitReader(response.Body, quarkMaxBody))
		response.Body.Close()
		cancel()
		jar.MergeSetCookie(response.Header.Values("Set-Cookie"))
		parsed, _ := url.Parse(current)
		if traceLog != nil && parsed != nil {
			*traceLog = append(*traceLog, fmt.Sprintf("%s%s:%d", parsed.Host, parsed.Path, response.StatusCode))
		}
		if response.StatusCode >= 300 && response.StatusCode < 400 {
			location := response.Header.Get("Location")
			if location != "" {
				next, resolveErr := parsed.Parse(location)
				if resolveErr != nil {
					return nil, resolveErr
				}
				current = next.String()
				continue
			}
		}
		if readErr != nil {
			return nil, readErr
		}
		return &quarkHTTPResponse{status: response.StatusCode, body: string(data), header: response.Header, url: current}, nil
	}
	return nil, fmt.Errorf("登录跳转次数过多，请重试")
}

func randomRequestID() (string, error) {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

func decodeQuarkJSON(body string) map[string]any {
	if body == "" {
		return nil
	}
	var decoded map[string]any
	if err := json.Unmarshal([]byte(body), &decoded); err != nil {
		return nil
	}
	return decoded
}

// statusOf reads the CAS status, which arrives as a number in the token
// response and has been seen as a string in others.
func statusOf(body map[string]any) int {
	if body == nil {
		return 0
	}
	return intValue(body["status"])
}

func messageOf(body map[string]any) string {
	if body == nil {
		return ""
	}
	message, _ := body["message"].(string)
	return message
}

// nestedString walks a JSON path and returns the string at its end.
func nestedString(body map[string]any, path ...string) string {
	var current any = body
	for _, key := range path {
		object, ok := current.(map[string]any)
		if !ok {
			return ""
		}
		current = object[key]
	}
	value, _ := current.(string)
	return value
}

// String names the phase for logs and evidence.
func (p QuarkQRPhase) String() string {
	switch p {
	case QuarkQRScanned:
		return "scanned"
	case QuarkQRExpired:
		return "expired"
	case QuarkQRFailed:
		return "failed"
	}
	return "waiting"
}
