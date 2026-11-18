<#
.SYNOPSIS
    打包简繁两个语言包，更新插件源清单与 README 版本号。

.DESCRIPTION
    用法：pwsh ./scripts/package.ps1
    产物：dist/community-zh-hans-<version>.pokeplugin、dist/community-zh-hant-<version>.pokeplugin、
          dist/community-zh-hans.zip、dist/release-notes.md、dist/version.txt

    要点：
    - ZIP 条目路径统一用正斜杠，否则安卓安装器会判定为 unsafe path 而拒绝安装
    - 条目按文件名排序、时间戳固定，保证同一份源码重复打包得到相同字节
    - 打包后重新打开校验：不能有反斜杠、绝对路径、.. 穿越，且 plugin.toml 引用的资源必须齐全
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot "dist" }
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }

$LANGUAGES = @(
    @{ Dir = "plugin";   Id = "community-zh-hans" },
    @{ Dir = "zh-hant";  Id = "community-zh-hant" }
)
$FIXED_TIME = [System.DateTimeOffset]::new(2020, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)

function Read-TomlValue([string]$Path, [string]$Key) {
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*"([^"]*)"')) { return $Matches[1] }
    }
    throw "在 $Path 中找不到 $Key"
}

function New-PluginPackage([string]$SourceDir, [string]$TargetPath) {
    if (Test-Path $TargetPath) { Remove-Item $TargetPath -Force }

    $files = Get-ChildItem -Path $SourceDir -Recurse -File | Sort-Object FullName
    $zip = [System.IO.Compression.ZipFile]::Open($TargetPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($SourceDir.Length).TrimStart('\', '/').Replace('\', '/')
            if ($relative -match '(^|/)\.\.(/|$)' -or $relative.StartsWith('/') -or $relative -match '\\') {
                throw "不安全的条目路径：$relative"
            }
            $entry = $zip.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $FIXED_TIME
            $source = [System.IO.File]::OpenRead($file.FullName)
            try {
                $target = $entry.Open()
                try { $source.CopyTo($target) } finally { $target.Dispose() }
            } finally { $source.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $files.Count
}

function Test-PluginPackage([string]$PackagePath, [string]$SourceDir) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        $bad = @($names | Where-Object { $_.Contains('\') -or $_.StartsWith('/') -or $_ -match '(^|/)\.\.(/|$)' })
        if ($bad.Count -gt 0) { throw "包内存在不安全路径：$($bad -join ', ')" }

        $manifestPath = Join-Path $SourceDir "plugin.toml"
        foreach ($key in @("strings", "messages", "templates", "help", "documents")) {
            $target = $null
            try { $target = Read-TomlValue $manifestPath $key } catch { continue }
            if ($key -eq "documents") {
                if (-not ($names | Where-Object { $_ -like "$target/*" })) { throw "包内缺少文档目录 $target/。" }
            } elseif (-not ($names -contains $target)) {
                throw "包内缺少资源文件 $target"
            }
        }
        return $names.Count
    } finally { $zip.Dispose() }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Update-SourceManifest([string]$Path, [hashtable]$Values, [string]$Version) {
    $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
    $current = $null
    $touched = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*"id"\s*:\s*"([^"]+)"') { $current = $Matches[1] }
        if (-not $current -or -not $Values.ContainsKey($current)) { continue }
        $v = $Values[$current]
        if ($lines[$i] -match '^(\s*)"version"\s*:\s*"[^"]*"(,?)\s*$') {
            $lines[$i] = $Matches[1] + '"version": "' + $Version + '"' + $Matches[2]
        } elseif ($lines[$i] -match '^(\s*)"download"\s*:\s*"[^"]*"(,?)\s*$') {
            $lines[$i] = $Matches[1] + '"download": "' + $v.Download + '"' + $Matches[2]
        } elseif ($lines[$i] -match '^(\s*)"sha256"\s*:\s*"[^"]*"(,?)\s*$') {
            $lines[$i] = $Matches[1] + '"sha256": "' + $v.Sha256 + '"' + $Matches[2]
        } elseif ($lines[$i] -match '^(\s*)"size"\s*:\s*(\d+)(,?)\s*$') {
            $lines[$i] = $Matches[1] + '"size": ' + $v.Size + $Matches[3]
            $touched++
        }
    }
    [System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding($false)))
    if ($touched -lt 1) { throw "未能更新 $Path（未匹配到插件条目）" }
}

function Update-ReadmeVersion([string]$Path, [string]$To) {
    if (-not (Test-Path $Path)) { return }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $before = $text
    $text = [regex]::Replace($text, 'community-zh-hans-\d+\.\d+\.\d+\.pokeplugin', "community-zh-hans-$To.pokeplugin")
    $text = [regex]::Replace($text, 'community-zh-hant-\d+\.\d+\.\d+\.pokeplugin', "community-zh-hant-$To.pokeplugin")
    $text = [regex]::Replace($text, 'community-zh-hans \d+\.\d+\.\d+', "community-zh-hans $To")
    $text = [regex]::Replace($text, 'community-zh-hant \d+\.\d+\.\d+', "community-zh-hant $To")
    $text = [regex]::Replace($text, 'version = "\d+\.\d+\.\d+"', "version = `"$To`"")
    if ($text -ne $before) {
        [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  [README] $Path -> $To"
    }
}

# ---------------------------------------------------------------- 主流程
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path $OutDir).Path
$version = $null
foreach ($lang in $LANGUAGES) {
    $manifest = Join-Path $RepoRoot (Join-Path $lang.Dir "plugin.toml")
    $v = Read-TomlValue $manifest "version"
    if ($version -and $version -ne $v) { throw "简繁版本号不一致：$version / $v" }
    $version = $v
}
$tag = "v$version"
$repo = "ZsyzLahz/pokeldn-zh-hans"
Write-Host "版本 $version（$tag）"

$values = @{}
foreach ($lang in $LANGUAGES) {
    $sourceDir = Join-Path $RepoRoot $lang.Dir
    $packageName = "$($lang.Id)-$version.pokeplugin"
    $packagePath = Join-Path $OutDir $packageName

    $count = New-PluginPackage $sourceDir $packagePath
    $verified = Test-PluginPackage $packagePath $sourceDir
    $size = (Get-Item $packagePath).Length
    $sha = Get-Sha256 $packagePath

    $values[$lang.Id] = @{
        Download = "https://github.com/$repo/releases/download/$tag/$packageName"
        Sha256 = $sha
        Size = $size
    }
    Write-Host ("  [OK] {0} 条目={1} 校验={2} 大小={3} sha256={4}" -f $packageName, $count, $verified, $size, $sha)
}

# 简体现成 zip（解压即装）
$zipPath = Join-Path $OutDir "community-zh-hans.zip"
Copy-Item (Join-Path $OutDir "community-zh-hans-$version.pokeplugin") $zipPath -Force
Write-Host "  [OK] community-zh-hans.zip"

Update-SourceManifest (Join-Path $RepoRoot "pokeldn-source.json") $values $version
Write-Host "  [OK] pokeldn-source.json"
Update-ReadmeVersion (Join-Path $RepoRoot "README.md") $version
Update-ReadmeVersion (Join-Path $RepoRoot "README.en.md") $version

# 发布说明：优先用 release-notes/v<version>.md，否则生成默认内容
$notesSource = Join-Path $RepoRoot (Join-Path "release-notes" "$tag.md")
$notesPath = Join-Path $OutDir "release-notes.md"
if (Test-Path $notesSource) {
    Copy-Item $notesSource $notesPath -Force
} else {
    $lines = @(
        "## $tag",
        "",
        "由 GitHub Actions 依据仓库中的译文资源自动打包。",
        "",
        "| 包 | 大小 | SHA-256 |",
        "|---|---|---|"
    )
    foreach ($lang in $LANGUAGES) {
        $simplified = $values[$lang.Id]
        $lines += ("| {0}-{1}.pokeplugin | {2} | ``{3}`` |" -f $lang.Id, $version, $simplified.Size, $simplified.Sha256)
    }
    $lines += @("", "- 包内路径全部为正斜杠，Windows 与 Android 均可安装")
    [System.IO.File]::WriteAllLines($notesPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
}
[System.IO.File]::WriteAllText((Join-Path $OutDir "version.txt"), $version, (New-Object System.Text.UTF8Encoding($false)))

if ($env:GITHUB_STEP_SUMMARY) {
    $summary = @("### 语言包 $tag", "", "| 包 | 大小 | SHA-256 |", "|---|---|---|")
    foreach ($lang in $LANGUAGES) {
        $s = $values[$lang.Id]
        $summary += ("| {0}-{1}.pokeplugin | {2} | ``{3}`` |" -f $lang.Id, $version, $s.Size, $s.Sha256)
    }
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($summary -join "`n") -Encoding UTF8
}
Write-Host "完成：产物在 $OutDir"
