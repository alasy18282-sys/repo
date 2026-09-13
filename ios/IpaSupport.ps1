function Get-StudioPython {
    $saved = Join-Path $global:ScriptDir 'config\python-path.txt'
    if (Test-Path -LiteralPath $saved -PathType Leaf) {
        $path = (Get-Content -LiteralPath $saved -Raw).Trim()
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    $command = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source -notlike '*\WindowsApps\*') { return $command.Source }
    throw 'Для IPA требуется Python 3.10+. Укажите путь к python.exe в config\python-path.txt.'
}

function Invoke-IpaBackend {
    param([ValidateSet('inspect','build','extract')][string]$Action,
          [System.Collections.IDictionary]$Config, [string]$OutputPath = '')
    $python = Get-StudioPython
    $backend = Join-Path $global:ScriptDir 'ios\ipa_tool.py'
    if (-not (Test-Path -LiteralPath $Config.IpaSource -PathType Leaf)) { throw 'Исходный IPA не найден.' }
    $arguments = @($backend, $Action, '--source', [string]$Config.IpaSource)
    $temp = $null
    try {
        if ($Action -eq 'build') {
            $temp = [IO.Path]::GetTempFileName()
            $iosConfig = @{}
            foreach ($key in $Config.Keys) { if ($key -like 'Ipa*') { $iosConfig[$key] = $Config[$key] } }
            $iosConfig | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temp -Encoding UTF8
            $arguments += @('--output', [string]$Config.IpaOut, '--config', $temp)
        } elseif ($Action -eq 'extract') {
            $arguments += @('--output', $OutputPath)
        } else {
            $reportDir = Join-Path $global:ScriptDir 'test_out\ipa-analysis'
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            $report = Join-Path $reportDir ('analysis-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')
            $arguments += @('--report', $report)
        }
        $previousPreference = $ErrorActionPreference
        $previousConsoleEncoding = [Console]::OutputEncoding
        try {
            $ErrorActionPreference = 'Continue'
            [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
            $text = @(& $python @arguments 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
            [Console]::OutputEncoding = $previousConsoleEncoding
        }
        if ($code -ne 0) { throw ($text -join [Environment]::NewLine) }
        return (($text -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop)
    } finally {
        if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Build-IPA {
    param([System.Collections.IDictionary]$C)
    Write-Log 'IPA: перепаковка без сертификата; результат потребует подписи. Проверка всех файлов может занять несколько минут.'
    $result = Invoke-IpaBackend -Action build -Config $C
    if ($result.endpoint_replacements -gt 0) {
        Write-Log ('IPA: адрес заменён на ' + $result.server_ip + '; строк: ' + $result.endpoint_replacements)
    }
    Write-Log ('ГОТОВО — НЕПОДПИСАННЫЙ IPA: ' + $result.output)
    Write-Log ('SHA256: ' + $result.output_sha256)
    Write-Log ('Отчёт: ' + $result.output + '.report.json')
}

function Build-Package {
    param([System.Collections.IDictionary]$C)
    if ($C.Platform -eq 'IPA') { Build-IPA -C $C }
    elseif (-not $C.Platform -or $C.Platform -eq 'APK') { Build-APK -C $C }
    else { throw ('Неизвестный тип пакета: ' + $C.Platform) }
}

function Update-PlatformUI {
    param([string]$Platform)
    if ($Platform -notin @('APK','IPA')) { $Platform = 'APK' }
    foreach ($key in $script:FieldRows.Keys) {
        $entry = $script:FieldRows[$key]
        $visible = if ($key -like 'Ipa*') { $Platform -eq 'IPA' } else { $Platform -eq 'APK' }
        foreach ($control in $entry.Controls) { $control.Visible = $visible }
        while ($entry.Panel.RowStyles.Count -le $entry.Row) {
            $null = $entry.Panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        }
        $style = $entry.Panel.RowStyles[$entry.Row]
        if ($visible) { $style.SizeType = [System.Windows.Forms.SizeType]::AutoSize }
        else { $style.SizeType = [System.Windows.Forms.SizeType]::Absolute; $style.Height = 0 }
    }
    if ($script:PlatformHeaders) {
        foreach ($header in $script:PlatformHeaders) {
            $visible = $header.Platform -eq $Platform
            $header.Control.Visible = $visible
            while ($header.Panel.RowStyles.Count -le $header.Row) {
                $null = $header.Panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
            }
            $style = $header.Panel.RowStyles[$header.Row]
            if ($visible) { $style.SizeType = [System.Windows.Forms.SizeType]::AutoSize }
            else { $style.SizeType = [System.Windows.Forms.SizeType]::Absolute; $style.Height = 0 }
        }
    }
    if ($script:BuildButton) { $script:BuildButton.Text = if ($Platform -eq 'IPA') { 'СОБРАТЬ IPA (без подписи)' } else { 'СОБРАТЬ APK' } }
    if ($script:IpaInspectButton) { $script:IpaInspectButton.Visible = $Platform -eq 'IPA' }
    if ($script:IpaExtractButton) { $script:IpaExtractButton.Visible = $Platform -eq 'IPA' }
}
