# scripts/prepare-release.ps1
# 用法: powershell -File prepare-release.ps1 [-Version "2.4.0"] [-Source "D:\ZCODE\work\plugins\persona-engine"] [-Dest "D:\ZCODE\work\persona-engine-github"]
# 将插件源文件打包到 GitHub 发布目录（排除运行时状态与临时文件）

param(
    [string]$Version = "2.4.0",
    [string]$Source = "D:\ZCODE\work\plugins\persona-engine",
    [string]$Dest = "D:\ZCODE\work\persona-engine-github"
)

$ErrorActionPreference = 'Stop'
$excludePatterns = @('smoke_*', 'ctx_home', 'v2_home', 'audit_s*', '*_input*', '*_out*', '*_err*', 'repro*', 'dyn_*', 'lens_*', 'marathon_*', 's9_*', 's10_*', 's11_*', 's12_*', 's13_*', 's14_*', 's15_*', 'v21_*', 's15_*.tmp')

function Copy-IfNewer([string]$src, [string]$dst) {
    $dstDir = Split-Path $dst -Parent
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item $src $dst -Force
}

# 1. 清空目标并重建
if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
New-Item -ItemType Directory -Path $Dest -Force | Out-Null

# 2. 复制核心文件
$coreFiles = @(
    'README.md', 'LICENSE', '.gitignore', 'CHANGELOG.md',
    '.zcode-plugin\plugin.json',
    'mcp\persona-engine.ps1',
    'skills\persona\SKILL.md',
    'commands\persona.md',
    'corpus\tone-notes.md',
    'docs\DESIGN.md', 'docs\PERSONA-CONVERSION.md', 'docs\AGENT-README.md',
    'tests\probes.md', 'tests\rubric.md',
    'tests\fixtures\persona-prompt.md',
    'tests\harness\transcript-hygiene.ps1'
)
foreach ($f in $coreFiles) {
    $srcPath = Join-Path $Source $f
    if (Test-Path $srcPath) { Copy-IfNewer $srcPath (Join-Path $Dest $f) }
    else { Write-Host "WARN missing: $f" }
}

# 3. 复制测试报告
Copy-IfNewer (Join-Path $Source 'tests\rounds\ctx-test-summary.md') (Join-Path $Dest 'tests\rounds\ctx-test-summary.md')
Copy-IfNewer (Join-Path $Source 'tests\rounds\rounds-summary.md') (Join-Path $Dest 'tests\rounds\rounds-summary.md')
Copy-IfNewer (Join-Path $Source 'tests\rounds\online-web-test.md') (Join-Path $Dest 'tests\rounds\online-web-test.md')

# 4. 复制会话记录（ctx-s*.md + round*-transcript.md + ctx-foil.md + ctx-fact-ledger.md）
Get-ChildItem (Join-Path $Source 'tests\rounds') -Filter '*.md' | ForEach-Object {
    Copy-IfNewer $_.FullName (Join-Path (Join-Path $Dest 'tests\rounds') $_.Name)
}

# 5. 验证版本
$manifest = Get-Content (Join-Path $Dest '.zcode-plugin\plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.version -ne $Version) {
    $t = [System.IO.File]::ReadAllText((Join-Path $Dest '.zcode-plugin\plugin.json'), [System.Text.Encoding]::UTF8)
    $t = $t.Replace($manifest.version, $Version)
    [System.IO.File]::WriteAllText((Join-Path $Dest '.zcode-plugin\plugin.json'), $t, (New-Object System.Text.UTF8Encoding($true)))
}
Write-Host "Release $Version prepared at $Dest"
Write-Host "Files: $((Get-ChildItem $Dest -Recurse -File).Count)"
