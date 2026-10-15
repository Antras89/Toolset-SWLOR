# Toolset SWLOR

An independent, unofficial Windows launcher for the SWLOR desktop Toolset, with an English interface. Version 1.1 helps you install the required tools, build the desktop application, launch it, and apply guarded updates.

This repository is maintained independently by Antras89. It is not an official SWLOR release or a fork of the SWLOR repositories. The launcher downloads the official SWLOR_NWN repository and its pinned SWLOR_Haks assets when installing the Toolset.

## Download and start

1. Download [SWLOR-Toolset1.1.zip](SWLOR-Toolset1.1.zip) and extract it.
2. Open `SWLOR-Launcher.exe` without administrator privileges.
3. Select a writable installation folder and click **Install and launch**.
4. Once the Toolset opens, use **Tools > Area Generator** to create an area.

The ZIP contains the ready-to-run launcher, source code, instructions, and validation notes.

## Features

- Install Git when needed and a private .NET 10 SDK.
- Download the Toolset source and the HAK revision pinned by that source.
- Build and launch the desktop Toolset and configure its Module Root.
- Launch an existing build without downloading or rebuilding.
- Rebuild local source without fetching updates.
- Check for upstream updates and preview incoming commits.
- Apply guarded fast-forward updates; local changes and diverged history block updating.
- Open local project files and diagnostic logs from the launcher.

Saving areas changes local files. The launcher does not publish your work to GitHub or a live server.

## Requirements

- Windows 10 or 11, x64.
- Windows PowerShell 5.1 and .NET Framework 4.8.
- Internet access for initial setup and dependency downloads.
- A writable local installation folder and enough space for the HAK assets.

Visual Studio, a preinstalled .NET SDK, and Docker are not required. Neverwinter Nights: Enhanced Edition is optional for starting the Toolset, but is needed for base-game models and tilesets.

## Source and documentation

- [User guide](README.txt): installation, buttons, update behavior, file locations, and troubleshooting.
- [Source code](source): C# launcher, embedded PowerShell backend, build script, and tests.
- [Validation notes](VALIDATION.txt): checks recorded for the supplied version and remaining limitations.
- [Executable checksum](SHA256SUMS.txt): SHA-256 for the supplied executable.

To rebuild, use `source/Build.ps1` on Windows with the .NET Framework compiler. See the user guide for test prerequisites. The supplied executable is not commercially code-signed.

The original version 1.1 package is preserved in this repository. Its executable checksum was verified during import; the application and its tests were not rerun as part of publication.
