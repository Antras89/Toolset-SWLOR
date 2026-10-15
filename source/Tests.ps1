param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
if (Test-Path -LiteralPath $TestRoot) { throw 'TestRoot must be a fresh disposable directory.' }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
. (Join-Path $PSScriptRoot 'Backend.ps1') -LibraryOnly
$script:Git = (Get-Command git.exe -ErrorAction Stop).Source
$script:passed=0
function Check([string]$Name,[scriptblock]$Body) { & $Body; $script:passed++; Write-Host "PASS $Name" }
function Assert($Condition) { if (-not $Condition) { throw 'Assertion failed.' } }
function Reject([scriptblock]$Body) { $failed=$false; try { & $Body } catch { $failed=$true }; Assert $failed }
function G([string]$Repo,[string[]]$A) { Invoke-Native $script:Git (@('-C',$Repo)+$A) }
$settings=Join-Path $TestRoot 'settings.json'
Check 'Create Module Root' { Set-ModuleRoot $settings 'C:\Example\Module'; Assert ((Get-Content $settings -Raw | ConvertFrom-Json).moduleRoot -eq 'C:\Example\Module') }
Check 'Preserve unrelated nested settings' { [IO.File]::WriteAllText($settings,'{"moduleRoot":"old","nested":{"list":[1,true,null,"text"]},"windowWidth":1200}'); Set-ModuleRoot $settings 'new'; $s=Get-Content $settings -Raw | ConvertFrom-Json; Assert ($s.nested.list.Count -eq 4 -and $s.windowWidth -eq 1200) }
Check 'Backup original bytes' { $b=@(Get-ChildItem $TestRoot -Filter 'settings.json.backup-*'); Assert ($b.Count -eq 1); Assert ([IO.File]::ReadAllText($b[0].FullName) -eq '{"moduleRoot":"old","nested":{"list":[1,true,null,"text"]},"windowWidth":1200}') }
Check 'Unchanged root causes no backup' { Set-ModuleRoot $settings 'new'; Assert (@(Get-ChildItem $TestRoot -Filter 'settings.json.backup-*').Count -eq 1) }
Check 'Invalid JSON preserved' { [IO.File]::WriteAllText($settings,'{bad'); Reject { Set-ModuleRoot $settings 'new' }; Assert ([IO.File]::ReadAllText($settings) -eq '{bad') }
Check 'JSON array rejected' { [IO.File]::WriteAllText($settings,'[]'); Reject { Set-ModuleRoot $settings 'new' }; Assert ([IO.File]::ReadAllText($settings) -eq '[]') }
Check 'JSON null rejected' { [IO.File]::WriteAllText($settings,'null'); Reject { Set-ModuleRoot $settings 'new' } }
$file=Join-Path $TestRoot 'payload'; [IO.File]::WriteAllText($file,'hello')
$hash=(Get-FileHash $file -Algorithm SHA256).Hash
Check 'SHA256 accepts correct content' { Assert (Test-Hash $file $hash SHA256) }
Check 'SHA256 rejects changed content' { Assert (-not (Test-Hash $file ('0'*64) SHA256)) }
Check 'SHA512 accepts correct content' { Assert (Test-Hash $file (Get-FileHash $file -Algorithm SHA512).Hash SHA512) }
Check 'Missing digest rejected' { Reject { Test-Hash $file '' SHA256 } }
Check 'Verified cached download reused without network' { $cache=Join-Path $TestRoot 'cache'; [IO.Directory]::CreateDirectory($cache) | Out-Null; $cached=Join-Path $cache ($hash.ToLowerInvariant()+'.zip'); [IO.File]::Copy($file,$cached); Assert ((Get-Verified 'https://example.invalid/offline.zip' $hash SHA256 $cache @('example.invalid')) -eq $cached) }
Check 'HTTPS upstream accepted' { Assert-Url 'https://github.com/a.zip' @('github.com') }
Check 'HTTP rejected' { Reject { Assert-Url 'http://github.com/a.zip' @('github.com') } }
Check 'Lookalike host rejected' { Reject { Assert-Url 'https://github.com.evil.test/a.zip' @('github.com') } }
Check 'Credentials in URL rejected' { Reject { Assert-Url 'https://user@github.com/a.zip' @('github.com') } }
Check 'Native exit failure propagated' { Reject { Invoke-Native $script:Git @('not-a-real-subcommand') } }
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
function Zip([string]$Path,[string]$Entry) { $z=[IO.Compression.ZipFile]::Open($Path,'Create'); try { $e=$z.CreateEntry($Entry); $w=New-Object IO.StreamWriter($e.Open()); $w.Write('payload'); $w.Dispose() } finally { $z.Dispose() } }
Check 'ZIP traversal rejected before extraction' { $z=Join-Path $TestRoot 'bad.zip'; Zip $z '../escaped.txt'; Reject { Expand-SafeZip $z (Join-Path $TestRoot 'bad-out') }; Assert (-not (Test-Path (Join-Path $TestRoot 'escaped.txt'))) }
Check 'ZIP normal extraction' { $z=Join-Path $TestRoot 'ok.zip'; Zip $z 'folder/file.txt'; Expand-SafeZip $z (Join-Path $TestRoot 'ok-out'); Assert (Test-Path (Join-Path $TestRoot 'ok-out\folder\file.txt')) }
Check 'ZIP absolute entry rejected' { $z=Join-Path $TestRoot 'absolute.zip'; Zip $z 'C:/escape.txt'; Reject { Expand-SafeZip $z (Join-Path $TestRoot 'abs-out') } }
Check 'ZIP long path extraction' { $z=Join-Path $TestRoot 'long.zip'; $entry=(('longfolder/'*24)+'file.txt'); Zip $z $entry; Expand-SafeZip $z (Join-Path $TestRoot 'long-out') }
$repo=Join-Path $TestRoot 'repo'; $sub=Join-Path $repo 'SWLOR_Haks'
[IO.Directory]::CreateDirectory($sub) | Out-Null
G $repo @('init'); G $repo @('config','user.email','test@example.invalid'); G $repo @('config','user.name','Launcher Test'); G $repo @('remote','add','origin','https://github.com/zunath/SWLOR_NWN')
G $sub @('init'); G $sub @('config','user.email','test@example.invalid'); G $sub @('config','user.name','Launcher Test')
[IO.File]::WriteAllText((Join-Path $sub 'asset.txt'),'original'); G $sub @('add','.'); G $sub @('commit','-m','fixture')
[IO.File]::WriteAllText((Join-Path $repo '.gitmodules'),"[submodule `"SWLOR_Haks`"]`npath = SWLOR_Haks`nurl = https://github.com/zunath/SWLOR_Haks`n")
G $repo @('add','.gitmodules','SWLOR_Haks'); G $repo @('commit','-m','fixture')
Check 'Official repository origin accepted' { Assert-Repository $repo }
Check 'Different origin refused' { G $repo @('remote','set-url','origin','https://example.invalid/fork'); Reject { Assert-Repository $repo }; G $repo @('remote','set-url','origin','https://github.com/zunath/SWLOR_NWN') }
Check 'Clean pinned submodule accepted' { Assert-Haks $repo }
Check 'Untracked HAK edit refused' { [IO.File]::WriteAllText((Join-Path $sub 'extra.txt'),'local'); Reject { Assert-Haks $repo }; [IO.File]::Delete((Join-Path $sub 'extra.txt')) }
Check 'Tracked HAK edit refused and preserved' { [IO.File]::WriteAllText((Join-Path $sub 'asset.txt'),'edited'); Reject { Assert-Haks $repo }; Assert ([IO.File]::ReadAllText((Join-Path $sub 'asset.txt')) -eq 'edited') }
Check 'Committed submodule revision mismatch refused' { G $sub @('add','.'); G $sub @('commit','-m','local'); Reject { Assert-Haks $repo } }
Check 'Staged gitlink mismatch refused' { G $repo @('add','SWLOR_Haks'); Reject { Assert-Haks $repo } }
Check 'Missing executable refused' { Reject { Start-Toolset (Join-Path $TestRoot 'missing.exe') } }
Write-Host "RESULT: $script:passed tests passed. Test files retained at $TestRoot"
