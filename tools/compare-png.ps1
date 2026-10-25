param(
  [Parameter(Mandatory=$true)][string]$ApprovedPath,
  [Parameter(Mandatory=$true)][string]$ActualPath,
  [Parameter(Mandatory=$true)][string]$DiffPath,
  [Parameter(Mandatory=$true)][string]$OutputJson
)
$ErrorActionPreference = 'Stop'

$approved = [IO.Path]::GetFullPath($ApprovedPath)
$actual = [IO.Path]::GetFullPath($ActualPath)
$diff = [IO.Path]::GetFullPath($DiffPath)
$output = [IO.Path]::GetFullPath($OutputJson)
foreach ($path in @($approved, $actual)) {
  if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "PNG not found: $path"
  }
}
New-Item -ItemType Directory -Force -Path (Split-Path $diff -Parent) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $output -Parent) | Out-Null

$references = @(
  Join-Path $PSHOME 'System.Drawing.Common.dll'
  Join-Path $PSHOME 'System.Drawing.Primitives.dll'
  Join-Path $PSHOME 'System.Private.Windows.Core.dll'
  Join-Path $PSHOME 'System.Private.Windows.GdiPlus.dll'
)
foreach ($reference in $references) {
  if (!(Test-Path -LiteralPath $reference -PathType Leaf)) {
    throw "Required .NET drawing assembly not found: $reference"
  }
}

Add-Type -ReferencedAssemblies $references -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public sealed class TingyuImageDiffResult
{
    public bool sameDimensions;
    public bool pixelExact;
    public int approvedWidth;
    public int approvedHeight;
    public int actualWidth;
    public int actualHeight;
    public long totalPixels;
    public long differingPixels;
    public double differingPercent;
    public int maxChannelDelta;
    public double meanAbsoluteDelta;
    public bool hasDifferenceBounds;
    public int boundsLeft;
    public int boundsTop;
    public int boundsRight;
    public int boundsBottom;
}

public static class TingyuPngComparer
{
    public static TingyuImageDiffResult Compare(string approvedPath, string actualPath, string diffPath)
    {
        using (var approvedSource = new Bitmap(approvedPath))
        using (var actualSource = new Bitmap(actualPath))
        {
            var result = new TingyuImageDiffResult
            {
                approvedWidth = approvedSource.Width,
                approvedHeight = approvedSource.Height,
                actualWidth = actualSource.Width,
                actualHeight = actualSource.Height,
                sameDimensions =
                    approvedSource.Width == actualSource.Width &&
                    approvedSource.Height == actualSource.Height
            };

            if (!result.sameDimensions)
            {
                int width = Math.Max(approvedSource.Width, actualSource.Width);
                int height = Math.Max(approvedSource.Height, actualSource.Height);
                using (var mask = new Bitmap(width, height, PixelFormat.Format32bppArgb))
                using (var graphics = Graphics.FromImage(mask))
                {
                    graphics.Clear(Color.Red);
                    mask.Save(diffPath, ImageFormat.Png);
                }
                result.totalPixels = (long)width * height;
                result.differingPixels = result.totalPixels;
                result.differingPercent = 100.0;
                result.maxChannelDelta = 255;
                result.meanAbsoluteDelta = 255.0;
                result.hasDifferenceBounds = width > 0 && height > 0;
                result.boundsLeft = 0;
                result.boundsTop = 0;
                result.boundsRight = Math.Max(0, width - 1);
                result.boundsBottom = Math.Max(0, height - 1);
                return result;
            }

            int pixelWidth = approvedSource.Width;
            int pixelHeight = approvedSource.Height;
            using (var diffBitmap = new Bitmap(pixelWidth, pixelHeight, PixelFormat.Format32bppArgb))
            using (var diffGraphics = Graphics.FromImage(diffBitmap))
            {
                diffGraphics.Clear(Color.White);
                int minX = int.MaxValue;
                int minY = int.MaxValue;
                int maxX = -1;
                int maxY = -1;
                long channelSum = 0;
                result.totalPixels = (long)pixelWidth * pixelHeight;

                for (int y = 0; y < pixelHeight; y++)
                {
                    for (int x = 0; x < pixelWidth; x++)
                    {
                        Color approvedColor = approvedSource.GetPixel(x, y);
                        Color actualColor = actualSource.GetPixel(x, y);
                        int b = Math.Abs(approvedColor.B - actualColor.B);
                        int g = Math.Abs(approvedColor.G - actualColor.G);
                        int r = Math.Abs(approvedColor.R - actualColor.R);
                        int a = Math.Abs(approvedColor.A - actualColor.A);
                        int channelMax = Math.Max(Math.Max(b, g), Math.Max(r, a));
                        channelSum += b + g + r + a;
                        if (channelMax > result.maxChannelDelta)
                        {
                            result.maxChannelDelta = channelMax;
                        }
                        if (channelMax == 0)
                        {
                            continue;
                        }

                        result.differingPixels++;
                        minX = Math.Min(minX, x);
                        minY = Math.Min(minY, y);
                        maxX = Math.Max(maxX, x);
                        maxY = Math.Max(maxY, y);
                        diffBitmap.SetPixel(x, y, Color.Red);
                    }
                }

                diffBitmap.Save(diffPath, ImageFormat.Png);

                result.pixelExact = result.differingPixels == 0;
                result.differingPercent = result.totalPixels == 0
                    ? 0
                    : result.differingPixels * 100.0 / result.totalPixels;
                result.meanAbsoluteDelta = result.totalPixels == 0
                    ? 0
                    : (double)channelSum / (result.totalPixels * 4.0);
                result.hasDifferenceBounds = result.differingPixels > 0;
                if (result.hasDifferenceBounds)
                {
                    result.boundsLeft = minX;
                    result.boundsTop = minY;
                    result.boundsRight = maxX;
                    result.boundsBottom = maxY;
                }
                return result;
            }
        }
    }
}
'@

$result = [TingyuPngComparer]::Compare($approved, $actual, $diff)
$approvedHash = (Get-FileHash -LiteralPath $approved -Algorithm SHA256).Hash.ToLowerInvariant()
$actualHash = (Get-FileHash -LiteralPath $actual -Algorithm SHA256).Hash.ToLowerInvariant()
$report = [ordered]@{
  schemaVersion = 1
  approvedPath = $approved
  actualPath = $actual
  diffPath = $diff
  approvedSha256 = $approvedHash
  actualSha256 = $actualHash
  byteExact = $approvedHash -eq $actualHash
  sameDimensions = $result.sameDimensions
  pixelExact = $result.pixelExact
  approvedWidth = $result.approvedWidth
  approvedHeight = $result.approvedHeight
  actualWidth = $result.actualWidth
  actualHeight = $result.actualHeight
  totalPixels = $result.totalPixels
  differingPixels = $result.differingPixels
  differingPercent = $result.differingPercent
  maxChannelDelta = $result.maxChannelDelta
  meanAbsoluteDelta = $result.meanAbsoluteDelta
  hasDifferenceBounds = $result.hasDifferenceBounds
  differenceBounds = if ($result.hasDifferenceBounds) {
    [ordered]@{
      left = $result.boundsLeft
      top = $result.boundsTop
      right = $result.boundsRight
      bottom = $result.boundsBottom
      width = $result.boundsRight - $result.boundsLeft + 1
      height = $result.boundsBottom - $result.boundsTop + 1
    }
  } else {
    $null
  }
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $output
if (!$result.sameDimensions -or !$result.pixelExact) {
  Write-Error (
    "Visual mismatch: $($result.differingPixels) pixels " +
    "($($result.differingPercent.ToString('F6', [Globalization.CultureInfo]::InvariantCulture))%)."
  )
  exit 1
}
exit 0
