param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
if (Test-Path -LiteralPath $TestRoot) { throw 'Use a new disposable TestRoot.' }
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$repo=Join-Path $TestRoot 'install\SWLOR_NWN'
$state=Join-Path $TestRoot 'state'
[void][IO.Directory]::CreateDirectory($repo);[void][IO.Directory]::CreateDirectory($state)
[IO.File]::WriteAllText((Join-Path $state 'install-parent.txt'),(Join-Path $TestRoot 'install'))
function Git([string[]]$A) { & git.exe -C $repo @A; if($LASTEXITCODE -ne 0){throw 'Fixture Git failed'} }
Git @('init','-b','main');Git @('config','user.name','UI Test');Git @('config','user.email','test@example.invalid')
[IO.File]::WriteAllText((Join-Path $repo 'area.json'),'old')
[IO.File]::WriteAllText((Join-Path $repo 'other.json'),'old')
Git @('add','.');Git @('commit','-m','Initial')
[IO.File]::WriteAllText((Join-Path $repo 'area.json'),'new area')
[IO.File]::WriteAllText((Join-Path $repo 'other.json'),'unselected')
Git @('add','other.json')
[Windows.Forms.Application]::EnableVisualStyles()
$assembly=[Reflection.Assembly]::LoadFile((Resolve-Path (Join-Path $PSScriptRoot '..\SWLOR-Launcher.exe')).Path)
$ctor=$assembly.GetType('Launcher').GetConstructor([type[]]@([string]))
$form=$ctor.Invoke([object[]]@([string]$state))
$flags=[Reflection.BindingFlags]'Instance,NonPublic'
function Field([string]$Name) { $panel.GetType().GetField($Name,$flags).GetValue($panel) }
function Invoke-UI([string]$Name) {
 $task=$panel.GetType().GetMethod($Name,$flags).Invoke($panel,@())
 $deadline=[DateTime]::UtcNow.AddSeconds(40)
 while(-not $task.IsCompleted) { [Windows.Forms.Application]::DoEvents();if([DateTime]::UtcNow -gt $deadline){throw 'UI task timed out'};Start-Sleep -Milliseconds 20 }
 if($task.IsFaulted){throw $task.Exception.GetBaseException()}
}
try {
 $form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-32000,-32000);$form.Show()
 $tabs=$form.Controls[0];if($tabs.TabPages.Count -ne 2){throw 'Expected two tabs'};$tabs.SelectedIndex=1
 $panel=$tabs.TabPages[1].Controls[0]
 Invoke-UI 'RefreshFiles'
 $files=Field 'files';if($files.Items.Count -ne 2){throw 'Missing changed files'}
 foreach($item in $files.Items){$item.Checked=$item.Text -eq 'area.json'}
 (Field 'message').Text='Commit from actual Git panel'
 (Field 'author').Text='UI Test';(Field 'email').Text='test@example.invalid'
 Invoke-UI 'Commit'
 if((Git @('show','HEAD:area.json')) -ne 'new area'){throw 'Selected content not committed'}
 if((Git @('show','HEAD:other.json')) -ne 'old'){throw 'Unselected content committed'}
 if((Git @('diff','--cached','--name-only')) -ne 'other.json'){throw 'Unrelated staging lost'}
 $form.PerformLayout();[Windows.Forms.Application]::DoEvents()
 $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
 try {$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $TestRoot 'git-menu.png'))}finally{$bitmap.Dispose()}
 Write-Host 'PASS Compiled UI -> embedded PowerShell -> refresh -> selected commit -> refresh'
} finally {$form.Dispose()}
