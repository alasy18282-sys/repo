# APK Studio - сборщик модифицированных APK Standoff 2
# (c) генерация PleasureProject/DustProject-style APK по шаблону рабочей сборки 0.21.0

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$global:ScriptDir = $PSScriptRoot
if (-not $global:ScriptDir) { $global:ScriptDir = (Get-Location).Path }

. (Join-Path $global:ScriptDir 'ios\IpaSupport.ps1')

# Resolve Java at build time so settings remain accessible without a JDK.
function Initialize-JavaTools {
    param([string]$JavaHome)
    $homes = @($JavaHome, $env:JAVA_HOME,
        [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User'),
        [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine'))
    $savedHome = Join-Path $global:ScriptDir 'config\java-home.txt'
    if (Test-Path -LiteralPath $savedHome -PathType Leaf) {
        $homes += (Get-Content -LiteralPath $savedHome -Raw).Trim()
    }
    $homes += Join-Path $global:ScriptDir 'libs\jdk'
    $javaCommand = Get-Command java.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($javaCommand) { $homes += Split-Path -Parent (Split-Path -Parent $javaCommand.Source) }
    foreach ($homeDir in $homes) {
        if ([string]::IsNullOrWhiteSpace($homeDir)) { continue }
        $javaPath = Join-Path $homeDir 'bin\java.exe'
        $keytoolPath = Join-Path $homeDir 'bin\keytool.exe'
        if ((Test-Path -LiteralPath $javaPath -PathType Leaf) -and
            (Test-Path -LiteralPath $keytoolPath -PathType Leaf)) {
            $global:JAVA = (Resolve-Path -LiteralPath $javaPath).ProviderPath
            $global:KEYTOOL = (Resolve-Path -LiteralPath $keytoolPath).ProviderPath
            return
        }
    }
    $global:JAVA = $null
    $global:KEYTOOL = $null
    throw 'JDK не найден. Укажите папку JDK с bin\java.exe и bin\keytool.exe в config\java-home.txt или JAVA_HOME.'
}

function Get-StudioConfigPath {
    return (Join-Path $global:ScriptDir 'config\apkstudio.json')
}

function Save-StudioConfig {
    param([System.Collections.IDictionary]$Config, [string]$Path = (Get-StudioConfigPath))
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
}

function Import-StudioConfig {
    param([System.Collections.IDictionary]$Defaults, [string]$Path = (Get-StudioConfigPath))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $saved = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in $saved.PSObject.Properties) {
            if ($Defaults.Contains($property.Name)) { $Defaults[$property.Name] = [string]$property.Value }
        }
    }
    return $Defaults
}

$global:APKTOOL = Join-Path $global:ScriptDir 'libs\apktool.jar'
$global:SIGNER = Join-Path $global:ScriptDir 'libs\uber-apk-signer.jar'

function Get-JniRoot {
    $scriptDir = $global:ScriptDir
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = $PSScriptRoot }
    $candidates = @($scriptDir, (Split-Path -Parent $scriptDir))
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath (Join-Path $candidate 'Android.mk') -PathType Leaf) { return $candidate }
    }
    return (Split-Path -Parent $scriptDir)
}

function ConvertTo-LibraryId {
    param([string]$FileName)
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    if ($base.Length -gt 3 -and $base.StartsWith('lib', [StringComparison]::OrdinalIgnoreCase)) {
        return $base.Substring(3)
    }
    return $base
}

function Get-KnownNativeLibraries {
    return @(
        [pscustomobject]@{ Id = 'pleasureproject'; Title = 'PleasureProject (шаблон студии)'; OriginalIp = '2.26.99.43' },
        [pscustomobject]@{ Id = 'ProjectZero'; Title = 'ProjectZero (maint.cpp, IL2CPP/ImGui)'; OriginalIp = '5.42.82.49' },
        [pscustomobject]@{ Id = 'MoonProject'; Title = 'MoonProject (moon.cpp, Connect hooks)'; OriginalIp = '172.19.0.1' }
    )
}

function Get-AndroidMkModules {
    $mk = Join-Path (Get-JniRoot) 'Android.mk'
    if (-not (Test-Path -LiteralPath $mk -PathType Leaf)) { return @() }
    $names = @()
    foreach ($line in Get-Content -LiteralPath $mk) {
        if ($line -match '^\s*LOCAL_MODULE\s*:?=\s*([A-Za-z0-9_]+)\s*$') {
            if ($Matches[1] -ne 'dobby') { $names += $Matches[1] }
        }
    }
    return $names
}

function Set-LibraryAbiPath {
    param($Map, [string]$Id, [string]$Abi, [string]$Path)
    if (-not $Map.Contains($Id)) {
        $Map[$Id] = @{ Id = $Id; Title = $Id; OriginalIp = ''; Arm64 = ''; Armv7 = '' }
    }
    if ($Abi -eq 'arm64-v8a' -and [string]::IsNullOrWhiteSpace($Map[$Id].Arm64)) { $Map[$Id].Arm64 = $Path }
    elseif ($Abi -eq 'armeabi-v7a' -and [string]::IsNullOrWhiteSpace($Map[$Id].Armv7)) { $Map[$Id].Armv7 = $Path }
}

function Get-NativeLibrarySearchRoots {
    $scriptDir = $global:ScriptDir
    $jni = Get-JniRoot
    return @(
        @{ Root = (Join-Path $scriptDir 'templates\libs'); Layout = 'named' },
        @{ Root = (Join-Path $scriptDir 'templates\lib'); Layout = 'flat' },
        @{ Root = (Join-Path $jni 'libs'); Layout = 'flat' },
        @{ Root = (Join-Path (Split-Path -Parent $jni) 'libs'); Layout = 'flat' }
    )
}

function Get-NativeLibraryCatalog {
    $map = [ordered]@{}
    foreach ($known in Get-KnownNativeLibraries) {
        $map[$known.Id] = @{
            Id         = $known.Id
            Title      = $known.Title
            OriginalIp = $known.OriginalIp
            Arm64      = ''
            Armv7      = ''
        }
    }
    foreach ($module in Get-AndroidMkModules) {
        if (-not $map.Contains($module)) {
            $map[$module] = @{ Id = $module; Title = $module; OriginalIp = ''; Arm64 = ''; Armv7 = '' }
        }
    }

    foreach ($entry in Get-NativeLibrarySearchRoots) {
        if (-not (Test-Path -LiteralPath $entry.Root -PathType Container)) { continue }
        if ($entry.Layout -eq 'named') {
            Get-ChildItem -LiteralPath $entry.Root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $id = $_.Name
                foreach ($abi in @('arm64-v8a', 'armeabi-v7a')) {
                    $abiDir = Join-Path $_.FullName $abi
                    if (-not (Test-Path -LiteralPath $abiDir -PathType Container)) { continue }
                    $preferred = Join-Path $abiDir ("lib$id.so")
                    $path = $null
                    if (Test-Path -LiteralPath $preferred -PathType Leaf) { $path = $preferred }
                    else {
                        $any = Get-ChildItem -LiteralPath $abiDir -Filter 'lib*.so' -File -ErrorAction SilentlyContinue |
                            Where-Object { (ConvertTo-LibraryId $_.Name) -ne 'dobby' } |
                            Select-Object -First 1
                        if ($any) { $path = $any.FullName }
                    }
                    if ($path) { Set-LibraryAbiPath -Map $map -Id $id -Abi $abi -Path $path }
                }
            }
        } else {
            foreach ($abi in @('arm64-v8a', 'armeabi-v7a')) {
                $abiDir = Join-Path $entry.Root $abi
                if (-not (Test-Path -LiteralPath $abiDir -PathType Container)) { continue }
                Get-ChildItem -LiteralPath $abiDir -Filter 'lib*.so' -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $id = ConvertTo-LibraryId $_.Name
                    if ($id -eq 'dobby') { return }
                    Set-LibraryAbiPath -Map $map -Id $id -Abi $abi -Path $_.FullName
                }
            }
        }
    }

    $list = @()
    foreach ($key in $map.Keys) {
        $item = $map[$key]
        $list += [pscustomobject]@{
            Id         = $item.Id
            Title      = $item.Title
            OriginalIp = $item.OriginalIp
            Arm64      = $item.Arm64
            Armv7      = $item.Armv7
            Present    = -not [string]::IsNullOrWhiteSpace($item.Arm64)
        }
    }
    return $list
}

function Get-DefaultLibs {
    $catalog = @(Get-NativeLibraryCatalog)
    foreach ($preferred in @('pleasureproject', 'MoonProject', 'ProjectZero')) {
        $hit = $catalog | Where-Object { $_.Id -eq $preferred -and $_.Present } | Select-Object -First 1
        if ($hit) { return @{ arm64 = $hit.Arm64; armv7 = $hit.Armv7 } }
    }
    $any = $catalog | Where-Object { $_.Present } | Select-Object -First 1
    if ($any) { return @{ arm64 = $any.Arm64; armv7 = $any.Armv7 } }
    return @{
        arm64 = Join-Path $global:ScriptDir 'templates\lib\arm64-v8a\libpleasureproject.so'
        armv7 = Join-Path $global:ScriptDir 'templates\lib\armeabi-v7a\libpleasureproject.so'
    }
}

function Resolve-NativeLibrary {
    param([System.Collections.IDictionary]$Config)
    $id = [string]$Config.LibId
    $name = [string]$Config.LibName
    if ([string]::IsNullOrWhiteSpace($id)) { $id = $name }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }

    $arm64 = [string]$Config.LibArm64
    $armv7 = [string]$Config.LibArmv7
    $originalIp = ''
    $catalog = @(Get-NativeLibraryCatalog)
    $match = $null
    if (-not [string]::IsNullOrWhiteSpace($id)) {
        $match = $catalog | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    }
    if (-not $match -and -not [string]::IsNullOrWhiteSpace($name)) {
        $match = $catalog | Where-Object { $_.Id -eq $name } | Select-Object -First 1
    }
    if ($match) {
        if ([string]::IsNullOrWhiteSpace($arm64)) { $arm64 = [string]$match.Arm64 }
        if ([string]::IsNullOrWhiteSpace($armv7)) { $armv7 = [string]$match.Armv7 }
        $originalIp = [string]$match.OriginalIp
        if ([string]::IsNullOrWhiteSpace($id)) { $id = $match.Id }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $match.Id }
    }
    $hasCustom = -not [string]::IsNullOrWhiteSpace([string]$Config.LibArm64)
    $skipFallback = (-not $hasCustom) -and -not [string]::IsNullOrWhiteSpace([string]$Config.LibId)
    if (-not $skipFallback -and ([string]::IsNullOrWhiteSpace($arm64) -or -not (Test-Path -LiteralPath $arm64 -PathType Leaf))) {
        $fallback = Get-DefaultLibs
        if ([string]::IsNullOrWhiteSpace($arm64)) { $arm64 = $fallback.arm64 }
        if ([string]::IsNullOrWhiteSpace($armv7)) { $armv7 = $fallback.armv7 }
    }
    if ([string]::IsNullOrWhiteSpace($arm64) -or -not (Test-Path -LiteralPath $arm64 -PathType Leaf)) {
        $available = @($catalog | Where-Object { $_.Present } | ForEach-Object { $_.Id })
        if (-not $available) { $available = @('(нет собранных .so)') }
        throw ("Либа '{0}' не найдена (arm64-v8a). Доступны: {1}. Положите lib{0}.so в templates\libs\{0}\arm64-v8a\ или соберите ndk-build." -f $id, ($available -join ', '))
    }
    if ([string]::IsNullOrWhiteSpace($armv7) -or -not (Test-Path -LiteralPath $armv7 -PathType Leaf)) {
        throw "Либа '$id': нет armeabi-v7a .so. Укажите файл или положите его рядом в armeabi-v7a."
    }
    return [pscustomobject]@{
        Id         = $id
        LibName    = $name
        Arm64      = $arm64
        Armv7      = $armv7
        OriginalIp = $originalIp
    }
}

function Sync-LibraryUi {
    param([bool]$OverwritePaths = $false)
    if (-not $script:Fields -or -not $script:Fields.ContainsKey('LibId')) { return }
    $id = $script:Fields['LibId'].Text
    if ([string]::IsNullOrWhiteSpace($id)) { return }
    $match = @(Get-NativeLibraryCatalog) | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if (-not $match) { return }
    if ($script:Fields.ContainsKey('LibName') -and ($OverwritePaths -or [string]::IsNullOrWhiteSpace($script:Fields['LibName'].Text))) {
        $script:Fields['LibName'].Text = $match.Id
    }
    if ($script:Fields.ContainsKey('LibArm64') -and ($OverwritePaths -or [string]::IsNullOrWhiteSpace($script:Fields['LibArm64'].Text))) {
        $script:Fields['LibArm64'].Text = [string]$match.Arm64
    }
    if ($script:Fields.ContainsKey('LibArmv7') -and ($OverwritePaths -or [string]::IsNullOrWhiteSpace($script:Fields['LibArmv7'].Text))) {
        $script:Fields['LibArmv7'].Text = [string]$match.Armv7
    }
    $abis = @()
    if ($match.Arm64) { $abis += 'arm64-v8a' }
    if ($match.Armv7) { $abis += 'armeabi-v7a' }
    $ip = if ($match.OriginalIp) { " · исходный IP $($match.OriginalIp)" } else { '' }
    if ($abis.Count) { Write-Log "Либа $($match.Id): $($abis -join ', ')$ip" }
    else { Write-Log "Либа $($match.Id): .so не найдены — соберите ndk-build или укажите файлы вручную" }
}

function Set-LibraryComboItems {
    param($Combo, [string]$Selected = '')
    if (-not $Combo) { return }
    $ids = @(Get-NativeLibraryCatalog | ForEach-Object { $_.Id })
    $Combo.Items.Clear()
    foreach ($id in $ids) { [void]$Combo.Items.Add($id) }
    if (-not [string]::IsNullOrWhiteSpace($Selected) -and -not $Combo.Items.Contains($Selected)) {
        [void]$Combo.Items.Add($Selected)
    }
    if (-not [string]::IsNullOrWhiteSpace($Selected) -and $Combo.Items.Contains($Selected)) {
        $Combo.Text = $Selected
    } elseif ($Combo.Items.Count -gt 0 -and $Combo.SelectedIndex -lt 0) {
        $Combo.SelectedIndex = 0
    }
}

function Get-DefaultTemplates {
    return @{
        DnsHook       = Join-Path $global:ScriptDir 'templates\smali\com\pleasureprod\pleasureproject\DnsHook.smali'
        OBBLoader     = Join-Path $global:ScriptDir 'templates\smali\com\axlebolt\bolt\OBBLoaderOcovskiy.smali'
        TokenRequest  = Join-Path $global:ScriptDir 'templates\smali\com\google\googlesignin\TokenRequest.smali'
        GoogleServices = Join-Path $global:ScriptDir 'templates\google-services.json'
    }
}

# ============================================================
#  ЛОГ + ДАЛОГ
# ============================================================
$global:LogBox = $null

function Write-Log {
    param([string]$Msg)
    if ($global:LogBox) {
        $global:LogBox.AppendText((Get-Date -Format 'HH:mm:ss') + "  " + $Msg + "`r`n")
        $global:LogBox.SelectionStart = $global:LogBox.TextLength
        $global:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
    Write-Host $Msg
}

function Show-Err {
    param([string]$Msg)
    [System.Windows.Forms.MessageBox]::Show($Msg, "APK Studio", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

# ============================================================
#  ВАЛИДАЦИЯ
# ============================================================
function Assert-NotEmpty {
    param([string]$Name, [string]$Val)
    if ([string]::IsNullOrWhiteSpace($Val)) { throw "Поле '$Name' не заполнено." }
    return $Val
}

function Assert-FileExists {
    param([string]$Name, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Файл '$Name' не найден: $Path" }
    return $Path
}

function Assert-DirExists {
    param([string]$Name, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Папка '$Name' не найдена: $Path" }
    return $Path
}

function Test-IP {
    param([string]$IP)
    if ([string]::IsNullOrWhiteSpace($IP)) { return $null }
    $seg = $IP.Split('.')
    if ($seg.Count -ne 4) { return $false }
    foreach ($s in $seg) {
        if (-not ($s -match '^\d+$') -or [int]$s -lt 0 -or [int]$s -gt 255) { return $false }
    }
    return $true
}

# ============================================================
#  ХЕЛПЕРЫ
# ============================================================
function Get-VersionCode {
    $aapt = Get-Aapt
    # Native stderr can contain warnings even on success in Windows PowerShell.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        $out = @(& $aapt dump badging $global:SRC_APK 2>&1)
        $exitCode = $global:LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        $details = ($out | Select-Object -Last 6) -join [Environment]::NewLine
        throw "aapt dump badging завершился с кодом '$exitCode'. Инструмент: $aapt. APK: $global:SRC_APK. $details"
    }
    $m = [regex]::Match(($out -join [Environment]::NewLine), "(?m)^package:\s+.*?\bversionCode='(\d+)'")
    if (-not $m.Success) {
        throw "aapt завершился успешно, но строка package с versionCode отсутствует. APK: $global:SRC_APK."
    }
    return [int]$m.Groups[1].Value
}

function Get-Aapt {
    $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
    if ($env:LOCALAPPDATA) { $sdkRoots += Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    # Unity installs SDK and OpenJDK alongside each other.
    $javaHomes = @($env:JAVA_HOME)
    if ($global:JAVA) { $javaHomes += Split-Path -Parent (Split-Path -Parent $global:JAVA) }
    if ($global:ScriptDir) {
        $savedJavaHome = Join-Path $global:ScriptDir 'config\java-home.txt'
        if (Test-Path -LiteralPath $savedJavaHome -PathType Leaf) {
            $javaHomes += (Get-Content -LiteralPath $savedJavaHome -Raw).Trim()
        }
    }
    foreach ($javaHome in $javaHomes) {
        if (-not [string]::IsNullOrWhiteSpace($javaHome)) {
            $sdkRoots += Join-Path (Split-Path -Parent $javaHome) 'SDK'
        }
    }
    foreach ($sdkRoot in ($sdkRoots | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($sdkRoot)) { continue }
        $buildTools = Join-Path $sdkRoot 'build-tools'
        if (-not (Test-Path -LiteralPath $buildTools -PathType Container)) { continue }
        $versions = Get-ChildItem -LiteralPath $buildTools -Directory | Sort-Object @{
            Expression = {
                $version = [version]'0.0'
                if ([version]::TryParse(($_.Name -split '-')[0], [ref]$version)) { $version }
                else { [version]'0.0' }
            }
        } -Descending
        foreach ($directory in $versions) {
            $exe = Join-Path $directory.FullName 'aapt.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
        }
    }
    $command = Get-Command aapt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw 'aapt.exe не найден. Укажите Android SDK с build-tools в ANDROID_SDK_ROOT или ANDROID_HOME; SDK рядом с JDK Unity определяется автоматически.'
}

function Get-KeystoreSha1 {
    param([string]$Ks, [string]$StorePass, [string]$Alias)
    $out = & $global:KEYTOOL -list -v -keystore $Ks -storepass $StorePass -alias $Alias 2>&1
    $line = $out | Select-String -Pattern '^\s*SHA1:\s*(.+)$'
    if ($line) {
        $sha = $line.Matches[0].Groups[1].Value.Trim()
        return ($sha -replace ':', '').ToLowerInvariant()
    }
    $line2 = $out | Select-String -Pattern 'SHA1\s*:\s*(.+)$'
    if ($line2) {
        $sha = $line2.Matches[0].Groups[1].Value.Trim()
        return ($sha -replace ':', '').ToLowerInvariant()
    }
    throw 'Не удалось получить SHA1 сертификата из keystore. Проверь alias/пароль.'
}

function Remove-Bom {
    param([string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        [System.IO.File]::WriteAllBytes($Path, $b[3..($b.Length-1)])
    }
}

function Test-Ipv4String {
    param([string]$Value)
    $parts = $Value.Split('.')
    if ($parts.Count -ne 4) { return $false }
    foreach ($part in $parts) {
        if ($part -notmatch '^\d{1,3}$') { return $false }
        if ([int]$part -gt 255) { return $false }
    }
    return $true
}

function Get-KnownLibServerIps {
    return @('2.26.99.43', '144.31.157.245', '94.156.114.39', '5.42.82.49', '172.19.0.1')
}

function Get-EmbeddedIpv4s {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $found = New-Object System.Collections.Generic.List[string]
    $cur = New-Object System.Text.StringBuilder
    for ($i = 0; $i -le $bytes.Length; $i++) {
        $isDigitOrDot = $false
        if ($i -lt $bytes.Length) {
            $ch = $bytes[$i]
            $isDigitOrDot = ($ch -ge 48 -and $ch -le 57) -or $ch -eq 46
        }
        if ($isDigitOrDot) {
            [void]$cur.Append([char]$bytes[$i])
        } else {
            $value = $cur.ToString()
            [void]$cur.Clear()
            if ($value -match '^\d{1,3}(\.\d{1,3}){3}$' -and (Test-Ipv4String $value) -and -not $found.Contains($value)) {
                $found.Add($value)
            }
        }
    }
    return @($found)
}

function Test-ByteSequenceAt {
    param([byte[]]$Haystack, [int]$Offset, [byte[]]$Needle)
    if ($Offset -lt 0 -or ($Offset + $Needle.Length) -gt $Haystack.Length) { return $false }
    for ($j = 0; $j -lt $Needle.Length; $j++) {
        if ($Haystack[$Offset + $j] -ne $Needle[$j]) { return $false }
    }
    return $true
}

function Test-SoContainsIp {
    param([byte[]]$Bytes, [string]$Ip)
    $needle = [System.Text.Encoding]::ASCII.GetBytes($Ip)
    for ($i = 0; $i -le $Bytes.Length - $needle.Length; $i++) {
        if (Test-ByteSequenceAt -Haystack $Bytes -Offset $i -Needle $needle) { return $true }
    }
    return $false
}

function Resolve-LibOriginalIp {
    param([string]$SoPath, [string]$Preferred = '')
    if (-not (Test-Path -LiteralPath $SoPath -PathType Leaf)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($SoPath)
    $embedded = @(Get-EmbeddedIpv4s -Path $SoPath)
    if ($Preferred -and (Test-SoContainsIp -Bytes $bytes -Ip $Preferred)) { return $Preferred }
    foreach ($known in Get-KnownLibServerIps) {
        if (Test-SoContainsIp -Bytes $bytes -Ip $known) { return $known }
    }
    foreach ($ip in $embedded) {
        if ($ip -notin @('127.0.0.1', '0.0.0.0')) { return $ip }
    }
    return ''
}

function Get-LibIpPatchTargets {
    param([byte[]]$Bytes, [string]$Preferred = '')
    $targets = New-Object System.Collections.Generic.List[string]
    $candidates = @()
    if ($Preferred) { $candidates += $Preferred }
    $candidates += Get-KnownLibServerIps
    foreach ($ip in $candidates) {
        if ([string]::IsNullOrWhiteSpace($ip)) { continue }
        if (-not (Test-SoContainsIp -Bytes $Bytes -Ip $ip)) { continue }
        if (-not $targets.Contains($ip)) { $targets.Add($ip) }
    }
    return @($targets)
}

function Replace-Ipv4InBytes {
    param([byte[]]$Bytes, [string]$OldIP, [string]$NewIP)
    $oldB = [System.Text.Encoding]::ASCII.GetBytes($OldIP)
    $newB = [System.Text.Encoding]::ASCII.GetBytes($NewIP)
    if ($newB.Length -gt 15) { throw "IP '$NewIP' длиннее максимального IPv4 (15 симв.)." }
    $count = 0
    $i = 0
    while ($i -le $Bytes.Length - $oldB.Length) {
        if (-not (Test-ByteSequenceAt -Haystack $Bytes -Offset $i -Needle $oldB)) { $i++; continue }
        $afterPos = $i + $oldB.Length
        $after = if ($afterPos -lt $Bytes.Length) { $Bytes[$afterPos] } else { 0 }
        $pad16 = $false
        if (($i + 16) -le $Bytes.Length) {
            $pad16 = $true
            for ($k = $oldB.Length; $k -lt 16; $k++) {
                if ($Bytes[$i + $k] -ne 0) { $pad16 = $false; break }
            }
        }
        $bounded = ($after -eq 0) -or ($after -lt 48) -or ($after -gt 57)
        if (-not $pad16 -and -not $bounded) { $i++; continue }
        $slot = if ($pad16) { 16 } else { $oldB.Length }
        if ($newB.Length -gt $slot) { $i++; continue }
        for ($k = 0; $k -lt $newB.Length; $k++) { $Bytes[$i + $k] = $newB[$k] }
        for ($k = $newB.Length; $k -lt $slot; $k++) { $Bytes[$i + $k] = 0 }
        $count++
        $i += $slot
    }
    return $count
}

function Patch-LibIP {
    param([string]$SoPath, [string]$NewIP, [string]$OldIP = '', [switch]$AllowMissing)
    if ([string]::IsNullOrWhiteSpace($NewIP)) { return 0 }
    if ($NewIP.Length -gt 15) { throw "IP '$NewIP' длиннее максимального IPv4 (15 симв., например 255.255.255.255)." }
    $b = [System.IO.File]::ReadAllBytes($SoPath)
    $targets = New-Object System.Collections.Generic.List[string]
    if ($OldIP -and (Test-SoContainsIp -Bytes $b -Ip $OldIP) -and $OldIP -ne $NewIP) { $targets.Add($OldIP) }
    foreach ($ip in (Get-LibIpPatchTargets -Bytes $b -Preferred $OldIP)) {
        if ($ip -eq $NewIP) { continue }
        if (-not $targets.Contains($ip)) { $targets.Add($ip) }
    }
    $count = 0
    $replaced = @()
    foreach ($old in $targets) {
        $n = Replace-Ipv4InBytes -Bytes $b -OldIP $old -NewIP $NewIP
        if ($n -gt 0) { $count += $n; $replaced += "$old($n)" }
    }
    if ($count -gt 0) {
        [System.IO.File]::WriteAllBytes($SoPath, $b)
        Write-Log ("Пропатчен IP в {0} -> {1} (замен: {2}: {3})" -f $SoPath, $NewIP, $count, ($replaced -join ', '))
        return $count
    }
    $msg = "IP для замены не найден в $SoPath — патч пропущен. Либа останется со своим адресом."
    if ($AllowMissing) { Write-Log $msg; return 0 }
    throw $msg
}

function Find-Smali {
    param([string]$Root, [string]$FileName)
    $hits = Get-ChildItem -Path $Root -Recurse -Filter $FileName -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\smali' }
    return $hits
}

# ============================================================
#  ДВИЖОК: ПАТЧИ
# ============================================================
function Patch-Manifest {
    param([string]$ManifestPath, [string]$Pkg)
    $txt = [System.IO.File]::ReadAllText($ManifestPath)
    $old = 'com.axlebolt.standoff2'
    if (-not $txt.Contains($old)) { throw 'В манифесте не найден оригинальный пакет com.axlebolt.standoff2. Программа рассчитана на стоковый Standoff 2.' }
    $txt = $txt.Replace($old, $Pkg)
    $txt = [regex]::Replace($txt, 'package="[^"]+"', 'package="' + $Pkg + '"')
    [System.IO.File]::WriteAllText($ManifestPath, $txt, (New-Object System.Text.UTF8Encoding $false))
    Remove-Bom $ManifestPath
    Write-Log "Manifest: пакет -> $Pkg"
}

function Add-DnsHook {
    param([string]$WorkRoot, [string]$Pkg)
    $pkgPath = $Pkg.Replace('.', '/')
    $destDir = Join-Path $WorkRoot "smali\$pkgPath"
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    $tpl = (Get-DefaultTemplates).DnsHook
    $txt = [System.IO.File]::ReadAllText($tpl)
    $txt = $txt.Replace('com/pleasureprod/pleasureproject', $pkgPath)
    $dest = Join-Path $destDir 'DnsHook.smali'
    [System.IO.File]::WriteAllText($dest, $txt, (New-Object System.Text.UTF8Encoding $false))
    Remove-Bom $dest
    Write-Log "DnsHook -> smali\$pkgPath\DnsHook.smali"
}

function Add-OBBLoader {
    param([string]$WorkRoot, [string]$Pkg, [int]$VersionCode, [long]$ObbSize)
    $destDir = Join-Path $WorkRoot 'smali\com\axlebolt\bolt'
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    $tpl = (Get-DefaultTemplates).OBBLoader
    $txt = [System.IO.File]::ReadAllText($tpl)
    $fname = "main.$VersionCode.$Pkg.obb"
    $phname = "main.$VersionCode.com.axlebolt.standoff2.obb"
    $hex = ('{0:X8}' -f $ObbSize).TrimStart('0'); if (-not $hex) { $hex = '0' }
    $txt = $txt.Replace('com.pleasureprod.pleasureproject', $Pkg)
    $txt = $txt.Replace('0x6B09BD78', '0x' + $hex)
    # также заменить любые main.NNNN в файле
    $txt = [regex]::Replace($txt, 'main\.\d+\.', "main.$VersionCode.")
    [System.IO.File]::WriteAllText((Join-Path $destDir 'OBBLoaderOcovskiy.smali'), $txt, (New-Object System.Text.UTF8Encoding $false))
    Remove-Bom (Join-Path $destDir 'OBBLoaderOcovskiy.smali')
    Write-Log "OBBLoader: $fname (size=0x$hex), placeholder=$phname"
}

function Patch-MessagingActivity {
    param([string]$WorkRoot, [string]$Pkg, [string]$LibName)
    $miss = Find-Smali -Root $WorkRoot -FileName 'MessagingUnityPlayerActivity.smali'
    if (-not $miss) { $miss = Get-ChildItem $WorkRoot -Recurse -Filter 'MessagingUnityPlayerActivity.smali' -ErrorAction SilentlyContinue }
    if (-not $miss) { throw 'MessagingUnityPlayerActivity.smali не найден после декода.' }
    $path = $miss[0].FullName
    $txt = [System.IO.File]::ReadAllText($path)
    $pkgPath = $Pkg.Replace('.', '/')

    $block = @(
        "    invoke-super {p0, p1}, Lcom/unity3d/player/UnityPlayerActivity;->onCreate(Landroid/os/Bundle;)V"   # anchor
        ""
        "    new-instance v0, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;"
        "    invoke-direct {v0, p0}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;-><init>(Landroid/content/Context;)V"
        "    invoke-virtual {v0}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->loadOBB()Z"
        ""
        "    const-string v0, `"$LibName`""
        ""
        "    invoke-static {v0}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V"
        ""
        "    invoke-static {}, L$pkgPath/DnsHook;->init()V"
    ) -join "`r`n"

    $anchor = "invoke-super {p0, p1}, Lcom/unity3d/player/UnityPlayerActivity;->onCreate(Landroid/os/Bundle;)V"
    if (-not $txt.Contains($anchor)) { throw 'Не найден якорь invoke-super onCreate в MessagingUnityPlayerActivity.' }
    if ($txt.Contains('OBBLoaderOcovskiy')) { Write-Log 'MessagingUnityPlayerActivity уже пропатчен (OBBLoader найден). Пропускаю.'; return }

    $txt = $txt.Replace($anchor, $block)
    [System.IO.File]::WriteAllText($path, $txt, (New-Object System.Text.UTF8Encoding $false))
    Remove-Bom $path
    Write-Log "MessagingUnityPlayerActivity: внедрены OBBLoader + loadLibrary('$LibName') + DnsHook.init()"
}

function Patch-WebClient {
    param([string]$WorkRoot, [string]$WebClientFull)
    # TokenRequest - перезапись шаблоном с патчем const-string
    $trPath = Find-Smali -Root $WorkRoot -FileName 'TokenRequest.smali' | Select-Object -First 1
    if ($trPath) {
        $tpl = (Get-DefaultTemplates).TokenRequest
        $txt = [System.IO.File]::ReadAllText($tpl)
        $txt = [regex]::Replace($txt, '"[A-Za-z0-9._-]+\.apps\.googleusercontent\.com"', ('"' + $WebClientFull + '"'))
        [System.IO.File]::WriteAllText($trPath.FullName, $txt, (New-Object System.Text.UTF8Encoding $false))
        Remove-Bom $trPath.FullName
        Write-Log ("TokenRequest getWebClientId -> {0}" -f $WebClientFull)
    } else {
        Write-Log 'TokenRequest.smali не найден - пропускаю.'
    }

    # GoogleSignInActivity + любые другие smali с apps.googleusercontent.com (кроме TokenRequest)
    Get-ChildItem $WorkRoot -Recurse -Filter '*.smali' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\smali' -and $_.Name -ne 'TokenRequest.smali' } |
        ForEach-Object {
            $p = $_.FullName
            $c = [System.IO.File]::ReadAllText($p)
            if ($c -match '"([A-Za-z0-9._-]+\.apps\.googleusercontent\.com)"') {
                $c2 = [regex]::Replace($c, '"([A-Za-z0-9._-]+\.apps\.googleusercontent\.com)"', ('"' + $WebClientFull + '"'))
                [System.IO.File]::WriteAllText($p, $c2, (New-Object System.Text.UTF8Encoding $false))
                Remove-Bom $p
                Write-Log "  web client заменён в $($_.FullName.Replace($WorkRoot,'').TrimStart('\'))"
            }
        }
}

function Patch-Strings {
    param([string]$WorkRoot, [hashtable]$C)
    $defs = @{
        'app_name'                = $C.AppLabel
        'default_web_client_id'   = $C.WebClient
        'default_android_client_id' = $C.AndroidClient
        'firebase_database_url'   = $C.DbUrl
        'gcm_defaultSenderId'     = $C.GcmSender
        'google_api_key'          = $C.ApiKey
        'google_app_id'           = $C.GoogleAppId
        'project_id'              = $C.ProjectId
        'google_storage_bucket'   = $C.StorageBucket
    }
    $files = Get-ChildItem (Join-Path $WorkRoot 'res') -Recurse -Filter 'strings.xml' -ErrorAction SilentlyContinue
    if (-not $files) { Write-Log 'strings.xml не найдены!'; return }
    foreach ($f in $files) {
        $content = [System.IO.File]::ReadAllText($f.FullName)
        $changed = $false
        foreach ($k in $defs.Keys) {
            if ([string]::IsNullOrWhiteSpace($defs[$k])) { continue }
            $re = [regex]('<string name="' + [regex]::Escape($k) + '">([^<]*)</string>')
            if ($re.IsMatch($content)) {
                $content = $re.Replace($content, ('<string name="' + $k + '">' + $defs[$k] + '</string>'), 1)
                $changed = $true
            }
        }
        if ($changed) {
            [System.IO.File]::WriteAllText($f.FullName, $content, (New-Object System.Text.UTF8Encoding $false))
            Remove-Bom $f.FullName
            Write-Log "strings.xml: $($f.FullName.Replace($WorkRoot,'').TrimStart('\')) — обновлено"
        }
    }
}

function Write-GoogleServices {
    param([string]$WorkRoot, [hashtable]$C, [string]$Sha1)
    $tpl = (Get-DefaultTemplates).GoogleServices
    $json = [System.IO.File]::ReadAllText($tpl)
    $json = $json.Replace('com.pleasureprod.pleasureproject', $C.Package)
    $json = $json.Replace('1:687942041441:android:c2bae1b49314d222b30f20', $C.GoogleAppId)
    $json = $json.Replace('687942041441-dg9gh1jm6htv0l7vevfgl05kf0kd9n2o.apps.googleusercontent.com', $C.AndroidClient)
    $json = $json.Replace('687942041441-kpuqemaimerqcldhdejpps8sildrfo7l.apps.googleusercontent.com', $C.WebClient)
    $json = $json.Replace('AIzaSyBQCZt00yshd9VFeyJHsOpy5uc_oGomaTo', $C.ApiKey)
    $json = $json.Replace('687942041441', $C.GcmSender)
    $json = $json.Replace('project24-506015', $C.ProjectId)
    $json = $json.Replace('project24-506015.firebasestorage.app', $C.StorageBucket)
    $json = $json.Replace('72d516cfe459f2206b9ab0db4f4191cd0118eac4', $Sha1)
    $assets = Join-Path $WorkRoot 'assets'
    New-Item -ItemType Directory -Path $assets -Force | Out-Null
    $dest = Join-Path $assets 'google-services.json'
    [System.IO.File]::WriteAllText($dest, $json, (New-Object System.Text.UTF8Encoding $false))
    Remove-Bom $dest
    Write-Log "google-services.json записан (SHA1=$Sha1)"
}

function Deployment-LibAndObb {
    param([string]$WorkRoot, [hashtable]$C, [int]$VersionCode, [string]$Arm64Lib, [string]$Armv7Lib, [string]$OriginalIp = '')
    # Libs
    foreach ($abi in @('arm64-v8a','armeabi-v7a')) {
        $dir = Join-Path $WorkRoot "lib\$abi"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $src = if ($abi -eq 'arm64-v8a') { $Arm64Lib } else { $Armv7Lib }
        $dst = Join-Path $dir ("lib" + $C.LibName + ".so")
        Copy-Item $src $dst -Force
        if ($C.ServerIp) {
            Patch-LibIP -SoPath $dst -NewIP $C.ServerIp -OldIP $OriginalIp -AllowMissing
        }
    }
    Write-Log "lib$($C.LibName).so: добавлены arm64-v8a + armeabi-v7a"

    # OBB в assets
    $obbDst = Join-Path $WorkRoot ("assets\main." + $VersionCode + "." + $C.Package + ".obb")
    New-Item -ItemType Directory -Path (Split-Path $obbDst) -Force | Out-Null
    Copy-Item $C.ObbPath $obbDst -Force
    Write-Log "OBB встроен: assets\main.$VersionCode.$($C.Package).obb"
}

# ============================================================
#  ОСНОВНАЯ СБОРКА
# ============================================================
function Build-APK {
    param([hashtable]$C)

    Write-Log "===== НАЧАЛО СБОРКИ ====="

    # --- 1. Валидация ---
    try {
        $global:SRC_APK = Assert-FileExists 'Исходный APK' $C.SrcApk
        Assert-FileExists 'OBB' $C.ObbPath | Out-Null
        Assert-DirExists 'Папка результата' (Split-Path -Parent $C.OutApk) | Out-Null
        Assert-FileExists 'Keystore' $C.KsPath | Out-Null
        Assert-NotEmpty 'Alias' $C.KsAlias | Out-Null
        Assert-NotEmpty 'Пароль keystore' $C.KsStorePass | Out-Null
        Assert-NotEmpty 'Пароль ключа' $C.KsKeyPass | Out-Null
        Assert-NotEmpty 'Название приложения' $C.AppLabel | Out-Null
        Assert-NotEmpty 'Имя библиотеки' $C.LibName | Out-Null
        $previewLib = Resolve-NativeLibrary -Config $C
        Assert-FileExists ("Либа arm64 ({0})" -f $previewLib.Id) $previewLib.Arm64 | Out-Null
        Assert-FileExists ("Либа armeabi-v7a ({0})" -f $previewLib.Id) $previewLib.Armv7 | Out-Null
        $Pkg = Assert-NotEmpty 'Package' $C.Package
        if ($Pkg -notmatch '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$') { throw "Package '$Pkg' некорректен (пример: com.pleasureprod.pleasureproject)." }
        Assert-NotEmpty 'Web client' $C.WebClient | Out-Null
        if (-not $C.WebClient.Contains('apps.googleusercontent.com')) { throw "Web client должен содержать .apps.googleusercontent.com (например 687942041441-xxx.apps.googleusercontent.com)" }
        if (-not (Test-Path $global:APKTOOL))  { throw "apktool.jar не найден: $global:APKTOOL" }
        if (-not (Test-Path $global:SIGNER))   { throw "uber-apk-signer.jar не найден: $global:SIGNER" }
        foreach ($fld in @('AndroidClient','GcmSender','GoogleAppId','ApiKey','ProjectId','DbUrl','StorageBucket','WebClient')) {
            if ([string]::IsNullOrWhiteSpace($C[$fld])) { throw "Поле '$fld' не заполнено." }
        }
        if ($C.ServerIp) {
            $ipok = Test-IP $C.ServerIp
            if ($ipok -eq $false) { throw "Некорректный IP сервера: $($C.ServerIp)" }
        }
        Initialize-JavaTools
        # проверка keystore
        $ksOut = & $global:KEYTOOL -list -keystore $C.KsPath -storepass $C.KsStorePass -alias $C.KsAlias 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Keystore не открылся: $($ksOut | Select-Object -Last 2)" }
    } catch {
        Write-Log ("ОШИБКА ВАЛИДАЦИИ: " + $_.Exception.Message)
        Show-Err $_.Exception.Message
        return
    }

    # --- 2. versionCode ---
    $ver = Get-VersionCode
    Write-Log "versionCode исходного APK = $ver"

    $work = Join-Path $env:TEMP ("apkstudio_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    try {
        # --- 3. декод ---
        $workDec = Join-Path $work 'decoded'
        Write-Log "apktool: декодирование (занимает время)..."
        $outD = & $global:JAVA -jar $global:APKTOOL d -f $global:SRC_APK -o $workDec 2>&1
        if ($LASTEXITCODE -ne 0) { throw "apktool d: $($outD | Select-Object -Last 4)" }
        Write-Log "Декодировано в $workDec"

        # --- 4. патчи ---
        $mfest = Join-Path $workDec 'AndroidManifest.xml'
        Patch-Manifest -ManifestPath $mfest -Pkg $C.Package
        Add-DnsHook -WorkRoot $workDec -Pkg $C.Package

        $obbLen = (Get-Item $C.ObbPath).Length
        Add-OBBLoader -WorkRoot $workDec -Pkg $C.Package -VersionCode $ver -ObbSize $obbLen

        Patch-MessagingActivity -WorkRoot $workDec -Pkg $C.Package -LibName $C.LibName

        # full web client (с суффиксом)
        $webFull = $C.WebClient
        if (-not $webFull.Contains('.apps.googleusercontent.com')) { $webFull = $C.WebClient + '.apps.googleusercontent.com' }
        $androidFull = $C.AndroidClient
        if (-not $androidFull.Contains('.apps.googleusercontent.com')) { $androidFull = $C.AndroidClient + '.apps.googleusercontent.com' }

        Patch-WebClient -WorkRoot $workDec -WebClientFull $webFull
        Patch-Strings -WorkRoot $workDec -C $C

        $sha1 = Get-KeystoreSha1 -Ks $C.KsPath -StorePass $C.KsStorePass -Alias $C.KsAlias
        Write-GoogleServices -WorkRoot $workDec -C $C -Sha1 $sha1

        $resolved = Resolve-NativeLibrary -Config $C
        if ([string]::IsNullOrWhiteSpace($C.LibName)) { $C.LibName = $resolved.LibName }
        Write-Log ("Выбрана либа: {0} -> lib{1}.so" -f $resolved.Id, $C.LibName)
        Deployment-LibAndObb -WorkRoot $workDec -C $C -VersionCode $ver -Arm64Lib $resolved.Arm64 -Armv7Lib $resolved.Armv7 -OriginalIp $resolved.OriginalIp

        # --- 5. сборка ---
        $unsigned = Join-Path $work 'unsigned.apk'
        Write-Log "apktool: сборка..."
        $outB = & $global:JAVA -jar $global:APKTOOL b $workDec -o $unsigned --use-aapt2 2>&1
        if ($LASTEXITCODE -ne 0) { throw "apktool b: $($outB | Select-Object -Last 6)" }
        Write-Log "Собрано: $unsigned"

        # --- 6. подпись ---
        $signOut = Join-Path $work 'signed'
        New-Item -ItemType Directory -Path $signOut -Force | Out-Null
        Write-Log "Подпись (uber-apk-signer)..."
        $outS = & $global:JAVA -jar $global:SIGNER --apks $unsigned --ks $C.KsPath --ksAlias $C.KsAlias --ksPass $C.KsStorePass --ksKeyPass $C.KsKeyPass --out $signOut 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Подпись не удалась: $($outS | Select-Object -Last 4)" }
        $signed = Join-Path $signOut 'unsigned-aligned-signed.apk'
        if (-not (Test-Path $signed)) { throw 'Подпись не выдала unsigned-aligned-signed.apk.' }

        # --- 7. финал ---
        Copy-Item $signed $C.OutApk -Force
        $mb = [math]::Round((Get-Item $C.OutApk).Length / 1MB, 1)
        Write-Log "ГОТОВО -> $($C.OutApk)  ($mb MB)"
        Write-Log "----- СБОРКА ЗАВЕРШЕНА -----"
        [System.Windows.Forms.MessageBox]::Show("Готово!`n$($C.OutApk)", "APK Studio", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        $msg = "ОШИБКА: " + $_.Exception.Message
        Write-Log $msg
        Show-Err $msg
    } finally {
        # временная папка остаётся для диагностики? почистим по умолчанию
        if (Test-Path $work) { Start-Sleep -Milliseconds 500; Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
    }
}

# ============================================================
#  GUI
# ============================================================
function New-ConfigDefaults {
    return [ordered]@{
        Platform     = 'APK'
        IpaSource    = ''
        IpaOut       = ''
        IpaBundle    = ''
        IpaLabel     = ''
        IpaVersion   = ''
        IpaBuild     = ''
        IpaGooglePlist= ''
        IpaPatchPlan = ''
        IpaServerIp  = ''
        IpaOriginalHosts = '46.101.200.35;fra02.bolt.bolt-api.com'
        SrcApk       = ''
        ObbPath      = ''
        OutApk       = ''
        Package      = 'com.pleasureprod.pleasureproject'
        AppLabel     = 'PleasureProject'
        LibId        = 'pleasureproject'
        LibName      = 'pleasureproject'
        LibArm64     = ''
        LibArmv7     = ''
        ServerIp     = '2.26.99.43'
        WebClient    = '687942041441-kpuqemaimerqcldhdejpps8sildrfo7l.apps.googleusercontent.com'
        AndroidClient= '687942041441-dg9gh1jm6htv0l7vevfgl05kf0kd9n2o.apps.googleusercontent.com'
        GcmSender    = '687942041441'
        GoogleAppId  = '1:687942041441:android:c2bae1b49314d222b30f20'
        ApiKey       = 'AIzaSyBQCZt00yshd9VFeyJHsOpy5uc_oGomaTo'
        ProjectId    = 'project24-506015'
        DbUrl        = 'https://project24-506015-default-rtdb.firebaseio.com'
        StorageBucket= 'project24-506015.firebasestorage.app'
        KsPath       = ''
        KsAlias      = 'pleasureproject'
        KsStorePass  = ''
        KsKeyPass    = ''
        Kept8        = ''   # placeholder passthrough
    }
}

$script:Fields = @{}
$script:FieldRows = @{}
$script:PlatformHeaders = @()
function New-FieldRow {
    param([System.Windows.Forms.TableLayoutPanel]$Panel, [string]$Key, [string]$Label, [bool]$Browse = $false, [string]$BrowseKind = '')
    $row = $Panel.RowCount
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Label
    $lbl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lbl.AutoSize = $true

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tb.Name = "fld_$Key"
    if ($Key -in @('KsStorePass', 'KsKeyPass')) { $tb.UseSystemPasswordChar = $true }

    if ($Browse) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = "..."
        $btn.Width = 30
        $btn.Tag = @($Key, $BrowseKind, $tb)
        $btn.Add_Click({
            param($sender, $eventArgs)
            $tag = $sender.Tag
            $key = $tag[0]; $kind = $tag[1]; $tbx = $tag[2]
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            if ($kind -eq 'apk')   { $dlg.Filter = 'APK (*.apk)|*.apk' }
            elseif ($kind -eq 'obb') { $dlg.Filter = 'OBB (*.obb)|*.obb' }
            elseif ($kind -eq 'ks')  { $dlg.Filter = 'Ключи (*.jks;*.keystore;*.ks)|*.jks;*.keystore;*.ks|Все файлы (*.*)|*.*' }
            elseif ($kind -eq 'ipa') { $dlg.Filter = 'IPA (*.ipa)|*.ipa' }
            elseif ($kind -eq 'plist') { $dlg.Filter = 'iOS Firebase (*.plist)|*.plist' }
            elseif ($kind -eq 'json') { $dlg.Filter = 'Patch plan (*.json)|*.json' }
            elseif ($kind -eq 'so') { $dlg.Filter = 'Native lib (*.so)|*.so' }
            elseif ($kind -eq 'outipa') {
                $s = New-Object System.Windows.Forms.SaveFileDialog
                $s.Filter = 'IPA (*.ipa)|*.ipa'
                $s.DefaultExt = 'ipa'
                if ($s.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $tbx.Text = $s.FileName }
                return
            }
            elseif ($kind -eq 'out') {
                $s = New-Object System.Windows.Forms.SaveFileDialog
                $s.Filter = 'APK (*.apk)|*.apk'
                if ($s.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $tbx.Text = $s.FileName }
                return
            }
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $tbx.Text = $dlg.FileName
                if ($kind -eq 'so' -and $key -eq 'LibArm64' -and (Get-Command ConvertTo-LibraryId -ErrorAction SilentlyContinue)) {
                    $pickedId = ConvertTo-LibraryId ([IO.Path]::GetFileName($dlg.FileName))
                    if ($script:Fields.ContainsKey('LibId')) {
                        if (-not $script:Fields['LibId'].Items.Contains($pickedId)) { [void]$script:Fields['LibId'].Items.Add($pickedId) }
                        $script:Fields['LibId'].Text = $pickedId
                    }
                    if ($script:Fields.ContainsKey('LibName')) { $script:Fields['LibName'].Text = $pickedId }
                    $v7 = $dlg.FileName.Replace('arm64-v8a', 'armeabi-v7a')
                    if ($v7 -ne $dlg.FileName -and (Test-Path -LiteralPath $v7 -PathType Leaf) -and $script:Fields.ContainsKey('LibArmv7')) {
                        $script:Fields['LibArmv7'].Text = $v7
                    }
                }
            }
        })
        $Panel.Controls.Add($lbl, 0, $row)
        $Panel.Controls.Add($tb, 1, $row)
        $Panel.Controls.Add($btn, 2, $row)
    } else {
        $Panel.Controls.Add($lbl, 0, $row)
        $Panel.Controls.Add($tb, 1, $row)
    }
    if (-not $script:FieldRows) { $script:FieldRows = @{} }
    $rowControls = @($lbl, $tb)
    if ($Browse) { $rowControls += $btn }
    $script:FieldRows[$Key] = @{ Panel=$Panel; Row=$row; Controls=$rowControls }
    $script:Fields[$Key] = $tb
    $Panel.RowCount = $row + 1
    return $tb
}

function New-SectionHeader {
    param([System.Windows.Forms.TableLayoutPanel]$Panel, [string]$Text)
    $row = $Panel.RowCount
    $h = New-Object System.Windows.Forms.Label
    $h.Text = $Text
    $h.Font = New-Object System.Drawing.Font($h.Font.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
    $h.Dock = [System.Windows.Forms.DockStyle]::Fill
    $Panel.Controls.Add($h, 0, $row)
    $Panel.SetColumnSpan($h, 3)
    $script:PlatformHeaders += @{Control=$h;Panel=$Panel;Row=$row;Platform=$script:BuildingPlatform}
    $Panel.RowCount = $row + 1
}

function Show-Main {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'APK / IPA Studio'
    $form.Size = New-Object System.Drawing.Size(1180, 820)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(860, 640)

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = [System.Windows.Forms.DockStyle]::Fill
    $split.SplitterDistance = 460
    $split.Orientation = 'Vertical'
    $form.Controls.Add($split)

    $leftPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $leftPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $leftPanel.Padding = New-Object System.Windows.Forms.Padding(8)
    $leftPanel.AutoScroll = $true
    $leftPanel.ColumnCount = 3
    $leftPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    $leftPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    $leftPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    $split.Panel1.Controls.Add($leftPanel)

    # --- Нижние кнопки над логом в правой панели ---
    $rightPanel = New-Object System.Windows.Forms.Panel
    $rightPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $split.Panel2.Controls.Add($rightPanel)

    $btnBuild = New-Object System.Windows.Forms.Button
    $btnBuild.Text = 'СОБРАТЬ APK'
    $btnBuild.Size = New-Object System.Drawing.Size(270, 38)
    $script:BuildButton = $btnBuild
    $btnBuild.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $btnBuild.Location = New-Object System.Drawing.Point(10, 8)
    $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Top
    $toolbar.AutoSize = $true
    $toolbar.WrapContents = $true
    $toolbar.Controls.Add($btnBuild)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'Сохранить настройки'
    $btnSave.Size = New-Object System.Drawing.Size(150, 30)
    $btnSave.Location = New-Object System.Drawing.Point(200, 10)
    $toolbar.Controls.Add($btnSave)
    $btnInspect = New-Object System.Windows.Forms.Button
    $btnInspect.Text = 'Разобрать IPA'
    $btnInspect.AutoSize = $true
    $toolbar.Controls.Add($btnInspect)
    $script:IpaInspectButton = $btnInspect
    $btnExtract = New-Object System.Windows.Forms.Button
    $btnExtract.Text = 'Извлечь IPA'
    $btnExtract.AutoSize = $true
    $toolbar.Controls.Add($btnExtract)
    $script:IpaExtractButton = $btnExtract

    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true
    $log.ReadOnly = $true
    $log.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $log.Dock = [System.Windows.Forms.DockStyle]::Fill
    $log.Location = New-Object System.Drawing.Point(0, 50)
    $rightPanel.Controls.Add($log)
    $rightPanel.Controls.Add($toolbar)
    $global:LogBox = $log

    # --- Поля ---
    $c = New-ConfigDefaults
    try { $c = Import-StudioConfig -Defaults $c }
    catch { Show-Err ("Ошибка чтения настроек: " + $_.Exception.Message); return }
    $script:Fields = @{}
    $script:FieldRows = @{}
    $script:PlatformHeaders = @()
    $typeLabel = New-Object System.Windows.Forms.Label
    $typeLabel.Text = 'Тип пакета:'
    $typeLabel.AutoSize = $true
    $typeBox = New-Object System.Windows.Forms.ComboBox
    $typeBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $typeBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $typeBox.Items.AddRange(@('APK','IPA'))
    $typeRow = $leftPanel.RowCount
    $leftPanel.Controls.Add($typeLabel,0,$typeRow)
    $leftPanel.Controls.Add($typeBox,1,$typeRow)
    $leftPanel.RowCount = $typeRow + 1
    $script:Fields['Platform'] = $typeBox
    $script:BuildingPlatform = 'IPA'
    New-SectionHeader -Panel $leftPanel -Text 'iOS — результат без подписи; для установки потребуется подписать'
    New-FieldRow -Panel $leftPanel -Key 'IpaSource' -Label 'Исходный IPA:' -Browse $true -BrowseKind 'ipa'
    New-FieldRow -Panel $leftPanel -Key 'IpaOut' -Label 'Выходной IPA (без подписи):' -Browse $true -BrowseKind 'outipa'
    New-FieldRow -Panel $leftPanel -Key 'IpaBundle' -Label 'Bundle ID (пусто — сохранить):'
    New-FieldRow -Panel $leftPanel -Key 'IpaLabel' -Label 'Название (пусто — сохранить):'
    New-FieldRow -Panel $leftPanel -Key 'IpaVersion' -Label 'Версия (CFBundleShortVersionString):'
    New-FieldRow -Panel $leftPanel -Key 'IpaBuild' -Label 'Сборка (CFBundleVersion):'
    New-FieldRow -Panel $leftPanel -Key 'IpaGooglePlist' -Label 'iOS GoogleService-Info.plist (необязательно):' -Browse $true -BrowseKind 'plist'
    New-FieldRow -Panel $leftPanel -Key 'IpaServerIp' -Label 'IP сервера IPA (пусто — не менять):'
    New-FieldRow -Panel $leftPanel -Key 'IpaOriginalHosts' -Label 'Исходные IP/домены (через ;):'
    New-FieldRow -Panel $leftPanel -Key 'IpaPatchPlan' -Label 'Точные двоичные патчи JSON (необязательно):' -Browse $true -BrowseKind 'json'
    $script:BuildingPlatform = 'APK'
    New-SectionHeader -Panel $leftPanel -Text 'Файлы'
    New-FieldRow -Panel $leftPanel -Key 'SrcApk'  -Label 'Исходный APK (стоковый):' -Browse $true -BrowseKind 'apk'
    New-FieldRow -Panel $leftPanel -Key 'ObbPath' -Label 'OBB файл:' -Browse $true -BrowseKind 'obb'
    New-FieldRow -Panel $leftPanel -Key 'OutApk'  -Label 'Выходной APK:' -Browse $true -BrowseKind 'out'

    New-SectionHeader -Panel $leftPanel -Text 'Приложение'
    New-FieldRow -Panel $leftPanel -Key 'Package'   -Label 'Package:'
    New-FieldRow -Panel $leftPanel -Key 'AppLabel'  -Label 'Название (label):'

    $libLabel = New-Object System.Windows.Forms.Label
    $libLabel.Text = 'Нативная либа:'
    $libLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $libLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $libLabel.AutoSize = $true
    $libBox = New-Object System.Windows.Forms.ComboBox
    $libBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $libBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $libBox.Name = 'fld_LibId'
    $btnLibRefresh = New-Object System.Windows.Forms.Button
    $btnLibRefresh.Text = 'Обновить'
    $btnLibRefresh.Width = 80
    $libRow = $leftPanel.RowCount
    $leftPanel.Controls.Add($libLabel, 0, $libRow)
    $leftPanel.Controls.Add($libBox, 1, $libRow)
    $leftPanel.Controls.Add($btnLibRefresh, 2, $libRow)
    $script:FieldRows['LibId'] = @{ Panel = $leftPanel; Row = $libRow; Controls = @($libLabel, $libBox, $btnLibRefresh) }
    $script:Fields['LibId'] = $libBox
    $leftPanel.RowCount = $libRow + 1
    Set-LibraryComboItems -Combo $libBox -Selected $c.LibId

    New-FieldRow -Panel $leftPanel -Key 'LibName'   -Label 'Имя loadLibrary (имя .so без lib):'
    New-FieldRow -Panel $leftPanel -Key 'LibArm64'  -Label 'arm64-v8a .so:' -Browse $true -BrowseKind 'so'
    New-FieldRow -Panel $leftPanel -Key 'LibArmv7'  -Label 'armeabi-v7a .so:' -Browse $true -BrowseKind 'so'
    New-FieldRow -Panel $leftPanel -Key 'ServerIp'  -Label 'IP сервера (под патч выбранной либы, до 15 симв.)'

    New-SectionHeader -Panel $leftPanel -Text 'Google Sign-In / Firebase'
    New-FieldRow -Panel $leftPanel -Key 'WebClient'     -Label 'Web client ID (oauth client_type 3):'
    New-FieldRow -Panel $leftPanel -Key 'AndroidClient' -Label 'Android client ID (client_type 1):'
    New-FieldRow -Panel $leftPanel -Key 'GcmSender'     -Label 'GCM Sender (project number):'
    New-FieldRow -Panel $leftPanel -Key 'GoogleAppId'   -Label 'Google App ID:'
    New-FieldRow -Panel $leftPanel -Key 'ApiKey'        -Label 'API key:'
    New-FieldRow -Panel $leftPanel -Key 'ProjectId'     -Label 'Project ID:'
    New-FieldRow -Panel $leftPanel -Key 'DbUrl'         -Label 'Database URL:'
    New-FieldRow -Panel $leftPanel -Key 'StorageBucket' -Label 'Storage bucket:'

    New-SectionHeader -Panel $leftPanel -Text 'Подпись'
    New-FieldRow -Panel $leftPanel -Key 'KsPath'      -Label 'Keystore (.jks):' -Browse $true -BrowseKind 'ks'
    New-FieldRow -Panel $leftPanel -Key 'KsAlias'     -Label 'Alias:'
    New-FieldRow -Panel $leftPanel -Key 'KsStorePass' -Label 'Пароль keystore:'
    New-FieldRow -Panel $leftPanel -Key 'KsKeyPass'   -Label 'Пароль ключа:'

    # --- заполнение по умолчанию ---
    foreach ($k in $c.Keys) {
        if ($script:Fields.ContainsKey($k)) { $script:Fields[$k].Text = $c[$k] }
    }
    if ([string]::IsNullOrWhiteSpace($libBox.Text) -and $c.LibName) {
        Set-LibraryComboItems -Combo $libBox -Selected $c.LibName
    } elseif (-not [string]::IsNullOrWhiteSpace($c.LibId)) {
        Set-LibraryComboItems -Combo $libBox -Selected $c.LibId
    }
    Sync-LibraryUi -OverwritePaths:([string]::IsNullOrWhiteSpace($c.LibArm64))
    $script:LibraryComboReady = $true
    $libBox.Add_SelectedIndexChanged({
        if (-not $script:LibraryComboReady) { return }
        Sync-LibraryUi -OverwritePaths:$true
    })
    $btnLibRefresh.Add_Click({
        $current = $script:Fields['LibId'].Text
        $script:LibraryComboReady = $false
        try {
            Set-LibraryComboItems -Combo $script:Fields['LibId'] -Selected $current
            Sync-LibraryUi -OverwritePaths:$true
        } finally { $script:LibraryComboReady = $true }
    })

    if ($typeBox.SelectedIndex -lt 0) { $typeBox.SelectedIndex = 0 }
    $typeBox.Add_SelectedIndexChanged({
        param($sender,$eventArgs)
        Update-PlatformUI -Platform $sender.Text
    })
    Update-PlatformUI -Platform $typeBox.Text

    function Read-Config {
        $h = [ordered]@{}
        foreach ($k in $script:Fields.Keys) { $h[$k] = $script:Fields[$k].Text }
        return $h
    }

    $btnBuild.Add_Click({
        param($sender, $eventArgs)
        $sender.Enabled = $false
        try {
            $cfg = Read-Config
            Save-StudioConfig -Config $cfg
            Write-Log ("Настройки сохранены: " + (Get-StudioConfigPath))
            Build-Package -C $cfg
        } catch { Show-Err $_.Exception.Message }
        finally { $sender.Enabled = $true }
    })
    $btnInspect.Add_Click({
        param($sender,$eventArgs)
        $sender.Enabled = $false
        try {
            Save-StudioConfig -Config (Read-Config)
            Write-Log 'IPA: чтение структуры, Mach-O и SHA256...'
            $result = Invoke-IpaBackend -Action inspect -Config (Read-Config)
            Write-Log ("Bundle: {0}; версия: {1}; сборка: {2}; iOS: {3}; Mach-O: {4}; шифрование: {5}" -f $result.bundle_id,$result.version,$result.build,$result.minimum_ios,$result.binaries.Count,$result.encrypted)
            Write-Log ('SHA256: ' + $result.sha256)
            Write-Log 'Отчёт сохранён в test_out\ipa-analysis. Подпись и запуск на устройстве не проверялись.'
        } catch { Show-Err $_.Exception.Message }
        finally { $sender.Enabled = $true }
    })
    $btnExtract.Add_Click({
        param($sender,$eventArgs)
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Выберите родительскую папку; файлы будут извлечены в новую подпапку.'
        try {
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $destination = Join-Path $dialog.SelectedPath ('ipa-extracted-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            $sender.Enabled = $false
            $result = Invoke-IpaBackend -Action extract -Config (Read-Config) -OutputPath $destination
            Write-Log ('IPA извлечён: ' + $result.directory)
        } catch { Show-Err $_.Exception.Message }
        finally { $sender.Enabled = $true; $dialog.Dispose() }
    })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        try { Save-StudioConfig -Config (Read-Config) }
        catch {
            $eventArgs.Cancel = $true
            Show-Err ("Ошибка сохранения настроек: " + $_.Exception.Message)
        }
    })
    $btnSave.Add_Click({
        $s = New-Object System.Windows.Forms.SaveFileDialog
        $s.Filter = 'Конфиг (*.json)|*.json'
        $s.InitialDirectory = Split-Path -Parent (Get-StudioConfigPath)
        $s.FileName = 'apkstudio.json'
        if ($s.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Save-StudioConfig -Config (Read-Config) -Path $s.FileName
            Write-Log "Настройки сохранены: $($s.FileName)"
        }
    })

    $form.ShowDialog() | Out-Null
}

# точка входа
if ($env:APKSTUDIO_CLI) {
    # CLI режим: APKSTUDIO_CONFIG=<путь к json>
    $cfgPath = $env:APKSTUDIO_CONFIG
    if (-not $cfgPath -or -not (Test-Path $cfgPath)) { Write-Log "CLI: не задан APKSTUDIO_CONFIG"; exit 1 }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $h = [ordered]@{}
    foreach ($p in $cfg.PSObject.Properties) { $h[$p.Name] = $p.Value }
    Build-Package -C $h
} else {
    Show-Main
}