package main

// This file is the single source of truth for the three design directions the
// redesign document proposes: palettes, type scales, spacing, radii, motion.
// The renderer reads it, and `-tokens` dumps it as JSON so the numbers in
// docs/design/2026-10-26-ui-redesign-directions.md can be checked against the
// code instead of drifting from it.
//
// Nothing here is wired into the app: the M4 tokens stay the app's, and this
// package only draws stills of what each direction would look like if it were
// implemented with the same MyGo primitives the app already uses.

import (
	"time"

	"github.com/egoist/mygo/ui"
)

// TypeStyle is one step of a direction's type scale. Track is letter spacing
// in DIPs (positive opens small text, negative closes display sizes) and
// Height is the line height as a multiple of the size.
type TypeStyle struct {
	Size   float32 `json:"size"`
	Weight int     `json:"weight"`
	Height float32 `json:"height"`
	Track  float32 `json:"track"`
}

// Palette is the semantic colour set of one brightness. Values are opaque
// except the *Alpha ones, which the material and selection faces need.
type Palette struct {
	Dark          bool   `json:"dark"`
	Canvas        string `json:"canvas"`
	Surface       string `json:"surface"`
	SurfaceRaised string `json:"surfaceRaised"`
	SurfaceSunken string `json:"surfaceSunken"`
	Border        string `json:"border"`
	BorderStrong  string `json:"borderStrong"`

	Text     string `json:"text"`
	Text2    string `json:"textSecondary"`
	Text3    string `json:"textTertiary"`
	Disabled string `json:"textDisabled"`

	Accent     string  `json:"accent"`
	AccentSoft string  `json:"accentSoft"`
	OnAccent   string  `json:"onAccent"`
	Success    string  `json:"success"`
	Warning    string  `json:"warning"`
	Danger     string  `json:"danger"`
	Scrim      float32 `json:"scrimAlpha"`

	// GlassTint is the translucent face over a blur; GlassAlpha its alpha,
	// and Blur the blur radius in DIPs (0 means the surface is opaque).
	GlassTint  string  `json:"glassTint"`
	GlassAlpha float32 `json:"glassAlpha"`
	Blur       float32 `json:"blur"`
}

// Color resolves a hex or rgba() string.
func (p Palette) Color(s string) ui.Color { return ui.Hex(s) }

// Motion is one animated relationship of a direction. Response and Damping
// are the SwiftUI-style parameters the document quotes; Steps maps them to
// the MyGo call that plays it (ui.SpringOptions takes the undamped period as
// Duration and 1-damping as Bounce).
type Motion struct {
	Name          string  `json:"name"`
	Response      float32 `json:"response"`  // seconds
	Damping       float32 `json:"damping"`   // 1.0 = no overshoot
	Velocity      float32 `json:"velocity"`  // DIPs/s handed off, 0 = none
	Interrupt     string  `json:"interrupt"` // "yes" / "no" + where it can be grabbed
	ReducedMotion string  `json:"reducedMotion"`
}

// Spring is the MyGo animation of this motion: response as the spring's
// period, damping ratio 1-damping as Bounce.
func (m Motion) Spring() ui.SpringOptions {
	o := ui.SpringOptions{Duration: time.Duration(m.Response * 1000 * float32(time.Millisecond))}
	o.Bounce = float64(1 - m.Damping)
	if m.Velocity != 0 {
		o.Velocity = m.Velocity
	}
	return o
}

// Radii are the corner steps in DIPs.
type Radii struct {
	XS, SM, MD, LG, XL, Pill float32
}

// Metric is fixed geometry: sizes that do not scale with density.
type Metric struct {
	Sidebar     float32
	Row         float32
	Transport   float32
	PagePadding float32
	CoverSmall  float32
	CoverStage  float32
}

// Direction is one complete proposal.
type Direction struct {
	Key      string               `json:"key"`
	Name     string               `json:"name"`
	Position string               `json:"position"` // one line: what it is
	Mood     string               `json:"mood"`     // one line: what it should feel like
	Summary  string               `json:"summary"`
	Light    Palette              `json:"light"`
	Dark     Palette              `json:"dark"`
	Type     map[string]TypeStyle `json:"type"`
	Space    []float32            `json:"space"`
	Radius   Radii                `json:"radius"`
	Metric   Metric               `json:"metric"`
	Motion   []Motion             `json:"motion"`
}

// Directions is the three proposals, in the order the document presents them.
var Directions = []Direction{dirA, dirB, dirC}

// dirA — 声档 1.5「静室」: the current system, corrected. Paper-neutral
// canvas, one crimson accent, a blur sidebar and a full-width transport.
var dirA = Direction{
	Key:      "a",
	Name:     "A · 声档 1.5「静室」",
	Position: "把现有「声档」做对：纸张中性底、单一朱红强调、排版的纪律。",
	Mood:     "安静、专注，像一间整理过的私人书房。",
	Summary:  "保留 12 个页面与全部快捷键，只重做令牌、外壳、列表节奏与材质层次。",
	Light: Palette{
		Canvas:        "#F4F4F1",
		Surface:       "#FCFCFA",
		SurfaceRaised: "#FFFFFF",
		SurfaceSunken: "#ECECE7",
		Border:        "#E1E1DA",
		BorderStrong:  "#CFCFC6",
		Text:          "#17171A",
		Text2:         "#5E5E63",
		Text3:         "#6A6A71",
		Disabled:      "#A9A9AE",
		Accent:        "#B01B2E",
		AccentSoft:    "#B01B2E1F",
		OnAccent:      "#FFFFFF",
		Success:       "#1F6B45",
		Warning:       "#8A5209",
		Danger:        "#A8201A",
		Scrim:         0.38,
		GlassTint:     "#FCFCFA",
		GlassAlpha:    0.72,
		Blur:          24,
	},
	Dark: Palette{
		Dark:          true,
		Canvas:        "#0E0E10",
		Surface:       "#161618",
		SurfaceRaised: "#1C1C20",
		SurfaceSunken: "#101012",
		Border:        "#2B2B31",
		BorderStrong:  "#3B3B43",
		Text:          "#F3F3F5",
		Text2:         "#A0A0A8",
		Text3:         "#7C7C85",
		Disabled:      "#5A5A62",
		Accent:        "#F26D7E",
		AccentSoft:    "#F26D7E26",
		OnAccent:      "#0E0E10",
		Success:       "#5BD98F",
		Warning:       "#E3A85B",
		Danger:        "#FF7066",
		Scrim:         0.56,
		GlassTint:     "#161618",
		GlassAlpha:    0.56,
		Blur:          24,
	},
	Type: map[string]TypeStyle{
		"display":     {40, 700, 1.08, -0.8},
		"h1":          {28, 700, 1.18, -0.4},
		"h2":          {20, 600, 1.28, -0.2},
		"h3":          {15, 600, 1.40, 0},
		"body":        {14, 400, 1.60, 0},
		"small":       {13, 400, 1.55, 0},
		"label":       {12, 500, 1.35, 0.2},
		"caption":     {13, 500, 1.40, 0.05},
		"overline":    {11, 600, 1.25, 0.8},
		"num":         {12, 500, 1.35, 0},
		"numSm":       {11, 500, 1.30, 0.2},
		"lyric":       {15, 400, 1.90, 0},
		"lyricActive": {18, 600, 1.55, -0.1},
	},
	Space:  []float32{4, 8, 12, 16, 20, 24, 32, 40, 56, 72},
	Radius: Radii{XS: 4, SM: 8, MD: 12, LG: 16, XL: 22, Pill: 999},
	Metric: Metric{Sidebar: 236, Row: 44, Transport: 88, PagePadding: 32, CoverSmall: 40, CoverStage: 392},
	Motion: []Motion{
		{Name: "按下反馈（行、按钮）", Response: 0.16, Damping: 1.0, Interrupt: "yes — 松手即反向，从当前缩放值开始", ReducedMotion: "只做 60 ms 颜色变化"},
		{Name: "舞台展开/收起（封面共享元素）", Response: 0.34, Damping: 1.0, Interrupt: "yes — Match 弹簧保留当前速度", ReducedMotion: "120 ms 交叉淡入"},
		{Name: "列表→舞台内容", Response: 0.28, Damping: 1.0, Interrupt: "yes", ReducedMotion: "100 ms 淡入"},
		{Name: "拖动进度", Response: 0.30, Damping: 1.0, Interrupt: "yes — 拖动期间不 seek，松手 seek 一次", ReducedMotion: "同左（拖动本身不是动画）"},
		{Name: "音量拖动", Response: 0.30, Damping: 1.0, Interrupt: "yes", ReducedMotion: "同左"},
		{Name: "甩动翻页（歌词页）", Response: 0.32, Damping: 0.82, Velocity: 0, Interrupt: "yes — 新甩动接管速度", ReducedMotion: "直接切页"},
	},
}

// dirB — 舞台「潮汐」: cover-led. No persistent sidebar; a glass top bar,
// a cover-derived full-bleed stage, and a floating transport.
var dirB = Direction{
	Key:      "b",
	Name:     "B · 舞台「潮汐」",
	Position: "封面是唯一的高饱和；界面其余部分退成光与玻璃，播放页就是舞台。",
	Mood:     "鲜活、有舞台感，像把一张唱片放到灯下。",
	Summary:  "去掉常驻侧栏，改玻璃顶栏 + 封面网格 + 浮动传输条；舞台全幅取色、逐字歌词。",
	Light: Palette{
		Canvas:        "#F5F6F8",
		Surface:       "#FFFFFF",
		SurfaceRaised: "#FFFFFF",
		SurfaceSunken: "#EDEFF3",
		Border:        "#E2E5EA",
		BorderStrong:  "#CDD2DA",
		Text:          "#14161A",
		Text2:         "#5C626C",
		Text3:         "#696F78",
		Disabled:      "#A2A8B1",
		Accent:        "#C92B54",
		AccentSoft:    "#C92B541F",
		OnAccent:      "#FFFFFF",
		Success:       "#1E6B49",
		Warning:       "#8A5209",
		Danger:        "#A8201A",
		Scrim:         0.34,
		GlassTint:     "#FFFFFF",
		GlassAlpha:    0.62,
		Blur:          28,
	},
	Dark: Palette{
		Dark:          true,
		Canvas:        "#0B0D10",
		Surface:       "#14171B",
		SurfaceRaised: "#191D22",
		SurfaceSunken: "#0D0F12",
		Border:        "#262A31",
		BorderStrong:  "#343A43",
		Text:          "#F5F6F8",
		Text2:         "#A7ADB6",
		Text3:         "#7C838C",
		Disabled:      "#565D66",
		Accent:        "#FF6E8A",
		AccentSoft:    "#FF6E8A26",
		OnAccent:      "#0B0D10",
		Success:       "#5BD98F",
		Warning:       "#E3A85B",
		Danger:        "#FF7066",
		Scrim:         0.52,
		GlassTint:     "#14171B",
		GlassAlpha:    0.66,
		Blur:          28,
	},
	Type: map[string]TypeStyle{
		"display":     {56, 700, 1.02, -1.4},
		"h1":          {34, 700, 1.12, -0.9},
		"h2":          {22, 600, 1.24, -0.3},
		"h3":          {16, 600, 1.40, 0},
		"body":        {15, 400, 1.60, 0},
		"small":       {13, 400, 1.50, 0.1},
		"label":       {12, 500, 1.35, 0.2},
		"caption":     {13, 500, 1.35, 0.1},
		"overline":    {11, 600, 1.20, 1.2},
		"num":         {12, 500, 1.30, 0},
		"numSm":       {11, 500, 1.25, 0.2},
		"lyric":       {19, 500, 1.72, 0},
		"lyricActive": {24, 600, 1.40, -0.5},
	},
	Space:  []float32{4, 8, 12, 16, 24, 32, 40, 48, 64, 80},
	Radius: Radii{XS: 6, SM: 10, MD: 16, LG: 22, XL: 28, Pill: 999},
	Metric: Metric{Sidebar: 0, Row: 56, Transport: 72, PagePadding: 48, CoverSmall: 48, CoverStage: 420},
	Motion: []Motion{
		{Name: "按下反馈（传输条按钮）", Response: 0.15, Damping: 1.0, Interrupt: "yes", ReducedMotion: "60 ms 透明度"},
		{Name: "舞台展开（封面共享元素）", Response: 0.42, Damping: 0.88, Interrupt: "yes — 收起可从当前尺寸反抓", ReducedMotion: "160 ms 交叉淡入"},
		{Name: "背景换歌交叉淡入", Response: 0.70, Damping: 1.0, Interrupt: "no — 交叉淡入按播放位置推进，不锁输入", ReducedMotion: "200 ms 交叉淡入"},
		{Name: "列表/网格→舞台", Response: 0.42, Damping: 0.88, Interrupt: "yes", ReducedMotion: "160 ms 淡入"},
		{Name: "拖动进度", Response: 0.30, Damping: 1.0, Interrupt: "yes — 松手一次 seek，时间气泡随拇指", ReducedMotion: "同左"},
		{Name: "音量拖动", Response: 0.30, Damping: 1.0, Interrupt: "yes", ReducedMotion: "同左"},
		{Name: "封面横甩换歌", Response: 0.38, Damping: 0.78, Velocity: 900, Interrupt: "yes — 反向甩动从当前位置接管", ReducedMotion: "只在换歌时淡入"},
	},
}

// dirC — 控制台「灰阶」: dense, keyboard-first, numbers in mono.
var dirC = Direction{
	Key:      "c",
	Name:     "C · 控制台「灰阶」",
	Position: "一台专业播放器：表格密度、等宽数字、右侧检查器，键盘优先。",
	Mood:     "精密、克制，信息密度带来掌控感。",
	Summary:  "侧栏 + 工具栏 + 36 px 行高表格 + 右侧检查器，传输条压到 56 px；动效最短。",
	Light: Palette{
		Canvas:        "#F5F6F7",
		Surface:       "#FFFFFF",
		SurfaceRaised: "#FFFFFF",
		SurfaceSunken: "#EDEFF1",
		Border:        "#DDE1E5",
		BorderStrong:  "#C4CAD1",
		Text:          "#121518",
		Text2:         "#58606A",
		Text3:         "#666D77",
		Disabled:      "#9AA1A9",
		Accent:        "#8A5307",
		AccentSoft:    "#8A530720",
		OnAccent:      "#FFFFFF",
		Success:       "#1C6B45",
		Warning:       "#8A5307",
		Danger:        "#A3201B",
		Scrim:         0.40,
		GlassTint:     "#F5F6F7",
		GlassAlpha:    0.80,
		Blur:          18,
	},
	Dark: Palette{
		Dark:          true,
		Canvas:        "#0F1113",
		Surface:       "#16191C",
		SurfaceRaised: "#1B1F22",
		SurfaceSunken: "#0C0E10",
		Border:        "#282C31",
		BorderStrong:  "#3A3F45",
		Text:          "#EDEFF2",
		Text2:         "#A2A9B2",
		Text3:         "#7A828C",
		Disabled:      "#555C64",
		Accent:        "#E3B56B",
		AccentSoft:    "#E3B56B22",
		OnAccent:      "#0F1113",
		Success:       "#5BD98F",
		Warning:       "#E3B56B",
		Danger:        "#FF7066",
		Scrim:         0.54,
		GlassTint:     "#16191C",
		GlassAlpha:    0.82,
		Blur:          18,
	},
	Type: map[string]TypeStyle{
		"display":     {24, 600, 1.15, -0.3},
		"h1":          {20, 600, 1.20, -0.2},
		"h2":          {14, 600, 1.35, 0},
		"h3":          {12, 600, 1.35, 0.1},
		"body":        {13, 400, 1.45, 0},
		"small":       {12, 400, 1.40, 0},
		"label":       {11, 500, 1.30, 0.2},
		"caption":     {12, 500, 1.35, 0.1},
		"overline":    {10, 600, 1.20, 0.6},
		"num":         {12, 500, 1.30, 0},
		"numSm":       {10, 500, 1.20, 0.2},
		"lyric":       {14, 400, 1.85, 0},
		"lyricActive": {16, 600, 1.60, -0.1},
	},
	Space:  []float32{2, 4, 6, 8, 10, 12, 16, 20, 24, 32},
	Radius: Radii{XS: 2, SM: 4, MD: 6, LG: 8, XL: 10, Pill: 999},
	Metric: Metric{Sidebar: 208, Row: 36, Transport: 56, PagePadding: 20, CoverSmall: 36, CoverStage: 328},
	Motion: []Motion{
		{Name: "按下反馈", Response: 0.10, Damping: 1.0, Interrupt: "yes", ReducedMotion: "无动画，只换色"},
		{Name: "舞台展开（面板）", Response: 0.22, Damping: 1.0, Interrupt: "yes", ReducedMotion: "0 ms，直接显示"},
		{Name: "列表→舞台", Response: 0.16, Damping: 1.0, Interrupt: "yes", ReducedMotion: "120 ms 交叉淡入"},
		{Name: "拖动进度", Response: 0.24, Damping: 1.0, Interrupt: "yes — 松手 seek 一次并对齐 0.5 s", ReducedMotion: "同左"},
		{Name: "音量拖动", Response: 0.24, Damping: 1.0, Interrupt: "yes", ReducedMotion: "同左"},
		{Name: "滚轮翻页", Response: 0, Damping: 0, Interrupt: "系统滚动动量，非弹簧", ReducedMotion: "系统滚动（无动画差）"},
	},
}

// motion finds a direction's motion by name prefix.
func (d Direction) motion(prefix string) Motion {
	for _, m := range d.Motion {
		if len(m.Name) >= len(prefix) && m.Name[:len(prefix)] == prefix {
			return m
		}
	}
	return Motion{}
}
