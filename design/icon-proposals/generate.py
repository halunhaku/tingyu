from pathlib import Path
import json,xml.etree.ElementTree as ET
root=Path(__file__).resolve().parent
g={
'play':'<path d="m9 6 9 6-9 6Z"/>',
'pause':'<rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/>',
'next':'<path d="m5 6 9 6-9 6Z"/><path d="M18 6v12"/>',
'previous':'<path d="m19 6-9 6 9 6Z"/><path d="M6 6v12"/>',
'library':'<rect x="4" y="5" width="5" height="14" rx="1"/><path d="M13 5v14m4-13 3 12"/>',
'album':'<rect x="4" y="4" width="16" height="16" rx="3"/><circle cx="12" cy="12" r="4"/>',
'artist':'<circle cx="12" cy="8" r="3.5"/><path d="M5 20a7 7 0 0 1 14 0"/>',
'playlist':'<path d="M4 6h14M4 11h10M4 16h6m7-3 4 3-4 3Z"/>',
'queue':'<path d="M4 5h16M4 10h12M4 15h8m4 0 4 3-4 3Z"/>',
'heart':'<path d="M12 20 4.5 12.5C-1 7 6 1 12 7c6-6 13 0 7.5 5.5Z"/>',
'search':'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/>',
'folder':'<path d="M3 8V6a2 2 0 0 1 2-2h4l3 3h7a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/>',
'cloud':'<path d="M7 18a4.5 4.5 0 0 1-1-8.9A6 6 0 0 1 17.5 8a5 5 0 0 1 0 10Z"/>',
'webdav':'<rect x="4" y="3" width="16" height="7" rx="2"/><rect x="4" y="14" width="16" height="7" rx="2"/><path d="M8 6.5h.01M8 17.5h.01M15 7h2m-2 10h2"/>',
'sync':'<path d="M5 9a7.5 7.5 0 0 1 13-3l2 2m0-5v5h-5M19 15a7.5 7.5 0 0 1-13 3l-2-2m0 5v-5h5"/>',
'shuffle':'<path d="M4 6h2c4 0 8 12 12 12h2m-4-4 4 4-4 3M4 18h2c1.5 0 3-2 4-4m4-4c1-2 2.5-4 4-4h2m-4-3 4 3-4 4"/>',
'repeat':'<path d="m16 3 4 4-4 4M4 11V9a2 2 0 0 1 2-2h14M8 21l-4-4 4-4m12 0v2a2 2 0 0 1-2 2H4"/>',
'volume':'<path d="M4 9v6h4l5 4V5L8 9Zm13-1a6 6 0 0 1 0 8"/>',
'lyrics':'<path d="M5 5h14M5 10h10M5 15h14M5 20h8"/>',
'settings':'<path d="M5 4v16M12 4v16M19 4v16"/><rect x="3" y="7" width="4" height="4" rx="1" fill="currentColor" stroke="none"/><rect x="10" y="13" width="4" height="4" rx="1" fill="currentColor" stroke="none"/><rect x="17" y="6" width="4" height="4" rx="1" fill="currentColor" stroke="none"/>',
'plus':'<path d="M12 5v14M5 12h14"/>',
'close':'<path d="m6 6 12 12M6 18 18 6"/>',
'check':'<path d="m5 12 4 4L19 6"/>',
'more':'<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
'back':'<path d="m15 6-6 6 6 6"/>',
'forward':'<path d="m9 6 6 6-6 6"/>',
'up':'<path d="m6 15 6-6 6 6"/>',
'down':'<path d="m6 9 6 6 6-6"/>',
'external':'<path d="M14 4h6v6m0-6L10 14m0-10H5a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-5"/>',
'info':'<circle cx="12" cy="12" r="8"/><path d="M12 11v6m0-10h.01"/>',
'music':'<path d="M10 17V6l9-2v11M10 9l9-2"/><ellipse cx="7" cy="17" rx="3" ry="2.5"/><ellipse cx="16" cy="15" rx="3" ry="2.5"/>',
'recent':'<circle cx="12" cy="12" r="8"/><path d="M12 7v5l3 2"/>'}
# Optical system: 24 grid, 18–20 content, rounded 1.8 stroke. Variants share controls deliberately.
marks=[
'<path d="M9 15V6l9-2v9M9 9l9-2"/><ellipse cx="6.5" cy="15" rx="2.5" ry="2"/><ellipse cx="15.5" cy="13" rx="2.5" ry="2"/><path d="M4 20q4 4 8 0t8 0"/>',
'<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="3"/><path d="M7 12a5 5 0 0 1 5-5m5 5a5 5 0 0 1-5 5"/>',
'<rect x="4" y="4" width="16" height="16" rx="3"/><path d="M4 9h16m-10 3 5 3-5 3Z"/>'
]
variants=[('a-sound-island','A / 声屿','#B01B2E','#F26D7E','音符 × 岛屿 · 延续品牌'),('b-resonance','B / 涟漪','#286258','#86CDBA','唱片 × 声波 · 沉浸聆听'),('c-sound-archive','C / 声档','#485A9C','#ADBBF3','档案 × 播放 · 私人曲库')]
def svg(body,size=24,color='currentColor'):
 return f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" color="{color}" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">{body}</svg>'
def tile(i):
 colors=[('#FF9AA7','#DB354F'),('#9DDBCD','#245E58'),('#BCC9F7','#4A5B9C')][i]
 return f'<defs><linearGradient id="tile" x2="1" y2="1"><stop stop-color="{colors[0]}"/><stop offset="1" stop-color="{colors[1]}"/></linearGradient></defs><rect x="1" y="1" width="22" height="22" rx="5" fill="url(#tile)" stroke="none"/><g transform="translate(3 3) scale(.75)" color="#17171A">{marks[i]}</g>'
for i,(folder,title,light,dark,desc) in enumerate(variants):
 p=root/folder;p.mkdir(exist_ok=True)
 assets=dict(g);assets['brand']=marks[i]
 if i==1:
  assets['library']='<path d="M4 5h3v14H4m7-14h3v14h-3m7-13 3 12"/>'
  assets['album']='<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="2.5"/>'
 if i==2:
  assets['library']='<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M4 10h16m-10 5h4"/>'
  assets['album']='<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M8 4v16"/><circle cx="14" cy="12" r="3"/>'
 for name,body in assets.items(): (p/f'{name}.svg').write_text(svg(body))
 (p/'heart-filled.svg').write_text(svg('<g fill="currentColor" stroke="none">'+g['heart']+'</g>'))
 (p/'app-icon.svg').write_text(svg(tile(i),1024))
 for theme,color in [('light',light),('dark',dark)]: (p/f'brand-{theme}.svg').write_text(svg(marks[i],24,color))
# SVG review sheet: actual pixel sizes + larger visual identity comparison.
out=['<svg xmlns="http://www.w3.org/2000/svg" width="1440" height="1440" viewBox="0 0 1440 1440">','<rect width="1440" height="1440" fill="#ECECE8"/>']
def txt(x,y,t,size=14,color='#17171A',weight=400):out.append(f'<text x="{x}" y="{y}" font-family="Helvetica Neue, PingFang SC, sans-serif" font-size="{size}" font-weight="{weight}" fill="{color}">{t}</text>')
def embed(body,x,y,s,color):out.append(f'<svg x="{x}" y="{y}" width="{s}" height="{s}" viewBox="0 0 24 24" fill="none" color="{color}" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">{body}</svg>')
txt(48,60,'听屿 / TINGYU',30,weight=650);txt(48,91,'ICON STUDIES     /     03 DIRECTIONS     /     SVG FIRST',12,color='#65656D');txt(1050,60,'DESIGN REVIEW · 2026.10',14)
for i,(folder,title,light,dark,desc) in enumerate(variants):
 x=36+i*468
 out.append(f'<rect x="{x}" y="124" width="444" height="978" rx="20" fill="#FAFAF8"/>')
 txt(x+24,166,title,24,weight=650);txt(x+24,195,desc,14,color='#66666E')
 embed(tile(i),x+138,225,168,'#17171A')
 for j,(bg,fg,accent,label) in enumerate([('#F4F4F1','#17171A',light,'LIGHT'),('#0E0E10','#F3F3F5',dark,'DARK')]):
  y=424+j*232
  out.append(f'<rect x="{x+16}" y="{y}" width="412" height="214" rx="12" fill="{bg}"/>')
  txt(x+32,y+28,label,11,accent,600)
  for k,s in enumerate([16,24,32]):
   xx=x+45+k*122
   embed(marks[i],xx,y+54,s,accent);txt(xx,y+111,f'{s}px',12,fg)
  names=['library','album','artist','heart','folder','cloud','play','pause','search','queue','lyrics','settings']
  for k,n in enumerate(names):
   body=(root/folder/f'{n}.svg').read_text().split('stroke-linejoin="round">')[1][:-6]
   embed(body,x+33+(k%6)*66,y+133+(k//6)*40,24,fg)
 txt(x+24,930,'OPTICAL SIZE / 1×',11,color='#66666E',weight=600)
 for row,s in enumerate([16,24,32]):
  txt(x+24,966+row*46,str(s),11,color='#66666E')
  for k,n in enumerate(['play','heart','search','folder','sync','settings']):embed(g[n],x+68+k*55,945+row*46,s,'#17171A')
 txt(x+24,1081,'24u grid · 1.8u stroke · round cap / join',11,color='#66666E')
out.append('</svg>');(root/'preview.svg').write_text(''.join(out))
html='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>听屿 · 图标方案</title><style>body{margin:0;background:#ecece8;font:14px system-ui}header{padding:20px 32px}img.board{width:100%;max-width:1440px}section{padding:24px;display:flex;flex-wrap:wrap;gap:12px}.cell{width:112px;padding:12px;background:white;border-radius:8px;text-align:center}.cell img{width:24px;height:24px;display:block;margin:8px auto}</style><header>听屿 · 图标提案 / 原尺寸预览请将浏览器缩放设为 100%。SVG 使用 currentColor；下方文件预览默认黑色。</header><img class="board" src="preview.svg">'''
for folder,title,*_ in variants:
 html+=f'<header><h2>{title}</h2></header><section>'
 for p in sorted((root/folder).glob('*.svg')):html+=f'<div class="cell"><img src="{folder}/{p.name}">{p.stem}</div>'
 html+='</section>'
(root/'preview.html').write_text(html+'</html>')
files=list(root.rglob('*.svg'))
for p in files:ET.parse(p)
(root/'manifest.json').write_text(json.dumps({'grid':24,'strokeWidth':1.8,'sizes':[16,24,32],'variants':[v[0] for v in variants],'svgCount':len(files),'existingAssetsReplaced':False},indent=2))
print(f'Generated and XML-validated {len(files)} SVG files')
