param([string]$RequestFile, [string]$ResultFile, [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'
$gitLibraryOnly = $LibraryOnly
. (Join-Path $PSScriptRoot 'Backend.ps1') -LibraryOnly

function Invoke-GitCommand([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory) {
    # Windows argv quoting. No command shell is involved.
    $quoted = foreach ($arg in $Arguments) {
        '"' + [regex]::Replace([regex]::Replace($arg, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }
    $si = New-Object Diagnostics.ProcessStartInfo
    $si.FileName = $Exe; $si.Arguments = $quoted -join ' '
    $si.UseShellExecute = $false; $si.CreateNoWindow = $true
    $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
    $si.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $si.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    if ($WorkingDirectory) { $si.WorkingDirectory = $WorkingDirectory }
    $si.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $si.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
    $si.EnvironmentVariables['GH_PROMPT_DISABLED'] = '1'
    $si.EnvironmentVariables['GH_CONFIG_DIR'] = $script:AuthDirectory
    $si.EnvironmentVariables['GH_HOST'] = 'github.com'
    foreach ($key in @('GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN','GIT_INDEX_FILE','GIT_DIR','GIT_WORK_TREE','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL')) { $si.EnvironmentVariables.Remove($key) }
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $si
    try {
        [void]$p.Start()
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(300000)) { $p.Kill(); throw 'Operation timed out. Refresh the repository before retrying.' }
        $output = $stdout.Result; $errors = $stderr.Result
        if ($p.ExitCode -ne 0) { throw ($errors + $output).Trim() }
        return $output
    } finally { $p.Dispose() }
}
function G([string[]]$Arguments) { Invoke-GitCommand $script:Git (@('--literal-pathspecs','-c','core.quotepath=false') + $Arguments) $script:Repo }
function Invoke-Gh([string[]]$Arguments) { Invoke-GitCommand $script:Gh $Arguments $script:Repo }
function Ensure-Gh([string]$Tools) {
    $receipt = Join-Path $Tools 'gh-path.txt'
    if (Test-Path -LiteralPath $receipt) {
        $path = [IO.File]::ReadAllText($receipt).Trim()
        if (Test-Path -LiteralPath $path) { return $path }
    }
    $existing = Get-Command gh.exe -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }
    $release = Get-Json 'https://api.github.com/repos/cli/cli/releases/latest'
    $asset = @($release.assets | Where-Object { $_.name -match '^gh_[0-9.]+_windows_amd64.zip$' })
    if ($asset.Count -ne 1 -or $asset[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'GitHub CLI release is missing a verified Windows x64 archive.' }
    $zip = Get-Verified $asset[0].browser_download_url $Matches[1] SHA256 (Join-Path $Tools 'downloads') @('github.com')
    $dest = Join-Path $Tools ('gh-' + [guid]::NewGuid().ToString('N'))
    Expand-SafeZip $zip $dest
    $path = Join-Path $dest 'bin\gh.exe'
    if (-not (Test-Path -LiteralPath $path)) { throw 'GitHub CLI executable missing.' }
    [IO.File]::WriteAllText($receipt, $path)
    return $path
}
function Assert-GitReady {
    if ((G @('rev-parse','--is-inside-work-tree')).Trim() -ne 'true') { throw 'Select an installed repository.' }
    foreach ($marker in @('MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','rebase-merge','rebase-apply')) {
        $path = (G @('rev-parse','--git-path',$marker)).Trim()
        if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $script:Repo $path }
        if (Test-Path -LiteralPath $path) { throw 'Finish the merge, rebase or cherry-pick outside the launcher first.' }
    }
    if (G @('ls-files','--unmerged')) { throw 'Resolve merge conflicts before continuing.' }
}
function Get-ChangedFiles {
    $raw = G @('status','--porcelain=v1','-z','--untracked-files=all','--ignore-submodules=none')
    $entries = $raw.Split([char]0); $result = @()
    for ($i=0; $i -lt $entries.Length; $i++) {
        $entry = $entries[$i]; if (-not $entry) { continue }
        $code = $entry.Substring(0,2); $path = $entry.Substring(3); $paths = @($path)
        if ($code -match '[RC]') { $i++; $paths += $entries[$i] }
        $result += [pscustomobject]@{ path=$path; status=$code; paths=$paths }
    }
    return $result
}
function Get-GitSnapshot {
    $branch = (G @('branch','--show-current')).Trim()
    [pscustomobject]@{ branch=$branch; files=@(Get-ChangedFiles); head=(G @('rev-parse','HEAD')).Trim() }
}
function Get-FilePreview([string]$Path) {
    $file = @(Get-ChangedFiles | Where-Object { $_.path -ceq $Path })
    if ($file.Count -ne 1) { throw 'File changed since refresh. Refresh the list.' }
    if ($file[0].status -eq '??') {
        $full = Join-Path $script:Repo $Path
        $info = Get-Item -LiteralPath $full
        if ($info.Length -gt 262144) { return 'New file: ' + $Path + "`nPreview omitted for files larger than 256 KB." }
        $bytes = [IO.File]::ReadAllBytes($full)
        if ($bytes -contains 0) { return 'New binary file: ' + $Path + "`nSize: " + $bytes.Length + ' bytes' }
        return [Text.Encoding]::UTF8.GetString($bytes)
    }
    $diff = G (@('diff','--no-ext-diff','--no-textconv','HEAD','--') + $file[0].paths)
    if ($diff.Length -gt 262144) { $diff = $diff.Substring(0,262144) + "`n[Preview truncated]" }
    return $diff
}
function Commit-Selected($Request) {
    Assert-GitReady
    if (-not (G @('branch','--show-current')).Trim()) { throw 'Detached HEAD: create a working branch before committing.' }
    if ([string]::IsNullOrWhiteSpace($Request.message)) { throw 'Enter a commit message.' }
    if ([string]::IsNullOrWhiteSpace($Request.authorName) -or $Request.authorEmail -notmatch '^[^\s<>]+@[^\s<>]+$') { throw 'Enter an author name and valid email, or sign in to GitHub.' }
    $available = @(Get-ChangedFiles); $paths = @()
    foreach ($selected in $Request.files) {
        $match = @($available | Where-Object { $_.path -ceq $selected })
        if ($match.Count -ne 1) { throw 'The changed-file list is stale. Refresh and select files again.' }
        $paths += $match[0].paths
    }
    if ($paths.Count -eq 0) { throw 'Select at least one file.' }
    # A submodule pointer is only meaningful when its own changes are committed.
    foreach ($path in $paths) {
        $mode = G @('ls-files','--stage','--',$path)
        if ($mode -match '^160000 ') {
            $dirty = Invoke-GitCommand $script:Git @('-C',(Join-Path $script:Repo $path),'status','--porcelain','--untracked-files=all') $script:Repo
            if ($dirty) { throw 'Commit and push HAK changes separately before selecting the HAK reference.' }
        }
    }
    $messagePath = Join-Path ([IO.Path]::GetTempPath()) ('swlor-message-'+[guid]::NewGuid().ToString('N')+'.txt')
    try {
        [IO.File]::WriteAllText($messagePath, $Request.message, (New-Object Text.UTF8Encoding($false)))
        $addPaths = @($paths | Where-Object { (Test-Path -LiteralPath (Join-Path $script:Repo $_)) -or (G @('ls-files','--',$_)) })
        if ($addPaths.Count -gt 0) { $null = G (@('add','--') + $addPaths) }
        # --only excludes unrelated entries that were already staged by another tool.
        $output = G (@('-c',('user.name='+$Request.authorName),'-c',('user.email='+$Request.authorEmail),'commit','--only','--file',$messagePath,'--') + $paths)
        return $output
    } finally { Remove-Item -LiteralPath $messagePath -ErrorAction SilentlyContinue }
}
function Assert-Destination([string]$Destination) {
    if ($Destination -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$' -or $Destination.EndsWith('/..') -or $Destination.EndsWith('/.')) { throw 'Destination must be owner/repository, for example Antras89/SWLOR_NWN.' }
}
function Push-SelectedBranch($Request) {
    Assert-GitReady
    Assert-Destination $Request.destination
    $branch = (G @('branch','--show-current')).Trim()
    if (-not $branch -or $branch -cne $Request.branch) { throw 'Branch changed. Refresh before pushing.' }
    if ((G @('rev-parse','HEAD')).Trim() -cne $Request.head) { throw 'Commits changed. Review again before pushing.' }
    $account = Invoke-Gh @('api','user','--jq','.login')
    if ($account.Trim() -cne $Request.account) { throw 'GitHub account changed. Sign in or refresh account details.' }
    $permission = (Invoke-Gh @('api',('repos/'+$Request.destination),'--jq','.permissions.push')).Trim()
    if ($permission -ne 'true') { throw 'This account cannot push here. Choose your own fork or a repository you can write to.' }
    $helper = '!"' + $script:Gh.Replace('\','/') + '" auth git-credential'
    return G @('-c','credential.helper=','-c',('credential.helper='+$helper),'push','--porcelain',('https://github.com/'+$Request.destination+'.git'),('HEAD:refs/heads/'+$branch))
}
if ($gitLibraryOnly) { return }
try {
    $r = Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $tools = Join-Path $r.state 'tools'; [void][IO.Directory]::CreateDirectory($tools)
    $script:AuthDirectory = Join-Path $r.state 'github-auth'
    $script:Repo = $r.repo
    if ($r.action -eq 'PrepareAuth') {
        $script:Gh = Ensure-Gh $tools
        $data = @{ gh=$script:Gh; authDirectory=$script:AuthDirectory }
    } else {
        if ($r.action -in @('Account','SwitchAccount')) {
            if (-not (Test-Path -LiteralPath $script:Repo -PathType Container)) { $script:Repo = $r.state }
        } else {
            $script:Git = Ensure-Git $tools
            if (-not (Test-Path -LiteralPath $script:Repo -PathType Container)) { throw 'Install the Toolset first or choose an existing repository.' }
        }
        switch ($r.action) {
            'Refresh' { $data = Get-GitSnapshot }
            'Preview' { $data = Get-FilePreview $r.path }
            'Commit' { $data = Commit-Selected $r }
            'Branch' { Assert-GitReady; $null=G @('check-ref-format','--branch',$r.branch); $data=G @('switch','-c',$r.branch) }
            'Account' { $script:Gh=Ensure-Gh $tools; $data=(Invoke-Gh @('api','user','--jq','{login: .login, id: .id}')) | ConvertFrom-Json }
            'SwitchAccount' { $script:Gh=Ensure-Gh $tools; $null=Invoke-Gh @('auth','switch','--hostname','github.com','--user',$r.account); $data=(Invoke-Gh @('api','user','--jq','{login: .login, id: .id}')) | ConvertFrom-Json }
            'Push' { $script:Gh=Ensure-Gh $tools; $data=Push-SelectedBranch $r }
            'Fork' {
                $script:Gh=Ensure-Gh $tools
                $upstream = if ((Split-Path $script:Repo -Leaf) -eq 'SWLOR_Haks') { 'zunath/SWLOR_Haks' } else { 'zunath/SWLOR_NWN' }
                $data=Invoke-Gh @('repo','fork',$upstream,'--clone=false','--remote=false')
            }
            default { throw 'Unknown Git action.' }
        }
    }
    @{ok=$true; data=$data} | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $ResultFile -Encoding UTF8
} catch {
    @{ok=$false; error=$_.Exception.Message} | ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultFile -Encoding UTF8
    exit 1
}
