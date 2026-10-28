param(
    [string]$BuildDir = (Join-Path $PSScriptRoot '..\..\zig-out'),
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'sharp-dev'),
    [string]$DesktopDir = [Environment]::GetFolderPath('Desktop')
)

# Publish only complete builds. Each payload gets its own directory so open
# terminals can continue using their executable and matching resources.
$ErrorActionPreference = 'Stop'
$BuildDir = (Get-Item -LiteralPath $BuildDir).FullName.TrimEnd('\', '/')
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
if ($InstallRoot.StartsWith('\\')) {
    throw 'InstallRoot must be a local Windows path, not a WSL or network path.'
}

$requiredFiles = @(
    'bin\sharp.exe', 'bin\conpty.dll', 'bin\OpenConsole.exe',
    'share\terminfo\ghostty.terminfo', 'share\licenses\conpty\LICENSE.txt'
)
$resourceDirs = @('share\ghostty\themes', 'share\ghostty\shell-integration')
foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $BuildDir $relativePath) -PathType Leaf)) {
        throw "Incomplete build: missing $relativePath"
    }
}
foreach ($relativePath in $resourceDirs) {
    if (-not (Test-Path -LiteralPath (Join-Path $BuildDir $relativePath) -PathType Container)) {
        throw "Incomplete build: missing $relativePath"
    }
}

# Include resources in the identity: editing a theme or integration script
# must refresh the shortcut even when the executable has not changed.
$files = @(
    foreach ($relativePath in $requiredFiles) {
        Get-Item -LiteralPath (Join-Path $BuildDir $relativePath)
    }
    foreach ($relativePath in $resourceDirs) {
        Get-ChildItem -LiteralPath (Join-Path $BuildDir $relativePath) -Recurse -File -Force
    }
)
$fileHashes = @{}
$manifest = @(
    foreach ($file in ($files | Sort-Object FullName)) {
        $relativePath = $file.FullName.Substring($BuildDir.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $fileHashes[$file.FullName] = $hash
        "$relativePath`t$hash"
    }
) -join "`n"
$hasher = [System.Security.Cryptography.SHA256]::Create()
try {
    $digest = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($manifest))
    $buildId = ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
} finally {
    $hasher.Dispose()
}

$buildsDir = Join-Path $InstallRoot 'builds'
$buildPath = Join-Path $buildsDir $buildId
New-Item -ItemType Directory -Path $buildsDir -Force | Out-Null
if (-not (Test-Path -LiteralPath $buildPath)) {
    $stagingPath = Join-Path $buildsDir ('.staging-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $stagingPath | Out-Null
        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($BuildDir.Length + 1)
            if ($relativePath.StartsWith('bin\')) { $relativePath = $relativePath.Substring(4) }
            $destination = Join-Path $stagingPath $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $fileHashes[$file.FullName]) {
                throw 'Build output changed while copying. Run the installer again after the build finishes.'
            }
        }
        Rename-Item -LiteralPath $stagingPath -NewName $buildId
    } finally {
        if (Test-Path -LiteralPath $stagingPath) {
            Remove-Item -LiteralPath $stagingPath -Recurse -Force
        }
    }
}

# Publish the link last so a failed copy leaves the previous launch intact.
New-Item -ItemType Directory -Path $DesktopDir -Force | Out-Null
$shortcutPath = Join-Path $DesktopDir 'Sharp Dev.lnk'
$temporaryLink = Join-Path $DesktopDir ('.sharp-dev-' + [guid]::NewGuid().ToString('N') + '.lnk')
try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($temporaryLink)
    $shortcut.TargetPath = Join-Path $buildPath 'sharp.exe'
    $shortcut.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
    $shortcut.IconLocation = $shortcut.TargetPath + ',0'
    $shortcut.Description = 'Latest successful local Sharp development build'
    $shortcut.Save()
    Move-Item -LiteralPath $temporaryLink -Destination $shortcutPath -Force
} finally {
    if (Test-Path -LiteralPath $temporaryLink) {
        Remove-Item -LiteralPath $temporaryLink -Force
    }
}

Write-Output "Development build: $buildPath"
Write-Output "Desktop shortcut: $shortcutPath"
Write-Output 'Open Sharp Dev to use this build. Existing terminals keep running.'
