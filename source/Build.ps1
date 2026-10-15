param([string]$Output = (Join-Path $PSScriptRoot '..\SWLOR-Launcher.exe'))
$ErrorActionPreference='Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $compiler)) { throw 'Windows x64 .NET Framework compiler not found.' }
$release=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full').Release
if ($release -lt 528040) { throw '.NET Framework 4.8 or later is required.' }
& $compiler /nologo /target:winexe /platform:x64 /optimize+ "/out:$Output" /reference:System.Web.Extensions.dll /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll "/win32manifest:$PSScriptRoot\App.manifest" "/resource:$PSScriptRoot\Backend.ps1,Backend.ps1" "/resource:$PSScriptRoot\GitBackend.ps1,GitBackend.ps1" "$PSScriptRoot\GitPanel.cs" "$PSScriptRoot\Launcher.cs"
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
Write-Host "Built $Output"
