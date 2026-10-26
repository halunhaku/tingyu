package metadata

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// AI settings. The JSON keys are the Flutter client's
// (app/lib/sources/ai/ai_config.dart AISettings.toJson), so the same Keychain
// account stays readable by both clients — the API key is never in
// settings.json, never in a log line and never in the repository.
const (
	// AIKeychainAccount is the Keychain account holding the settings blob,
	// matching app/lib/sources/ai/ai_settings_repository.dart.
	AIKeychainAccount = "tingyu_ai_settings"
	// AILegacyKeychainAccount is where the old Swift client kept only the key.
	AILegacyKeychainAccount = "tingyu_ai_api_key"
)

// AIPreset is one OpenAI-compatible provider the settings page offers.
type AIPreset struct {
	Name        string // deepseek, qwen, kimi, openai, ollama, custom
	DisplayName string
	BaseURL     string
	Model       string
}

// AIPresets is the Flutter preset list, in its order.
var AIPresets = []AIPreset{
	{"deepseek", "DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat"},
	{"qwen", "通义千问 (Qwen)", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus"},
	{"kimi", "Kimi (Moonshot)", "https://api.moonshot.cn/v1", "moonshot-v1-8k"},
	{"openai", "OpenAI", "https://api.openai.com/v1", "gpt-4o-mini"},
	{"ollama", "本地 Ollama", "http://localhost:11434/v1", "qwen2.5:7b"},
	{"custom", "自定义", "https://api.openai.com/v1", "gpt-4o-mini"},
}

// AISettings is the stored configuration.
type AISettings struct {
	Enabled bool   `json:"isEnabled"`
	Preset  string `json:"preset"`
	BaseURL string `json:"baseUrl"`
	Model   string `json:"model"`
	APIKey  string `json:"apiKey"`
}

// DefaultAISettings is AISettings() in Flutter: off, DeepSeek preset, no key.
func DefaultAISettings() AISettings {
	return AISettings{Preset: "deepseek", BaseURL: AIPresets[0].BaseURL, Model: AIPresets[0].Model}
}

// Ready reports whether the fallback can run at all. A source that is not
// configured is skipped silently (plan §6 M5).
func (s AISettings) Ready() bool {
	return s.Enabled && strings.TrimSpace(s.BaseURL) != "" && strings.TrimSpace(s.Model) != ""
}

// ParseAISettings reads the JSON blob, falling back field by field like the
// Dart parser. A corrupt blob is reported, not guessed at silently.
func ParseAISettings(raw string) (AISettings, error) {
	settings := DefaultAISettings()
	if strings.TrimSpace(raw) == "" {
		return settings, nil
	}
	var stored AISettings
	if err := json.Unmarshal([]byte(raw), &stored); err != nil {
		return settings, fmt.Errorf("metadata: AI settings: %w", err)
	}
	settings.Enabled = stored.Enabled
	if stored.Preset != "" {
		settings.Preset = stored.Preset
	}
	if stored.BaseURL != "" {
		settings.BaseURL = stored.BaseURL
	}
	if stored.Model != "" {
		settings.Model = stored.Model
	}
	settings.APIKey = stored.APIKey
	return settings, nil
}

// Encode renders the blob stored in the Keychain.
func (s AISettings) Encode() (string, error) {
	data, err := json.Marshal(s)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// MaskKey is what a log line or the settings page may show of a key: its last
// four characters at most, never the whole value.
func (s AISettings) MaskKey() string {
	key := strings.TrimSpace(s.APIKey)
	if key == "" {
		return ""
	}
	if len(key) <= 4 {
		return "****"
	}
	return "****" + key[len(key)-4:]
}

// AIInput is one file name handed to the model.
type AIInput struct {
	ID       string `json:"id"`
	Filename string `json:"filename"`
}

// AIResult is the cleaned metadata of one input.
type AIResult struct {
	Title  string
	Artist string
	Album  string
}

// AIClient talks to an OpenAI-compatible /chat/completions endpoint.
type AIClient struct {
	BaseURL string
	Model   string
	APIKey  string
	HTTP    *http.Client
	// Log receives failures; it must never receive the key.
	Log func(format string, args ...any)
}

// NewAIClient returns nil when the settings are not ready, so callers can
// simply skip a nil fallback.
func NewAIClient(settings AISettings, client *http.Client) *AIClient {
	if !settings.Ready() {
		return nil
	}
	if client == nil {
		client = &http.Client{Timeout: 60 * time.Second}
	}
	return &AIClient{BaseURL: settings.BaseURL, Model: settings.Model, APIKey: settings.APIKey, HTTP: client}
}

// aiSystemPrompt asks for a strict JSON array of cleaned names. It is the
// Flutter prompt's contract (title/artist/album, no noise); the wording is
// ours, the fields are the same so results stay comparable.
const aiSystemPrompt = `你是一位资深音乐元数据专家。用户会给出一组含噪声的音频文件名。
请识别每首歌的真实信息：
1. title：官方歌名，去掉 Live、伴奏、前导序号与扩展名；
2. artist：主要歌手，华语歌曲使用常见简体中文；
3. album：正式录音室专辑或官方原声带，无法确定时留空。

只输出合法 JSON 数组，不要 Markdown 代码块之外的任何解释：
[{"id":"1","title":"园游会","artist":"周杰伦","album":"七里香"}]`

// ChatMessage is one message of the request.
type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// Complete sends one chat request and returns the assistant's text.
func (c *AIClient) Complete(ctx context.Context, messages []ChatMessage) (string, error) {
	if c == nil {
		return "", errors.New("metadata: AI client is not configured")
	}
	endpoint := strings.TrimRight(strings.TrimSpace(c.BaseURL), "/") + "/chat/completions"
	payload, err := json.Marshal(map[string]any{
		"model":       c.Model,
		"messages":    messages,
		"temperature": 0.1,
	})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "application/json")
	if key := strings.TrimSpace(c.APIKey); key != "" {
		request.Header.Set("Authorization", "Bearer "+key)
	}
	response, err := c.HTTP.Do(request)
	if err != nil {
		return "", &UpstreamError{Provider: "ai", URL: endpoint, Network: true, Err: err}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBody))
	if err != nil {
		return "", &UpstreamError{Provider: "ai", URL: endpoint, Network: true, Err: err}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", &UpstreamError{Provider: "ai", URL: endpoint, Status: response.StatusCode}
	}
	var decoded struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil || len(decoded.Choices) == 0 {
		return "", &UpstreamError{Provider: "ai", URL: endpoint, Err: errors.New("no choices in the reply")}
	}
	return decoded.Choices[0].Message.Content, nil
}

// CleanFilenames asks the model to repair a batch of file names.
func (c *AIClient) CleanFilenames(ctx context.Context, items []AIInput) (map[string]AIResult, error) {
	if c == nil || len(items) == 0 {
		return nil, nil
	}
	input, err := json.Marshal(items)
	if err != nil {
		return nil, err
	}
	reply, err := c.Complete(ctx, []ChatMessage{
		{Role: "system", Content: aiSystemPrompt},
		{Role: "user", Content: "请清洗并识别以下歌曲文件名：\n" + string(input)},
	})
	if err != nil {
		return nil, err
	}
	return ParseAIReply(reply)
}

// ParseAIReply extracts the JSON array from a model reply (it may wrap it in
// a code fence or add prose) and maps it by input id.
func ParseAIReply(reply string) (map[string]AIResult, error) {
	text := strings.TrimSpace(reply)
	if start := strings.Index(text, "```"); start >= 0 {
		if line := strings.IndexByte(text[start:], '\n'); line >= 0 {
			body := text[start+line+1:]
			if end := strings.LastIndex(body, "```"); end >= 0 {
				text = strings.TrimSpace(body[:end])
			}
		}
	}
	first := strings.IndexByte(text, '[')
	last := strings.LastIndexByte(text, ']')
	if first >= 0 && last > first {
		text = strings.TrimSpace(text[first : last+1])
	}
	var decoded []struct {
		ID     any    `json:"id"`
		Title  string `json:"title"`
		Artist string `json:"artist"`
		Album  string `json:"album"`
	}
	if err := json.Unmarshal([]byte(text), &decoded); err != nil {
		return nil, fmt.Errorf("metadata: AI reply: %w", err)
	}
	out := make(map[string]AIResult, len(decoded))
	for _, entry := range decoded {
		id := strings.TrimSpace(fmt.Sprint(entry.ID))
		title := strings.TrimSpace(entry.Title)
		if id == "" || title == "" {
			continue
		}
		out[id] = AIResult{
			Title:  title,
			Artist: strings.TrimSpace(entry.Artist),
			Album:  strings.TrimSpace(entry.Album),
		}
	}
	return out, nil
}
