# transcript-hygiene.ps1 - 转写卫生工具（v0.9）
# 用法: powershell -File transcript-hygiene.ps1 <转写文件路径>
# 剥离误入转写正文的引擎注记：model_user 登记/对账、persona_recall/predict 注记、
# 带置信度的推断行、以及任何"（...）"包裹的后台机制文本。剥离前自动备份 .bak。

param([string]$Path)
if (-not (Test-Path $Path)) { Write-Host "file not found: $Path"; exit 1 }
Copy-Item $Path "$Path.bak" -Force
$t = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
$before = $t.Length
# 整行剥离：包裹在（）内的引擎机制注记行
$patterns = @(
    '（model_user[^）]*）\r?\n?',
    '（model_user 对账[^）]*）\r?\n?',
    '（persona_recall[^）]*）\r?\n?',
    '（prediction[^）]*）\r?\n?',
    '（engine[^）]*）\r?\n?',
    '（invisible[^）]*）\r?\n?'
)
foreach ($pat in $patterns) { $t = [regex]::Replace($t, $pat, '') }
# 行内剥离：对话行内的（…登记…）/（…对账…）片段
$t = $t.Replace('（model_user 对账：预测"开口说让人或垫钱的事"——应验了。垫钱不在预测内，补进模型）', '')
$t = [regex]::Replace($t, '（model_user 登记：[^）]*）', '')
$t = [regex]::Replace($t, '（model_user 对账：[^）]*）', '')
[System.IO.File]::WriteAllText($Path, $t, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("cleaned: " + $Path + " (" + $before + " -> " + $t.Length + " chars, backup at .bak)")
