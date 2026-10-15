SWLOR Toolset Launcher 1.1
English edition for Windows x64

GET STARTED
1. Extract the ZIP into a folder of your choice.
2. Double-click SWLOR-Launcher.exe. Do not run it as administrator.
3. Keep the suggested installation folder, or click Browse.
4. Click Install and launch. Leave the launcher open until setup finishes.
5. After the Toolset opens, use Tools > Area Generator to create an area.

The launcher requires Windows 10/11 x64, Windows PowerShell 5.1 and
.NET Framework 4.8 (normally included with current Windows installations).
No Visual Studio, preinstalled .NET SDK, or manual terminal commands are needed.
Internet is needed for first-time setup and dependency restore. HAK assets are
large; download time and disk usage depend on the current repository contents.
Use a writable local folder, preferably outside OneDrive and Program Files.

BUTTONS
Install and launch: obtains Git if needed, downloads a private .NET 10 SDK,
downloads official SWLOR_NWN and its pinned SWLOR_Haks submodule, builds the
desktop Toolset and its referenced libraries, configures Module Root and runs it.
Launch: starts the existing build without downloading, updating or rebuilding.
Rebuild and launch: rebuilds the local source and starts the Toolset. It does
not fetch repository updates or replace authored module files.
Check for updates: fetches the upstream default branch and compares revisions.
It shows the result and up to 10 incoming commits without changing working
files, rebuilding, downloading HAK assets, or changing Toolset settings.
Update and launch: downloads and applies a safe fast-forward update of the
default branch, checks out its pinned HAK revision, rebuilds and launches.
Local tracked/untracked changes (including saved areas), local HAK changes,
diverged history, another branch, or hidden tracked edits block the update.
Open files: opens your SWLOR_NWN repository.
Open logs: opens the launcher's diagnostic logs.

The percentage bar shows setup stages, not a download time estimate.
Downloaded megabytes and build messages appear in the log.
Close an already running Toolset before using Install, Launch, Rebuild or Update.

WHERE FILES GO
Repository: <selected installation folder>\SWLOR_NWN
Default installation folder: %USERPROFILE%\SWLOR
SDK, optional Git and package cache: %LOCALAPPDATA%\SWLORLauncher\tools
Logs and launcher preferences: %LOCALAPPDATA%\SWLORLauncher
Toolset settings: %LOCALAPPDATA%\SWLOR.Toolset\settings.json

Module Root is set to the selected repository's Module folder. Other settings
are preserved. If Module Root changes, a settings.json.backup-* copy is saved
beside the original settings. Invalid JSON is not overwritten.

RETRYING AND EXISTING WORK
If a network or build error occurs, read the log and retry. Verified SDK/Git
downloads are reused, and an interrupted HAK download can normally be retried.
The launcher refuses to switch submodule revisions when local edits, a
different checked-out revision or conflicts are detected. Back up and resolve
that state yourself; Launch can still run a previously built application.
An incomplete main clone may require choosing a fresh installation folder.
Never delete a repository containing areas or other work you want to keep.

Updates happen only when you click Update and launch. Install and launch does
not update existing repositories. No reset, clean, stash, forced checkout or
automatic conflict resolution is used. Initial clones use shallow history to reduce
downloads. Full assets at the project's pinned revision are still downloaded.
To use an existing checkout, select its parent folder; its name must be
SWLOR_NWN and its origin must be the official HTTPS repository.

UPDATING AN EXISTING INSTALLATION
1. Run this new launcher and select the same installation parent as before.
2. Click Check for updates to compare against GitHub's default branch.
3. Close the Toolset, then click Update and launch to apply available changes.
If you have authored local areas, the updater stops instead of merging them.
Keep your work, back it up and resolve the repository manually, or install a
fresh copy into another parent folder. Nothing is uploaded to GitHub or a server.
An interrupted update can be retried with Update and launch. A journal inside
the Git metadata records the exact main/HAK revisions for a guarded resume.
If the source update succeeds but the build fails, fix the reported issue and
use Rebuild and launch. The launcher does not roll back or delete your files.

OTHER NOTES
This launcher is an unofficial helper, not an official SWLOR release.
The EXE is not code-signed with a commercial publisher certificate.
Windows file-picker/system dialogs can follow your Windows display language;
the launcher interface and its own messages are English.
NWN Enhanced Edition remains optional for starting the Toolset, but is needed
for base-game models and tilesets. Docker is not needed for this desktop flow.
Saving an area edits local files; it does not publish to a live server.

The SDK download uses Microsoft's release metadata and SHA512 verification.
Portable Git uses Git for Windows release metadata and SHA256 verification.
All tools are downloaded from their upstream services rather than bundled.

SOURCE AND REBUILD
The source folder includes Launcher.cs, Backend.ps1, App.manifest, Build.ps1
and Tests.ps1 plus Tests.Updates.ps1. Backend.ps1 is embedded in the executable;
it need not be kept
beside the EXE. Build.ps1 recompiles it with the Windows .NET Framework compiler.
Tests.ps1 requires Git and a fresh disposable -TestRoot directory.
See VALIDATION.txt for what was actually tested and remaining limits.
