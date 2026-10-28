# Installs Sharp from a GitHub release. release.sh fills in {version} and
# the installers' {sha256_x64} and {sha256_arm64} and publishes this
# script beside them,
# so this installs the newest stable release:
#
#   irm https://github.com/tinuxongit/sharp-terminal/releases/latest/download/install.ps1 | iex
#
# Downloaded by PowerShell rather than a browser, the installer carries no
# mark of the web, so SmartScreen doesn't stop the unsigned installer.
# Everything runs in a script block: `iex` runs in the user's own shell,
# which an `exit` would close and loose variables would litter.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $version = '{version}'
    # The system's processor, not PowerShell's: on ARM it may run as x64.
    $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
    $sha256 = if ($arch -eq 'arm64') { '{sha256_arm64}' } else { '{sha256_x64}' }
    $name = "Sharp-$version-$arch-setup.exe"
    $url = "https://github.com/tinuxongit/sharp-terminal/releases/download/v$version/$name"

    $dir = Join-Path ([IO.Path]::GetTempPath()) ('sharp-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $file = Join-Path $dir $name
        Write-Host "Downloading Sharp $version..."
        Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $sha256) {
            throw "The download doesn't match Sharp $version's checksum, so nothing was installed."
        }
        Write-Host 'Installing...'
        $installer = Start-Process -FilePath $file -Wait -PassThru
        if ($installer.ExitCode -ne 0) {
            throw "The installer stopped before finishing (exit code $($installer.ExitCode))."
        }
        Write-Host "Sharp $version is installed. It updates itself from now on."
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
