param([ValidateSet('Install','Launch','Rebuild','Check','Update')][string]$Action = 'Install', [string]$InstallParent, [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Log([string]$Text) { Write-Host $Text }
function Stage([int]$Percent, [string]$Text) { Write-Log "PROGRESS|$Percent|$Text" }
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw "$Exe failed (exit $code). See the preceding log messages." }
}
function Git-Text([string]$Repo, [string[]]$Arguments) {
    $result = & $script:Git -C $Repo @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Git check failed: $result" }
    return (($result | ForEach-Object { "$_" }) -join "`n").Trim()
}
function Assert-Url([string]$Url, [string[]]$Hosts) {
    $u = [uri]$Url
    if (-not $u.IsAbsoluteUri -or $u.Scheme -ne 'https' -or $u.UserInfo -or $u.Port -ne 443 -or $Hosts -notcontains $u.Host) { throw "Untrusted download URL: $Url" }
}
function Test-Hash([string]$Path, [string]$Hash, [string]$Algorithm) {
    $length = if ($Algorithm -eq 'SHA512') {128} elseif ($Algorithm -eq 'SHA256') {64} else {throw 'Unsupported checksum algorithm.'}
    if ($Hash -notmatch "^[a-fA-F0-9]{$length}$") { throw 'Missing or invalid upstream checksum.' }
    return ((Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash -eq $Hash)
}
function Get-Verified([string]$Url, [string]$Hash, [string]$Algorithm, [string]$Cache, [string[]]$Hosts) {
    Assert-Url $Url $Hosts
    [void](Test-Hash (Join-Path $Cache 'missing') $Hash $Algorithm)
    [IO.Directory]::CreateDirectory($Cache) | Out-Null
    $path = Join-Path $Cache ($Hash.ToLowerInvariant() + '.zip')
    if (Test-Hash $path $Hash $Algorithm) { Write-Log 'Reusing verified download.'; return $path }
    $part = $path + '.partial'
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = 'SWLOR-Launcher/1.0'
    $request.Timeout = 60000
    $response = $request.GetResponse()
    try {
        $input = $response.GetResponseStream()
        $output = [IO.File]::Create($part)
        try {
            $buffer = New-Object byte[] 1048576; $total = 0L; $last = -10L
            while (($n = $input.Read($buffer,0,$buffer.Length)) -gt 0) {
                $output.Write($buffer,0,$n); $total += $n
                $mb = [long]($total / 1MB)
                if ($mb -ge $last + 10) { Write-Log "Downloaded $mb MB"; $last = $mb }
            }
        } finally { $output.Dispose(); $input.Dispose() }
    } finally { $response.Dispose() }
    if (-not (Test-Hash $part $Hash $Algorithm)) { throw 'Downloaded file checksum mismatch. File will not be used.' }
    Move-Item -LiteralPath $part -Destination $path -Force
    return $path
}
function Expand-SafeZip([string]$Zip, [string]$Destination) {
    if (-not ('LauncherZip' -as [type])) {
        Add-Type -ReferencedAssemblies System.IO.Compression,System.IO.Compression.FileSystem -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
public static class LauncherZip {
 static string Long(string p) { return p.StartsWith(@"\\") ? @"\\?\UNC\"+p.Substring(2) : @"\\?\"+p; }
 public static void Extract(string zip, string dest) {
  string root=Path.GetFullPath(dest).TrimEnd('\\')+"\\";
  using(var a=ZipFile.OpenRead(zip)) {
   foreach(var e in a.Entries) {
    string n=e.FullName.Replace('/','\\');
    if(n.StartsWith("\\") || n.Contains(":")) throw new InvalidDataException("Unsafe ZIP entry");
    string p=Path.GetFullPath(root+n);
    if(!p.StartsWith(root,StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("ZIP traversal rejected");
   }
   Directory.CreateDirectory(Long(root));
   foreach(var e in a.Entries) {
    string p=Path.GetFullPath(root+e.FullName.Replace('/','\\'));
    if(e.Name.Length==0) { Directory.CreateDirectory(Long(p)); continue; }
    Directory.CreateDirectory(Long(Path.GetDirectoryName(p)));
    using(var s=e.Open()) using(var d=new FileStream(Long(p),FileMode.CreateNew)) s.CopyTo(d);
   }
  }
 }
}
'@
    }
    [LauncherZip]::Extract($Zip,$Destination)
}
function Get-Json([string]$Url) { Invoke-RestMethod -Uri $Url -Headers @{'User-Agent'='SWLOR-Launcher/1.0'} }
function Ensure-Git([string]$Tools) {
    $existing = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($existing) { Invoke-Native $existing.Source @('--version'); return $existing.Source }
    $receipt = Join-Path $Tools 'git-path.txt'
    if (Test-Path -LiteralPath $receipt) {
        $candidate = [IO.File]::ReadAllText($receipt).Trim()
        if (Test-Path -LiteralPath $candidate) { Invoke-Native $candidate @('--version'); return $candidate }
    }
    $release = Get-Json 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $asset = @($release.assets | Where-Object { $_.name -match '^MinGit-[0-9.]+-64-bit.zip$' })
    if ($asset.Count -ne 1 -or $asset[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'Portable Git metadata does not contain one x64 ZIP with a SHA256 digest.' }
    $zip = Get-Verified $asset[0].browser_download_url $Matches[1] 'SHA256' (Join-Path $Tools 'downloads') @('github.com')
    $dest = Join-Path $Tools ('git-' + [guid]::NewGuid().ToString('N'))
    Expand-SafeZip $zip $dest
    $exe = Join-Path $dest 'cmd\git.exe'
    Invoke-Native $exe @('--version')
    [IO.File]::WriteAllText($receipt,$exe)
    return $exe
}
function Ensure-Sdk([string]$Tools, [switch]$Offline) {
    $receipt = Join-Path $Tools 'sdk-path.txt'
    if (Test-Path -LiteralPath $receipt) {
        $candidate = [IO.File]::ReadAllText($receipt).Trim()
        if (Test-Path -LiteralPath (Join-Path $candidate 'dotnet.exe')) { return $candidate }
    }
    if ($Offline) { throw 'Private SDK missing. Use Install and launch first.' }
    $meta = Get-Json 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
    $sdk = @($meta.releases | ForEach-Object { $_.sdks } | Where-Object { $_.version -eq $meta.'latest-sdk' })[0]
    $file = @($sdk.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -match '\.zip$' })
    if ($file.Count -ne 1) { throw 'Microsoft metadata did not provide one Windows x64 SDK ZIP.' }
    $zip = Get-Verified $file[0].url $file[0].hash 'SHA512' (Join-Path $Tools 'downloads') @('builds.dotnet.microsoft.com','download.visualstudio.microsoft.com','dotnetcli.azureedge.net')
    $dest = Join-Path $Tools ('sdk-' + $sdk.version + '-' + [guid]::NewGuid().ToString('N'))
    Expand-SafeZip $zip $dest
    Invoke-Native (Join-Path $dest 'dotnet.exe') @('--list-sdks')
    [IO.File]::WriteAllText($receipt,$dest)
    return $dest
}
function Assert-Repository([string]$Repo) {
    $top = Git-Text $Repo @('rev-parse','--show-toplevel')
    if ([IO.Path]::GetFullPath($top).TrimEnd('\') -ne [IO.Path]::GetFullPath($Repo).TrimEnd('\')) { throw 'Selected folder is not the repository root.' }
    $origin = Git-Text $Repo @('remote','get-url','origin')
    if ($origin -cnotmatch '^https://github\.com/zunath/SWLOR_NWN(?:\.git)?$') { throw 'Repository origin must be the official SWLOR_NWN HTTPS URL.' }
}
function Assert-Haks([string]$Repo, [switch]$Initialize) {
    # Refuse changed gitlinks and edited submodule definitions before any update.
    foreach ($argsList in @(@('diff','--quiet','HEAD','--','.gitmodules','SWLOR_Haks'), @('diff','--cached','--quiet','--','.gitmodules','SWLOR_Haks'))) {
        & $script:Git -C $Repo @argsList
        if ($LASTEXITCODE -ne 0) { throw 'Local submodule edits or revision mismatch detected. Resolve manually; nothing was switched.' }
    }
    $url = Git-Text $Repo @('config','-f','.gitmodules','--get','submodule.SWLOR_Haks.url')
    $path = Git-Text $Repo @('config','-f','.gitmodules','--get','submodule.SWLOR_Haks.path')
    if ($url -cnotmatch '^https://github\.com/zunath/SWLOR_Haks(?:\.git)?$' -or $path -cne 'SWLOR_Haks') { throw 'Unexpected HAK submodule definition.' }
    $tree = Git-Text $Repo @('ls-tree','HEAD','--','SWLOR_Haks')
    if ($tree -notmatch '^160000 commit ([a-f0-9]{40})\s+SWLOR_Haks$') { throw 'Missing pinned HAK gitlink.' }
    $pin = $Matches[1]; $sub = Join-Path $Repo 'SWLOR_Haks'
    if (Test-Path -LiteralPath (Join-Path $sub '.git')) {
        $head = Git-Text $sub @('rev-parse','HEAD')
        $dirty = Git-Text $sub @('status','--porcelain','--untracked-files=all')
        if ($head -ne $pin -or $dirty) { throw 'HAK edits or revision mismatch detected. Resolve manually; nothing was switched.' }
        return
    }
    if ((Test-Path -LiteralPath $sub) -and @(Get-ChildItem -LiteralPath $sub -Force).Count -gt 0) { throw 'Uninitialized HAK folder is not empty. Resolve manually.' }
    if (-not $Initialize) { throw 'HAK submodule missing. Use Install and launch.' }
    Invoke-Native $script:Git @('-C',$Repo,'-c','core.longpaths=true','-c','submodule.SWLOR_Haks.url=https://github.com/zunath/SWLOR_Haks','submodule','update','--init','--depth','1','--','SWLOR_Haks')
    Assert-Haks $Repo
}
function Get-Pin([string]$Repo, [string]$Revision) {
    $tree = Git-Text $Repo @('ls-tree',$Revision,'--','SWLOR_Haks')
    if ($tree -notmatch '^160000 commit ([a-f0-9]{40})\s+SWLOR_Haks$') { throw 'Missing pinned HAK revision.' }
    return $Matches[1]
}
function Assert-UpdateClean([string]$Repo) {
    if ((Git-Text $Repo @('ls-files','-v')) -cmatch '(?m)^[a-zS] ') { throw 'Update refused: sparse checkout or assume-unchanged files require manual review.' }
    $dirty = Git-Text $Repo @('status','--porcelain','--untracked-files=all','--ignore-submodules=all')
    if ($dirty) { Write-Log $dirty; throw 'Update stopped: local files or saved areas have changes. Back up and resolve them manually, or install in a new folder. Nothing was discarded.' }
    Invoke-Native $script:Git @('-C',$Repo,'diff','--cached','--quiet','HEAD','--','SWLOR_Haks')
    foreach ($name in @('MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','rebase-merge','rebase-apply','BISECT_LOG')) {
        $p = Git-Text $Repo @('rev-parse','--git-path',$name)
        if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Repo $p }
        if (Test-Path -LiteralPath $p) { throw 'Finish the existing Git operation before updating.' }
    }
    $sub = Join-Path $Repo 'SWLOR_Haks'
    if (-not (Test-Path -LiteralPath (Join-Path $sub '.git'))) { throw 'Initialize HAK assets with Install and launch first.' }
    if ((Git-Text $sub @('ls-files','-v')) -cmatch '(?m)^[a-zS] ') { throw 'Update refused: hidden HAK file changes require manual review.' }
    if (Git-Text $sub @('status','--porcelain','--untracked-files=all')) { throw 'Update stopped: local HAK edits detected.' }
}
function Get-UpdateTarget([string]$Repo) {
    Assert-Repository $Repo
    $remote = Git-Text $Repo @('ls-remote','--symref','origin','HEAD')
    if ($remote -notmatch '(?m)^ref: refs/heads/([^\s]+)\s+HEAD$') { throw 'Unable to identify the upstream default branch.' }
    $branch = $Matches[1]
    Invoke-Native $script:Git @('-C',$Repo,'fetch','--no-tags','--no-recurse-submodules','origin',("refs/heads/{0}:refs/remotes/origin/{0}" -f $branch))
    $target = Git-Text $Repo @('rev-parse',("refs/remotes/origin/{0}" -f $branch))
    $head = Git-Text $Repo @('rev-parse','HEAD')
    Write-Log "Upstream branch: $branch"
    Write-Log "Installed revision: $head"
    Write-Log "Available revision: $target"
    if ($head -eq $target) { Stage 100 'Already up to date.' }
    else {
        Write-Log (Git-Text $Repo @('log','--oneline','-10',("HEAD..{0}" -f $target)))
        & $script:Git -C $Repo merge-base --is-ancestor HEAD $target
        if ($LASTEXITCODE -eq 0) { Stage 100 'Updates available. Use Update and launch.' }
        elseif ($LASTEXITCODE -eq 1) { Stage 100 'Local history differs. Automatic update is blocked.' }
        else { throw 'Unable to compare repository history.' }
    }
    return @{ Branch=$branch; Target=$target }
}
function Get-UpdateJournal([string]$Repo) {
    $p = Git-Text $Repo @('rev-parse','--git-path','swlor-launcher-update.json')
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Repo $p }
    return $p
}
function Assert-UpdatePlan([string]$Repo, $Plan) {
    Assert-Repository $Repo
    foreach ($key in @('Old','New')) { if ($Plan.$key -notmatch '^[a-f0-9]{40}$') { throw 'Invalid update journal revision.' } }
    $branch = Git-Text $Repo @('symbolic-ref','--short','HEAD')
    if ($branch -cne $Plan.Branch) { throw 'Update requires the upstream default branch checked out. No branch switching is performed.' }
    $head = Git-Text $Repo @('rev-parse','HEAD')
    if ($head -ne $Plan.Old -and $head -ne $Plan.New) { throw 'Repository changed since this update began. Resolve manually.' }
    Invoke-Native $script:Git @('-C',$Repo,'merge-base','--is-ancestor',$Plan.Old,$Plan.New)
    $url = Git-Text $Repo @('config','--blob',($Plan.New+':.gitmodules'),'--get','submodule.SWLOR_Haks.url')
    $path = Git-Text $Repo @('config','--blob',($Plan.New+':.gitmodules'),'--get','submodule.SWLOR_Haks.path')
    if ($url -cnotmatch '^https://github\.com/zunath/SWLOR_Haks(?:\.git)?$' -or $path -cne 'SWLOR_Haks') { throw 'Upstream changed the HAK definition. Manual review required.' }
    Assert-UpdateClean $Repo
    $subhead = Git-Text (Join-Path $Repo 'SWLOR_Haks') @('rev-parse','HEAD')
    $oldPin = Get-Pin $Repo $Plan.Old; $newPin = Get-Pin $Repo $Plan.New
    if ($subhead -ne $oldPin -and -not ($head -eq $Plan.New -and $subhead -eq $newPin)) { throw 'Unexpected HAK revision. Nothing will be switched.' }
}
function Complete-Update([string]$Repo, $Plan) {
    # Both commits were fetched before this journal was written. Retry is bounded
    # to these exact revisions and never discards intervening edits.
    Assert-UpdatePlan $Repo $Plan
    $pin = Get-Pin $Repo $Plan.New
    $sub = Join-Path $Repo 'SWLOR_Haks'
    Invoke-Native $script:Git @('-C',$sub,'cat-file','-e',($pin+'^{commit}'))
    Invoke-Native $script:Git @('-C',$Repo,'-c','core.longpaths=true','-c','submodule.recurse=false','merge','--ff-only','--no-overwrite-ignore',$Plan.New)
    Assert-UpdateClean $Repo
    Invoke-Native $script:Git @('-C',$sub,'-c','core.longpaths=true','-c','submodule.recurse=false','checkout','--detach','--no-overwrite-ignore',$pin)
    Assert-Haks $Repo
    $journal = Get-UpdateJournal $Repo
    if (Test-Path -LiteralPath $journal) { [IO.File]::Delete($journal) }
    Write-Log 'Main source and pinned HAK revision updated. Building the Toolset next.'
}
function Update-Repository([string]$Repo) {
    Assert-Repository $Repo
    $journal = Get-UpdateJournal $Repo
    if (Test-Path -LiteralPath $journal) {
        Write-Log 'Resuming the previously downloaded update.'
        $plan = [IO.File]::ReadAllText($journal) | ConvertFrom-Json
        Complete-Update $Repo $plan
        return
    }
    Assert-UpdateClean $Repo
    Assert-Haks $Repo
    $target = Get-UpdateTarget $Repo
    $plan = @{ Old=(Git-Text $Repo @('rev-parse','HEAD')); New=$target.Target; Branch=$target.Branch }
    Assert-UpdatePlan $Repo $plan
    if ($plan.Old -eq $plan.New) { return }
    $sub = Join-Path $Repo 'SWLOR_Haks'
    $pin = Get-Pin $Repo $plan.New
    Stage 40 'Downloading the updated pinned HAK assets'
    Invoke-Native $script:Git @('-C',$sub,'fetch','--no-tags','--no-recurse-submodules','--depth','1','https://github.com/zunath/SWLOR_Haks',$pin)
    Assert-NotRunning
    Assert-UpdatePlan $Repo $plan
    [IO.File]::WriteAllText($journal,($plan | ConvertTo-Json))
    Complete-Update $Repo $plan
}
function Set-ModuleRoot([string]$Settings, [string]$Module) {
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 16777216; $serializer.RecursionLimit = 100
    $data = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    if (Test-Path -LiteralPath $Settings) {
        $raw = [IO.File]::ReadAllText($Settings)
        if (-not $raw.TrimStart().StartsWith('{')) { throw 'Settings must be a JSON object. Original file preserved.' }
        $null = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        $data = $serializer.DeserializeObject($raw)
        if ($data -isnot [System.Collections.IDictionary]) { throw 'Settings must be an object.' }
        if ($data.ContainsKey('moduleRoot') -and $data['moduleRoot'] -ceq $Module) { return }
    }
    $data['moduleRoot'] = $Module
    $json = $serializer.Serialize($data)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Settings)) | Out-Null
    $temp = $Settings + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp,$json,(New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Settings) {
            $backup = $Settings + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
            [IO.File]::Replace($temp,$Settings,$backup)
            Write-Log "Settings backup: $backup"
        } else { [IO.File]::Move($temp,$Settings) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}
function Assert-NotRunning {
    if (Get-Process -Name 'SWLOR.Toolset' -ErrorAction SilentlyContinue) { throw 'Close the running SWLOR Toolset before continuing.' }
}
function Start-Toolset([string]$Exe) {
    if (-not (Test-Path -LiteralPath $Exe)) { throw 'No completed Toolset build found. Use Install and launch.' }
    Assert-NotRunning
    $p = Start-Process -FilePath $Exe -WorkingDirectory ([IO.Path]::GetDirectoryName($Exe)) -PassThru
    if ($p.WaitForExit(3000)) { throw "Toolset exited during startup (exit $($p.ExitCode)). Check its application logs." }
    Write-Log "Toolset started (PID $($p.Id))."
}
function Main {
    if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSVersion -lt [version]'5.1') { throw 'Windows x64 and PowerShell 5.1 or later are required.' }
    if ($Action -ne 'Check') { Assert-NotRunning }
    if ([string]::IsNullOrWhiteSpace($InstallParent)) { $script:InstallParent = Join-Path $env:USERPROFILE 'SWLOR' }
    $parent = [IO.Path]::GetFullPath($InstallParent)
    if ($parent.StartsWith('\\') -or $parent.Substring(0,3) -notmatch '^[A-Za-z]:\\$') { throw 'Choose an absolute local installation folder.' }
    $repo = Join-Path $parent 'SWLOR_NWN'
    $tools = Join-Path $env:LOCALAPPDATA 'SWLORLauncher\tools'
    [IO.Directory]::CreateDirectory($tools) | Out-Null
    $env:GIT_TERMINAL_PROMPT = '0'
    if ($Action -eq 'Check') {
        $script:Git = Ensure-Git $tools
        $null = Get-UpdateTarget $repo
        Write-Log 'Check complete. Your working files and HAK checkout were not changed.'
        return
    }
    $sdk = Ensure-Sdk $tools -Offline:($Action -ne 'Install')
    $env:DOTNET_ROOT = $sdk; $env:DOTNET_ROOT_X64 = $sdk
    $env:DOTNET_MULTILEVEL_LOOKUP = '0'; $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_CLI_UI_LANGUAGE = 'en'; $env:VSLANG = '1033'
    $env:DOTNET_NOLOGO = '1'; $env:DOTNET_CLI_HOME = Join-Path $tools 'dotnet-home'
    $env:NUGET_PACKAGES = Join-Path $tools 'packages'; $env:PATH = $sdk + ';' + $env:PATH
    $exe = Join-Path $repo 'SWLOR.Toolset\bin\Debug\net10.0\SWLOR.Toolset.exe'
    if ($Action -ne 'Launch') {
        Stage 25 'Preparing Git and repository'
        $script:Git = Ensure-Git $tools
        if (-not (Test-Path -LiteralPath $repo)) {
            if ($Action -ne 'Install') { throw 'Repository missing. Use Install and launch.' }
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            Invoke-Native $script:Git @('-c','core.longpaths=true','clone','--depth','1','--','https://github.com/zunath/SWLOR_NWN',$repo)
        }
        Assert-Repository $repo
        if ($Action -eq 'Update') { Update-Repository $repo }
        Stage 40 'Checking pinned HAK assets'
        Assert-Haks $repo -Initialize:($Action -eq 'Install')
        Stage 70 'Building Toolset and referenced libraries'
        Push-Location $repo
        try { Invoke-Native (Join-Path $sdk 'dotnet.exe') @('build','SWLOR.Toolset/SWLOR.Toolset.csproj','-c','Debug','-p:RunPostBuildEvent=Never','--nologo') } finally { Pop-Location }
    }
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Toolset executable missing from the expected build output.' }
    $module = Join-Path $repo 'Module'
    foreach ($folder in @('are','utc')) { if (-not (Test-Path -LiteralPath (Join-Path $module $folder) -PathType Container)) { throw 'Selected checkout does not contain a valid Module folder.' } }
    Assert-NotRunning
    Stage 95 'Configuring Module Root'
    Set-ModuleRoot (Join-Path $env:LOCALAPPDATA 'SWLOR.Toolset\settings.json') $module
    Start-Toolset $exe
    Stage 100 'Toolset launched'
}
if (-not $LibraryOnly) {
    $state = Join-Path $env:LOCALAPPDATA 'SWLORLauncher'
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $lock = $null
    try {
        $lock = [IO.File]::Open((Join-Path $state 'operation.lock'),'OpenOrCreate','ReadWrite','None')
        Start-Transcript -Path (Join-Path $state ('launcher-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID + '.log')) | Out-Null
        Stage 5 'Preparing requested operation'
        Main
        exit 0
    } catch { Write-Host "ERROR: $($_.Exception.Message)"; exit 1 }
    finally { try { Stop-Transcript | Out-Null } catch {}; if ($lock) { $lock.Dispose() } }
}
