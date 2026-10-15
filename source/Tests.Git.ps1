param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
if (Test-Path -LiteralPath $TestRoot) { throw 'TestRoot must be a new disposable directory.' }
[void][IO.Directory]::CreateDirectory($TestRoot)
. (Join-Path $PSScriptRoot 'GitBackend.ps1') -LibraryOnly
$script:Git=(Get-Command git.exe -ErrorAction Stop).Source
$script:Repo=$TestRoot
$script:AuthDirectory=Join-Path $TestRoot 'unused-auth'
$script:passed=0
function Assert($Value) { if (-not $Value) { throw 'Assertion failed.' } }
function Test([string]$Name,[scriptblock]$Body) { & $Body; $script:passed++; Write-Host "PASS $Name" }
function Reject([scriptblock]$Body) { $rejected=$false;try { & $Body }catch{$rejected=$true};Assert $rejected }
function Put([string]$Path,[string]$Text) { [IO.File]::WriteAllText((Join-Path $TestRoot $Path),$Text,(New-Object Text.UTF8Encoding($false))) }
$null=G @('init','-b','main');$null=G @('config','user.name','Test');$null=G @('config','user.email','test@example.invalid')
Put 'selected.txt' 'old';Put 'unselected.txt' 'old';Put 'delete.txt' 'old';Put 'rename-old.txt' 'old'
$null=G @('add','.');$null=G @('commit','-m','Initial')
$request=[pscustomobject]@{files=@('selected.txt');message='Selected only';authorName='Launcher Test';authorEmail='test@example.invalid'}
Test 'Commit excludes unrelated staged file' {
 Put 'selected.txt' 'new';Put 'unselected.txt' 'keep staged';$null=G @('add','unselected.txt')
 $null=Commit-Selected $request
 Assert ((G @('show','HEAD:selected.txt')).Trim() -eq 'new')
 Assert ((G @('show','HEAD:unselected.txt')).Trim() -eq 'old')
 Assert ((G @('diff','--cached','--name-only')).Trim() -eq 'unselected.txt')
}
Test 'Unicode, spaces, apostrophe and literal pathspec filename' {
 $name="zażółć file's [1].txt";Put $name 'Unicode data'
 $request.files=@($name);$null=Commit-Selected $request
 Assert ((G @('show',('HEAD:'+$name))).Trim() -eq 'Unicode data')
}
Test 'Untracked preview and binary summary' {
 Put 'new.txt' 'Preview content';Assert ((Get-FilePreview 'new.txt') -eq 'Preview content')
 [IO.File]::WriteAllBytes((Join-Path $TestRoot 'image.bin'),[byte[]]@(0,1,2));Assert ((Get-FilePreview 'image.bin') -match 'binary')
}
Test 'Deletion is committed only when selected' {
 Remove-Item -LiteralPath (Join-Path $TestRoot 'delete.txt');$request.files=@('delete.txt');$null=Commit-Selected $request
 Assert (-not (G @('ls-tree','HEAD','--','delete.txt')))
}
Test 'Rename includes old and new paths' {
 $null=G @('mv','rename-old.txt','rename-new.txt');$request.files=@('rename-new.txt');$null=Commit-Selected $request
 Assert (-not (G @('ls-tree','HEAD','--','rename-old.txt')));Assert (G @('ls-tree','HEAD','--','rename-new.txt'))
 Assert ((G @('diff','--cached','--name-only')).Trim() -eq 'unselected.txt')
}
Test 'Stale selection, empty message and detached HEAD refused' {
 $request.files=@('missing.txt');Reject { Commit-Selected $request }
 $request.files=@('new.txt');$request.message='';Reject { Commit-Selected $request };$request.message='Test'
 $null=G @('switch','--detach');Reject { Commit-Selected $request };$null=G @('switch','main')
}
Test 'Destination URL and option injection refused' {
 Assert-Destination 'Antras89/SWLOR_NWN'
 Reject {Assert-Destination 'https://example.com/a/b'};Reject {Assert-Destination '-x/repo'};Reject {Assert-Destination 'a/b --force'}
}
Test 'Push blocks changed branch before network' {
 Reject {Push-SelectedBranch ([pscustomobject]@{destination='Antras89/test';branch='other';head='wrong'})}
}
Write-Host "$script:passed Git publishing tests passed."

# Keep real Git for repository checks; intercept only the network push command.
$script:realG=${function:G}
$script:Gh='C:\Program Files\GitHub CLI\gh.exe'
$script:fakeLogin='Antras89';$script:fakePermission='true';$script:pushArguments=$null
function Invoke-Gh([string[]]$Arguments) { if($Arguments[1] -eq 'user'){return $script:fakeLogin};return $script:fakePermission }
function G([string[]]$Arguments) { if($Arguments -contains 'push'){$script:pushArguments=$Arguments;return 'mock push'}; & $script:realG $Arguments }
$pushRequest=[pscustomobject]@{destination='Antras89/test';branch='main';head=(G @('rev-parse','HEAD')).Trim();account='Antras89'}
Test 'Push uses selected HTTPS destination and explicit branch without force' {
 $null=Push-SelectedBranch $pushRequest
 Assert ($script:pushArguments -contains 'https://github.com/Antras89/test.git')
 Assert ($script:pushArguments -contains 'HEAD:refs/heads/main')
 Assert (-not ($script:pushArguments -contains '--force'))
 Assert ($script:pushArguments -contains 'credential.helper=')
}
Test 'Push rejects account mismatch and missing permission' {
 $script:fakeLogin='OtherUser';Reject {Push-SelectedBranch $pushRequest};$script:fakeLogin='Antras89'
 $script:fakePermission='false';Reject {Push-SelectedBranch $pushRequest};$script:fakePermission='true'
}
Test 'Push rejects a stale commit ID' {
 $pushRequest.head='0000000000000000000000000000000000000000';Reject {Push-SelectedBranch $pushRequest}
}
Write-Host "RESULT: $script:passed Git publishing tests passed (network push mocked)."
