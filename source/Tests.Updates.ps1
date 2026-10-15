param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
if (Test-Path -LiteralPath $TestRoot) { throw 'TestRoot must be a fresh disposable directory.' }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
. (Join-Path $PSScriptRoot 'Backend.ps1') -LibraryOnly
$script:Git=(Get-Command git.exe).Source
$script:passed=0
function Assert($v) { if (-not $v) { throw 'Assertion failed' } }
function Check($name,[scriptblock]$body) { & $body; $script:passed++; Write-Host "PASS $name" }
function Reject([scriptblock]$body) { $failed=$false; try { & $body } catch { Write-Host $_.Exception.Message; $failed=$true }; Assert $failed }
function G($r,[string[]]$a) { Invoke-Native $script:Git (@('-C',$r)+$a) }
function Fixture($name) {
 $r=Join-Path $TestRoot $name; $s=Join-Path $r 'SWLOR_Haks'; [IO.Directory]::CreateDirectory($s) | Out-Null
 foreach($d in @($r,$s)) { G $d @('init','-b','master'); G $d @('config','user.email','test@example.invalid'); G $d @('config','user.name','Test') }
 G $r @('remote','add','origin','https://github.com/zunath/SWLOR_NWN')
 [IO.File]::WriteAllText((Join-Path $s 'asset'),'old'); G $s @('add','.'); G $s @('commit','-m','old-hak'); $oldHak=Git-Text $s @('rev-parse','HEAD')
 [IO.File]::WriteAllText((Join-Path $r '.gitmodules'),"[submodule `"SWLOR_Haks`"]`npath=SWLOR_Haks`nurl=https://github.com/zunath/SWLOR_Haks`n")
 [IO.File]::WriteAllText((Join-Path $r 'area'),'old-area'); [IO.File]::WriteAllText((Join-Path $r '.gitignore'),"ignored.txt`n")
 G $r @('add','.'); G $r @('commit','-m','old-main'); $old=Git-Text $r @('rev-parse','HEAD')
 G $r @('checkout','-b','fixture-upstream'); [IO.File]::WriteAllText((Join-Path $s 'asset'),'new'); G $s @('add','.'); G $s @('commit','-m','new-hak')
 [IO.File]::WriteAllText((Join-Path $r 'area'),'new-area'); [IO.File]::WriteAllText((Join-Path $r 'ignored.txt'),'upstream'); G $r @('add','.'); G $r @('add','-f','ignored.txt'); G $r @('commit','-m','new-main'); $new=Git-Text $r @('rev-parse','HEAD')
 G $r @('checkout','master'); G $s @('checkout','--detach',$oldHak)
 return @{Repo=$r; Sub=$s; Plan=@{Old=$old;New=$new;Branch='master'}}
}
$f=Fixture 'safe'
Check 'Clean fast-forward plan accepted' { Assert-UpdatePlan $f.Repo $f.Plan }
Check 'Saved local area blocks update and is preserved' { [IO.File]::WriteAllText((Join-Path $f.Repo 'area'),'my-area'); Reject { Complete-Update $f.Repo $f.Plan }; Assert ([IO.File]::ReadAllText((Join-Path $f.Repo 'area')) -eq 'my-area'); Assert ((Git-Text $f.Repo @('rev-parse','HEAD')) -eq $f.Plan.Old); [IO.File]::WriteAllText((Join-Path $f.Repo 'area'),'old-area') }
Check 'Untracked local area blocks update' { $p=Join-Path $f.Repo 'new-local-area'; [IO.File]::WriteAllText($p,'mine'); Reject { Complete-Update $f.Repo $f.Plan }; Assert (Test-Path $p); [IO.File]::Delete($p) }
Check 'Staged edits block update' { [IO.File]::WriteAllText((Join-Path $f.Repo 'area'),'staged'); G $f.Repo @('add','area'); Reject { Complete-Update $f.Repo $f.Plan }; G $f.Repo @('restore','--staged','area'); [IO.File]::WriteAllText((Join-Path $f.Repo 'area'),'old-area') }
Check 'Hidden tracked edits block update' { G $f.Repo @('update-index','--assume-unchanged','area'); Reject { Complete-Update $f.Repo $f.Plan }; G $f.Repo @('update-index','--no-assume-unchanged','area') }
Check 'Local HAK edits block update' { [IO.File]::WriteAllText((Join-Path $f.Sub 'asset'),'mine'); Reject { Complete-Update $f.Repo $f.Plan }; [IO.File]::WriteAllText((Join-Path $f.Sub 'asset'),'old') }
Check 'Ignored file collision is not overwritten' { $p=Join-Path $f.Repo 'ignored.txt'; [IO.File]::WriteAllText($p,'precious'); Reject { Complete-Update $f.Repo $f.Plan }; Assert ([IO.File]::ReadAllText($p) -eq 'precious'); Assert ((Git-Text $f.Repo @('rev-parse','HEAD')) -eq $f.Plan.Old); [IO.File]::Delete($p) }
Check 'Both main and HAK update successfully' { [IO.File]::WriteAllText((Get-UpdateJournal $f.Repo),($f.Plan | ConvertTo-Json)); Complete-Update $f.Repo $f.Plan; Assert ((Git-Text $f.Repo @('rev-parse','HEAD')) -eq $f.Plan.New); Assert ([IO.File]::ReadAllText((Join-Path $f.Sub 'asset')) -eq 'new'); Assert (-not (Test-Path (Get-UpdateJournal $f.Repo))) }
$f=Fixture 'resume'
Check 'Interrupted update resumes after main changed' { G $f.Repo @('merge','--ff-only',$f.Plan.New); [IO.File]::WriteAllText((Get-UpdateJournal $f.Repo),($f.Plan | ConvertTo-Json)); Update-Repository $f.Repo; Assert ((Git-Text $f.Sub @('rev-parse','HEAD')) -eq (Get-Pin $f.Repo $f.Plan.New)) }
$f=Fixture 'resume-edits'
Check 'Resume refuses intervening local edits' { G $f.Repo @('merge','--ff-only',$f.Plan.New); [IO.File]::WriteAllText((Join-Path $f.Sub 'asset'),'new-local-work'); [IO.File]::WriteAllText((Get-UpdateJournal $f.Repo),($f.Plan | ConvertTo-Json)); Reject { Update-Repository $f.Repo }; Assert ([IO.File]::ReadAllText((Join-Path $f.Sub 'asset')) -eq 'new-local-work') }
$f=Fixture 'diverged'
Check 'Local commits cannot be overwritten' { [IO.File]::WriteAllText((Join-Path $f.Repo 'area'),'local-commit'); G $f.Repo @('add','.'); G $f.Repo @('commit','-m','local-work'); $f.Plan.Old=Git-Text $f.Repo @('rev-parse','HEAD'); Reject { Complete-Update $f.Repo $f.Plan } }
$f=Fixture 'branch'
Check 'Non-default branch refused' { G $f.Repo @('checkout','-b','personal'); Reject { Complete-Update $f.Repo $f.Plan } }
Check 'Malformed journal refused' { $f.Plan.New='invalid'; Reject { Complete-Update $f.Repo $f.Plan } }
$f=Fixture 'check'
$remote=Join-Path $TestRoot 'remote.git'
Invoke-Native $script:Git @('clone','--bare',$f.Repo,$remote)
G $remote @('update-ref','refs/heads/master',$f.Plan.New)
G $f.Repo @('remote','set-url','origin',$remote)
# Only the origin allowlist is replaced for this local, network-free fixture.
$originalAssert=${function:Assert-Repository}
function Assert-Repository([string]$Repo) { if ($Repo -ne $f.Repo) { throw 'Unexpected test repository' } }
try {
 Check 'Check fetches available revision without changing main or HAK' { $before=Git-Text $f.Sub @('rev-parse','HEAD'); $result=Get-UpdateTarget $f.Repo; Assert ($result.Target -eq $f.Plan.New); Assert ((Git-Text $f.Repo @('rev-parse','HEAD')) -eq $f.Plan.Old); Assert ((Git-Text $f.Sub @('rev-parse','HEAD')) -eq $before) }
 Check 'Check preserves saved local files' { [IO.File]::WriteAllText((Join-Path $f.Repo 'area'),'my-local-area'); $null=Get-UpdateTarget $f.Repo; Assert ([IO.File]::ReadAllText((Join-Path $f.Repo 'area')) -eq 'my-local-area') }
} finally { Set-Item Function:\Assert-Repository $originalAssert }
Write-Host "RESULT: $script:passed update tests passed. Fixtures retained at $TestRoot"
