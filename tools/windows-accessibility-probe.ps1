param([Parameter(Mandatory=$true)][int]$AppProcessId,
      [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName Accessibility
Add-Type -ReferencedAssemblies Accessibility, System.Collections, System.Runtime -IgnoreWarnings -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Accessibility;
public static class TingyuAccessibilityProbe {
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr window, uint command);
  [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr window, uint id, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object accessible);
  [DllImport("oleacc.dll")] static extern int AccessibleChildren(IAccessible accessible, int start, int count, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex=2)] object[] children, out int obtained);
  public static string[] Read(IntPtr window) {
    var iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
    object accessible;
    int result = AccessibleObjectFromWindow(window, unchecked((uint)-4), ref iid, out accessible);
    if(result != 0) Marshal.ThrowExceptionForHR(result);
    var lines = new List<string>();
    Visit((IAccessible)accessible, lines, 0);
    return lines.ToArray();
  }
  static void Visit(IAccessible accessible, List<string> lines, int depth) {
    if(depth > 30 || lines.Count > 2000) return;
    lines.Add(new string(' ',depth*2) + "role=" + accessible.get_accRole(0) + " name=" + accessible.get_accName(0));
    int count = accessible.accChildCount;
    if(count <= 0) return;
    var children = new object[count];
    int obtained;
    Marshal.ThrowExceptionForHR(AccessibleChildren(accessible,0,count,children,out obtained));
    for(int i=0;i<obtained;i++) {
      var child = children[i] as IAccessible;
      if(child != null) Visit(child,lines,depth+1);
      else if(children[i] is int) lines.Add(new string(' ',(depth+1)*2) + "role=" + accessible.get_accRole(children[i]) + " name=" + accessible.get_accName(children[i]));
    }
  }
}
'@
$process = Get-Process -Id $AppProcessId
$child = [TingyuAccessibilityProbe]::GetWindow($process.MainWindowHandle,5)
if ($child -eq [IntPtr]::Zero) { throw 'Flutter window not found' }
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$lines = [TingyuAccessibilityProbe]::Read($child)
$lines | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'msaa-tree.txt')
$result = [ordered]@{ processId=$AppProcessId; nodes=$lines.Count; namedNodes=@($lines | Where-Object { $_ -match 'name=\S' }).Count }
$result | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $OutputDirectory 'msaa-result.json')
$result | ConvertTo-Json
if ($result.namedNodes -lt 4) { throw 'Application controls are missing from MSAA tree' }
