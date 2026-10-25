param(
  [Parameter(Mandatory=$true)][string]$InputDirectory,
  [Parameter(Mandatory=$true)][string]$OutputPath,
  [string[]]$Names,
  [int]$Columns = 3,
  [int]$TileWidth = 560,
  [int]$TileHeight = 340,
  [int]$LabelHeight = 22
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $Names -or $Names.Count -eq 0) {
  $Names = Get-ChildItem -LiteralPath $InputDirectory -Filter '*.png' |
    Sort-Object Name | ForEach-Object { $_.BaseName }
}

$rows = [Math]::Ceiling($Names.Count / $Columns)
$sheet = [Drawing.Bitmap]::new(
  $Columns * $TileWidth,
  $rows * ($TileHeight + $LabelHeight)
)
$graphics = [Drawing.Graphics]::FromImage($sheet)
$font = [Drawing.Font]::new('Microsoft YaHei', 11)
$brush = [Drawing.Brushes]::Black
$pen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(200, 200, 200), 1)
try {
  $graphics.Clear([Drawing.Color]::White)
  $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  for ($i = 0; $i -lt $Names.Count; $i++) {
    $name = $Names[$i]
    $path = Join-Path $InputDirectory "$name.png"
    if (-not (Test-Path -LiteralPath $path)) { throw "缺少截图：$path" }
    $column = $i % $Columns
    $row = [Math]::Floor($i / $Columns)
    $x = $column * $TileWidth
    $y = $row * ($TileHeight + $LabelHeight)
    $image = [Drawing.Image]::FromFile($path)
    try {
      # 等比缩放到瓦片内（留 4px 边距），左上对齐，避免拉伸变形。
      $scale = [Math]::Min(
        ($TileWidth - 8) / $image.Width,
        ($TileHeight - 8) / $image.Height
      )
      $w = [int]($image.Width * $scale)
      $h = [int]($image.Height * $scale)
      $graphics.DrawImage($image, $x + 4, $y + 4, $w, $h)
      $graphics.DrawRectangle($pen, $x + 3, $y + 3, $w + 2, $h + 2)
    } finally { $image.Dispose() }
    $graphics.DrawString($name, $font, $brush, $x + 4, $y + $TileHeight + 2)
  }
  $sheet.Save($OutputPath, [Drawing.Imaging.ImageFormat]::Png)
} finally {
  $pen.Dispose(); $font.Dispose(); $graphics.Dispose(); $sheet.Dispose()
}
Write-Host "contact sheet: $OutputPath ($($Names.Count) tiles)"
