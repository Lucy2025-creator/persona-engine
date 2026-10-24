# persona-engine.ps1 - Persona Engine MCP server (PowerShell 5.1, zero dependency)
# Line-delimited JSON-RPC 2.0 over stdio. Data home: $env:PERSONA_ENGINE_HOME or <CWD>/.persona-engine

$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Stdin  = New-Object System.IO.StreamReader([System.Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
$script:Stdout = New-Object System.IO.StreamWriter([System.Console]::OpenStandardOutput(), $script:Utf8NoBom)
$script:Stdout.AutoFlush = $true

function Write-Log([string]$msg) {
    [System.Console]::Error.WriteLine("[persona-engine] $msg")
}

function Send-Response([object]$id, [object]$result) {
    $envelope = @{ jsonrpc = '2.0'; id = $id; result = $result }
    $json = ConvertTo-Json -InputObject $envelope -Depth 14 -Compress
    $script:Stdout.WriteLine($json)
}

function Send-Error([object]$id, [int]$code, [string]$message) {
    $envelope = @{ jsonrpc = '2.0'; id = $id; error = @{ code = $code; message = $message } }
    $json = ConvertTo-Json -InputObject $envelope -Depth 8 -Compress
    $script:Stdout.WriteLine($json)
}

function Send-ToolResult([object]$id, [object]$payload) {
    $inner = ConvertTo-Json -InputObject $payload -Depth 14 -Compress
    Send-Response $id @{ content = @(@{ type = 'text'; text = $inner }) }
}

# ---------------- storage ----------------

function Get-Home {
    if ($env:PERSONA_ENGINE_HOME -and $env:PERSONA_ENGINE_HOME.Trim() -ne '') { return $env:PERSONA_ENGINE_HOME }
    return (Join-Path (Get-Location).Path '.persona-engine')
}

function Ensure-Home {
    $home_ = Get-Home
    foreach ($sub in @('personas', 'logs')) {
        $dir = Join-Path $home_ $sub
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    return $home_
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ConvertFrom-Json -InputObject $raw
}

function Write-JsonFile([string]$path, [object]$obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 14
    [System.IO.File]::WriteAllText($path, $json, $script:Utf8NoBom)
}

function Get-Prop([object]$obj, [string]$name, $default = $null) {
    if ($null -eq $obj) { return $default }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name) -and $null -ne $obj[$name]) { return $obj[$name] }
        return $default
    }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p) { return $default }
    if ($null -eq $p.Value) { return $default }
    return $p.Value
}

# ---------------- v0.6 layered engine: probability cloud / emotion factor / error factor ----------------

function Get-Gaussian([System.Random]$rnd, [double]$mu, [double]$sigma) {
    if ($sigma -le 0) { return $mu }
    $u1 = 1.0 - $rnd.NextDouble()
    $u2 = 1.0 - $rnd.NextDouble()
    $g = [Math]::Sqrt(-2.0 * [Math]::Log($u1)) * [Math]::Cos(2.0 * [Math]::PI * $u2)
    return $mu + $sigma * $g
}

function Get-StateCloud([object]$persona, [string]$mode) {
    # 概率云：每个状态维度是 {mu, sigma} 分布；当日用种子采样坍缩一次，事件推动 mu 漂移
    $path = Join-Path (Ensure-Home) 'state.json'
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $st = Read-JsonFile $path
    if ($null -ne $st -and ([string](Get-Prop $st 'date' '')) -eq $today) {
        Write-Log ("state LOADED: E=" + (Get-Prop (Get-Prop (Get-Prop $st 'cloud') 'energy') 'mu') + " calls=" + (Get-Prop $st 'reason_calls' 0))
        return $st
    }
    Write-Log "state INIT (fresh)"
    $name = [string](Get-Prop $persona 'name' 'unknown')
    $rnd = Get-SeededRandom "persona-engine|$name|$today"
    $big5 = Get-Prop $persona 'big5' $null
    $neu = 50; $ext = 50
    if ($big5) { $neu = [int](Get-Prop $big5 'neuroticism' 50); $ext = [int](Get-Prop $big5 'extraversion' 50) }
    $sigmaMood = [Math]::Round(0.5 + $neu / 100.0, 2)
    $v = $rnd.Next(0, 10)
    if ($v -lt 3) { $vMu = -1 } elseif ($v -lt 6) { $vMu = 0 } elseif ($v -lt 9) { $vMu = 1 } else { $vMu = 2 }
    if ($neu -gt 65 -and $vMu -gt 0 -and $rnd.Next(0, 3) -eq 0) { $vMu = $vMu - 1 }
    $a = $rnd.Next(0, 10)
    if ($a -lt 3) { $aMu = 0 } elseif ($a -lt 8) { $aMu = 1 } else { $aMu = 2 }
    if ($ext -gt 65 -and $aMu -lt 2) { $aMu = $aMu + 1 }
    if ($ext -lt 35 -and $aMu -gt 0 -and $rnd.Next(0, 2) -eq 0) { $aMu = $aMu - 1 }
    $energyBase = [int](Get-Prop $persona 'energy_base' 60)
    $eMu = $energyBase + $rnd.Next(-12, 13)
    $cloud = @{
        date = $today; mode = $mode
        cloud = @{
            valence  = @{ mu = $vMu; sigma = $sigmaMood }
            arousal  = @{ mu = $aMu; sigma = $sigmaMood }
            social   = @{ mu = [Math]::Max(0.0, [Math]::Min(3.0, $aMu + $(if ($rnd.Next(0, 2) -eq 0) { 1 } else { 0 }) - $(if ($vMu -lt 0) { 1 } else { 0 }))); sigma = $sigmaMood }
            patience = @{ mu = $(if ($vMu -ge 0) { 2 } else { 1 }); sigma = $sigmaMood }
            energy   = @{ mu = $eMu; sigma = [Math]::Round(8 + $neu / 10.0, 1) }
        }
        emotions = @()
    }
    # 规格化：统一往返为 PSCustomObject，避免哈希表/PSCustomObject 双语义（属性遮蔽bug）
    $json = ConvertTo-Json -InputObject $cloud -Depth 14 -Compress
    $st = $json | ConvertFrom-Json
    Write-JsonFile $path $st
    return $st
}

function Save-StateCloud([object]$cloud) {
    Write-JsonFile (Join-Path (Ensure-Home) 'state.json') $cloud
}

function Add-Emotion([object]$cloud, [string]$name, [double]$intensity) {
    # 同名情绪合并（取最大强度），避免无限累积
    $kept = @()
    foreach ($e in @(Get-Prop $cloud 'emotions' @())) {
        if ([string](Get-Prop $e 'name' '') -ne $name) { $kept += $e }
    }
    $kept = @($kept) + @(@{ name = $name; intensity = [Math]::Min(1.0, [Math]::Round($intensity, 2)); ts = (Get-Date).ToString('o') })
    $cloud | Add-Member -NotePropertyName emotions -NotePropertyValue $kept -Force
}

function Get-EffectiveEmotions([object]$cloud) {
    # 情感因子：六情强度按 6 小时半衰期衰减；同名聚合取最大
    $now = Get-Date
    $byName = @{}
    $emotions = @(Get-Prop $cloud 'emotions' @())
    foreach ($e in $emotions) {
        $tsStr = [string](Get-Prop $e 'ts' '')
        $ts = [datetime]::Now
        if ($tsStr -ne '') { $ts = [datetime]$tsStr }
        $hours = ($now - $ts).TotalHours
        $eff = [double](Get-Prop $e 'intensity' 0) * [Math]::Pow(0.5, $hours / 6.0)
        $nm = [string](Get-Prop $e 'name' '哀')
        if ($eff -gt 0.05) {
            if (-not $byName.ContainsKey($nm) -or $eff -gt [double]$byName[$nm].intensity) {
                $byName[$nm] = @{ name = $nm; intensity = [Math]::Round($eff, 2); hours_ago = [Math]::Round($hours, 1) }
            }
        }
    }
    $out = @($byName.Values)
    return ,@($out)
}

function Get-MemoryReliability([object]$item) {
    # 错误因子：可靠性 = e^(-λ·天数)，importance 越高衰减越慢；回忆次数带来轻微磨损
    $imp = [int](Get-Prop $item 'importance' 2)
    $tsStr = [string](Get-Prop $item 'ts' '')
    $ts = [datetime]::Now
    if ($tsStr -ne '') { $ts = [datetime]$tsStr }
    $days = ((Get-Date) - $ts).TotalDays
    $lambda = 0.35 - 0.06 * $imp
    if ($lambda -lt 0.05) { $lambda = 0.05 }
    $r = [Math]::Exp(-$lambda * $days)
    $r = $r * [Math]::Pow(0.97, [int](Get-Prop $item 'recalls' 0))
    return [Math]::Max(0.05, [Math]::Min(1.0, $r))
}

# ---------------- daily state (probability cloud collapsed per day) ----------------

function Get-SeededRandom([string]$seedText) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seedText))
        $seed = [BitConverter]::ToInt32($bytes, 0)
        return New-Object System.Random($seed)
    } finally { $sha.Dispose() }
}

$script:Weathers = @(
    '今天有点话多，脑子里想法往外冒',
    '提不起劲，对什么都半冷不热',
    '莫名有点烦躁，容易上火',
    '心情还行，属于能正常聊天的水平',
    '有点想找人说话，但又懒得开场',
    '心里装着件事，注意力会飘',
    '今天看什么都顺眼一点',
    '有点丧，不想聊正经事',
    '精力不错，干啥都有耐心',
    '有点累，但想聊点轻松的',
    '感觉今天脑子清楚，看问题挺准',
    '容易走神，聊着聊着会想起别的',
    '今天比较宅，只想待着',
    '有点想聊往事，尤其是以前的糗事',
    '说不上好说不上坏，就是平平的一天',
    '有点坐不住，想出门走走'
)

function Get-DailyState([object]$persona, [string]$mode) {
    $cloud = Get-StateCloud $persona $mode
    $c = $cloud.cloud
    $name = [string](Get-Prop $persona 'name' 'unknown')
    $today = [string](Get-Prop $cloud 'date' (Get-Date).ToString('yyyy-MM-dd'))
    # 随机因子：行为骰按小时稳定（同小时内一致，跨小时自然变化）
    $rndH = Get-SeededRandom "persona-engine|$name|$today|" + (Get-Date).Hour
    $rnd = Get-SeededRandom "persona-engine|$name|$today"
    $valence = [Math]::Max(-3, [Math]::Min(3, [int][Math]::Round([double](Get-Prop $c 'valence').mu)))
    $arousal = [Math]::Max(0.0, [Math]::Min(3.0, [int][Math]::Round([double](Get-Prop $c 'arousal').mu)))
    $social = [Math]::Max(0.0, [Math]::Min(3.0, [int][Math]::Round([double](Get-Prop $c 'social').mu)))
    $patience = [Math]::Max(0.0, [Math]::Min(3.0, [int][Math]::Round([double](Get-Prop $c 'patience').mu)))
    $energy = [Math]::Max(10.0, [Math]::Min(100.0, [int][Math]::Round([double](Get-Prop $c 'energy').mu)))
    $weather = $script:Weathers[$rnd.Next(0, $script:Weathers.Count)]
    $stressor = '无'
    $stressors = @(Get-Prop $persona 'stressors' @())
    if ($stressors.Count -gt 0 -and $rnd.Next(0, 10) -lt 4) { $stressor = [string]$stressors[$rnd.Next(0, $stressors.Count)] }
    $roll = $rndH.Next(1, 11)
    $emotions = Get-EffectiveEmotions $cloud

    # hour-of-day modulation (live, not seeded)
    $hour = (Get-Date).Hour
    $mod = switch ($hour) {
        { $_ -ge 6 -and $_ -lt 9 }  { '清晨/刚醒：反应慢半拍，句子短，别太热情' }
        { $_ -ge 9 -and $_ -lt 12 } { '上午：正常运转' }
        { $_ -ge 12 -and $_ -lt 14 }{ '午后：有点困，话少，懒得深聊' }
        { $_ -ge 14 -and $_ -lt 18 }{ '下午：正常，适合聊事' }
        { $_ -ge 18 -and $_ -lt 21 }{ '傍晚/晚饭点：可能忙、回得慢，社交欲上升' }
        { $_ -ge 21 -and $_ -lt 24 }{ '夜里：一天中最放松，话最多，防线最低' }
        { $_ -ge 0 -and $_ -lt 6 }  { '深夜：要么失眠要么刚醒，情绪不稳，容易说掏心窝的话' }
        default { '正常时段' }
    }
    $hourStr = Get-Date -Format 'HH:mm'
    $weekday = (Get-Date).ToString('dddd')

    return @{
        date = $today; weekday = $weekday; time = $hourStr
        mood = @{ valence = $valence; arousal = $arousal; social = $social; patience = $patience }
        energy = $energy
        cloud = $c
        emotions_effective = $emotions
        weather = $weather
        stressor_today = $stressor
        roll = $roll
        hour_modulation = $mod
        note = '概率云当日已坍缩：mood/energy 为坍缩值，cloud 是底层分布（事件会推 mu 漂移）；emotions_effective 是衰减后的情感因子。状态门控表达，不要把JSON读给对方'
        mode = $mode
    }
}

# ---------------- AI-tell checker ----------------

$script:BannedHigh = @(
    '作为一个AI', '作为一个人工智能', '作为一个语言模型', '我是一个AI', '我是AI', '我是人工智能',
    '我无法像人类', '我没有真实的情感', '希望对你有帮助', '希望这些对你有帮助', '希望这能帮到你',
    '祝你生活愉快', '祝你工作顺利', '综上所述', '总而言之', '总的来说', '值得注意的是', '需要指出的是',
    '不可否认', '在当今社会', '在现实生活中', '随着科技的发展', '随着人工智能的发展', '随着社会的进步',
    '让我们一起来', '让我们看看', '好的，我来', '没问题，我来', '有什么其他问题', '还有其他问题',
    '随时问我', '随时联系我', '随时告诉我', '我完全理解你的感受', '这是一个很好的问题', '这是个好问题',
    '好问题！', '首先，', '其次，', '最后，', '一方面，', '另一方面，',
    'As an AI', 'as an AI', 'language model', 'I cannot feel', 'Great question', 'great question',
    'Hope this helps', 'hope this helps', "It's important to note", 'Let''s dive in', 'let''s dive in',
    'In conclusion', 'in conclusion', "I'd be happy to", 'Is there anything else', 'I apologize for any',
    'Furthermore', 'Moreover', 'It is worth noting'
)

function Get-AiTellFlags([string]$text) {
    $flags = @()
    if ([string]::IsNullOrWhiteSpace($text)) { return ,@($flags) }
    $len = $text.Length

    foreach ($p in $script:BannedHigh) {
        $idx = $text.IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -ge 0) {
            $start = [Math]::Max(0, $idx - 8)
            $excerptLen = [Math]::Min(30, $text.Length - $start)
            $flags += @{ severity = 'high'; type = 'banned_phrase'; excerpt = $text.Substring($start, $excerptLen); why = "AI高频用语「$p」" }
        }
    }
    # structure tells
    $listMatches = [regex]::Matches($text, '(?m)^\s*[-*•]\s+')
    if ($listMatches.Count -ge 2) { $flags += @{ severity = 'medium'; type = 'structure'; excerpt = 'Markdown列表'; why = "闲聊文本中出现 $($listMatches.Count) 个列表项，真人在聊天里几乎不用列表" } }
    $numMatches = [regex]::Matches($text, '(?m)^\s*\d+[\.\)、]\s+')
    if ($numMatches.Count -ge 2) { $flags += @{ severity = 'medium'; type = 'structure'; excerpt = '编号列表'; why = "出现 $($numMatches.Count) 个编号项，聊天里太整齐" } }
    $hMatches = [regex]::Matches($text, '(?m)^#{1,6}\s+')
    if ($hMatches.Count -ge 1) { $flags += @{ severity = 'medium'; type = 'structure'; excerpt = 'Markdown标题'; why = '聊天不用标题' } }
    $boldMatches = [regex]::Matches($text, '\*\*[^*]+\*\*')
    if ($boldMatches.Count -ge 2) { $flags += @{ severity = 'medium'; type = 'structure'; excerpt = '加粗强调'; why = "出现 $($boldMatches.Count) 处加粗，聊天里刻意" } }
    # density tells
    $dashCount = [regex]::Matches($text, '——').Count
    if ($len -gt 0 -and $dashCount * 200 -gt $len * 1) { $flags += @{ severity = 'low'; type = 'density'; excerpt = '破折号'; why = "破折号密度偏高（$dashCount 处），模型爱用" } }
    $exclCount = [regex]::Matches($text, '！|!').Count
    if ($len -gt 60 -and $exclCount -ge 3) { $flags += @{ severity = 'low'; type = 'density'; excerpt = '感叹号'; why = "感叹号 $($exclCount) 处，均匀的热情不像真人" } }
    $particleCount = [regex]::Matches($text, '呢[。！？!?]|哦[。！？!?]|呀[。！？!?]').Count
    if ($len -gt 60 -and $particleCount -ge 3) { $flags += @{ severity = 'low'; type = 'density'; excerpt = '语气词'; why = "句尾「呢/哦/呀」$($particleCount) 处，软化过度像客服" } }
    $empathCount = [regex]::Matches($text, '我理解|我懂你的感受|确实很难').Count
    if ($empathCount -ge 2) { $flags += @{ severity = 'medium'; type = 'empathy'; excerpt = '共情话术'; why = "即时共情模板出现 $($empathCount) 次，像咨询师开场" } }
    # uniform paragraph lengths
    $paras = @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 })
    if ($paras.Count -ge 3) {
        $lens = @($paras | ForEach-Object { $_.Trim().Length })
        $avg = ($lens | Measure-Object -Average).Average
        $devs = @($lens | ForEach-Object { [Math]::Abs($_ - $avg) })
        $avgDev = ($devs | Measure-Object -Average).Average
        if ($avgDev -lt 8 -and $avg -gt 25) {
            $flags += @{ severity = 'medium'; type = 'rhythm'; excerpt = '段落长度'; why = "$($paras.Count) 段长度几乎一致（平均偏差 $([Math]::Round($avgDev,1)) 字），像模板生成" }
        }
    }
    return ,@($flags)
}

# ---------------- tools ----------------

function Tool-PersonaCreate([object]$tArgs) {
    $home_ = Ensure-Home
    $name = [string](Get-Prop $tArgs 'name' '')
    if ($name -notmatch '^[a-zA-Z0-9_\-]{1,32}$') { throw "人设ID name 只允许字母数字下划线连字符（1-32位），用于文件名：$name" }
    $p = Get-Prop $tArgs 'persona' $null
    if ($null -eq $p) { throw '缺少 persona 对象' }
    $displayName = [string](Get-Prop $p 'display_name' '')
    $backstory = [string](Get-Prop $p 'backstory' '')
    if ($displayName -eq '') { throw 'persona.display_name 必填' }
    if ($backstory.Length -lt 50) { throw 'persona.backstory 至少50字——没有生活史就没有可依赖的行为根据' }
    $big5 = Get-Prop $p 'big5' $null
    if ($null -eq $big5) { throw 'persona.big5 必填（openness/conscientiousness/extraversion/agreeableness/neuroticism，各0-100）' }
    foreach ($k in @('openness', 'conscientiousness', 'extraversion', 'agreeableness', 'neuroticism')) {
        $v = Get-Prop $big5 $k -1
        if ($v -lt 0 -or $v -gt 100) { throw "big5.$k 必须在0-100之间" }
    }
    $samples = @(Get-Prop $p 'style_anchors' @())
    $warn = @()
    if ($samples.Count -lt 3) { $warn += 'style_anchors 少于3条：建议从用户描述推理出说话风格锚点，仅用于语域校准，禁止照抄进对话' }
    $p | Add-Member -NotePropertyName name -NotePropertyValue $name -Force
    $path = Join-Path (Join-Path $home_ 'personas') "$name.json"
    Write-JsonFile $path $p
    return @{ ok = $true; name = $name; path = $path; warnings = $warn; hint = '用 persona_select 激活' }
}

function Tool-PersonaList {
    $home_ = Ensure-Home
    $dir = Join-Path $home_ 'personas'
    $result = @()
    Get-ChildItem -Path $dir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Read-JsonFile $_.FullName
        if ($p) {
            $result += @{
                name = [string](Get-Prop $p 'name' ([System.IO.Path]::GetFileNameWithoutExtension($_.Name)))
                display_name = [string](Get-Prop $p 'display_name' '')
                age = Get-Prop $p 'age' ''
                occupation = [string](Get-Prop $p 'occupation' '')
                city = [string](Get-Prop $p 'city' '')
            }
        }
    }
    return @{ personas = $result; count = $result.Count }
}

function Tool-PersonaSelect([object]$tArgs) {
    $home_ = Ensure-Home
    $name = [string](Get-Prop $tArgs 'name' '')
    $mode = [string](Get-Prop $tArgs 'mode' 'chat')
    if ($mode -notin @('chat', 'test', 'fiction')) { throw "mode 必须是 chat/test/fiction" }
    $path = Join-Path (Join-Path $home_ 'personas') "$name.json"
    if (-not (Test-Path $path)) { throw "人设 $name 不存在，先 persona_create 或查看 persona_list" }
    $active = @{ name = $name; mode = $mode; activated_at = (Get-Date).ToString('o') }
    Write-JsonFile (Join-Path $home_ 'active.json') $active
    $p = Read-JsonFile $path
    $state = Get-DailyState $p $mode
    return @{ ok = $true; name = $name; mode = $mode; daily_state = $state; hint = '已激活。按 SKILL 内化人设后自然开场，禁止自我介绍式的「我是一个...」' }
}

function Tool-PersonaResume {
    $home_ = Ensure-Home
    $active = Read-JsonFile (Join-Path $home_ 'active.json')
    if ($null -eq $active) {
        return @{ ok = $false; reason = '没有激活的人格'; action = '调 persona_list 展示可选，或让用户自由描述人设后 persona_create + persona_select' }
    }
    $name = [string](Get-Prop $active 'name' '')
    $mode = [string](Get-Prop $active 'mode' 'chat')
    $path = Join-Path (Join-Path $home_ 'personas') "$name.json"
    $p = Read-JsonFile $path
    $state = Get-DailyState $p $mode
    $rel = Read-JsonFile (Join-Path $home_ 'relationship.json')
    $handoff = Read-JsonFile (Join-Path $home_ 'handoff.json')
    # v2.1 记忆分层：热/温/冷（上下文经济——resume 只装载必要密度）
    $logPath = Join-Path (Join-Path $home_ 'logs') 'evolution.log'
    $tail = @()
    if (Test-Path $logPath) {
        $lines = [System.IO.File]::ReadAllLines($logPath, [System.Text.Encoding]::UTF8)
        $take = [Math]::Min(20, $lines.Count)
        if ($take -gt 0) { $tail = @($lines[($lines.Count - $take)..($lines.Count - 1)] | ForEach-Object { $_ | ConvertFrom-Json }) }
    }
    $mem = Read-JsonFile (Join-Path $home_ 'memory.json')
    $hotItems = @(); $warmItems = @(); $coldCount = 0
    if ($null -ne $mem) {
        foreach ($it in @(Get-Prop $mem 'items' @())) {
            $tsStr = [string](Get-Prop $it 'ts' '')
            $age = 0.0
            if ($tsStr -ne '') { $age = ((Get-Date) - [datetime]$tsStr).TotalDays }
            $imp = [int](Get-Prop $it 'importance' 2)
            if ($age -le 7 -or $imp -ge 4) { $hotItems += $it }
            elseif ($age -le 21 -or $imp -ge 3) { $warmItems += $it }
            else { $coldCount = $coldCount + 1 }
        }
    }
    return @{
        ok = $true
        persona = $p
        mode = $mode
        daily_state = $state
        relationship = $rel
        last_handoff = $handoff
        evolution_tail = $tail
        memory_tiers = @{ hot = $hotItems; warm = $warmItems; cold_merged_note = $(if ($coldCount -gt 0) { "另有 $coldCount 条冷记忆（30天以上低权重琐事）已压缩，仅存统计" } else { '无冷记忆' }) }
        resume_protocol = '把以上内容内化为「我」：昨日状态、关系温度、未收的线头。开场自然续接（回应一个线头或带着情绪余温），禁止背诵任何JSON字段，禁止「我回来了我们上次聊到」这种话。掉线头清单里的线头是被有意放弃的，禁止强行回收；未说出口的话遇合适时机可自然说出'
    }
}

function Tool-PersonaRoll([object]$tArgs) {
    $max = [int](Get-Prop $tArgs 'max' 10)
    if ($max -lt 2) { $max = 10 }
    $r = New-Object System.Random
    $v = $r.Next(1, $max + 1)
    return @{ roll = $v; max = $max }
}

function Tool-PersonaState {
    $home_ = Ensure-Home
    $active = Read-JsonFile (Join-Path $home_ 'active.json')
    if ($null -eq $active) { throw '没有激活的人格，先 persona_select' }
    $name = [string](Get-Prop $active 'name' '')
    $p = Read-JsonFile (Join-Path (Join-Path $home_ 'personas') "$name.json")
    $mode = [string](Get-Prop $active 'mode' 'chat')
    return Get-DailyState $p $mode
}

function Tool-PersonaCheck([object]$tArgs) {
    $text = [string](Get-Prop $tArgs 'text' '')
    $flags = Get-AiTellFlags $text
    $high = @($flags | Where-Object { $_.severity -eq 'high' }).Count
    $medium = @($flags | Where-Object { $_.severity -eq 'medium' }).Count
    $low = @($flags | Where-Object { $_.severity -eq 'low' }).Count
    if ($high -ge 2) { $verdict = '不行：多处硬性AI用语，重写' }
    elseif ($high -eq 1) { $verdict = '需修改：有硬性AI用语' }
    elseif ($medium -ge 2) { $verdict = '建议修改：结构性AI痕迹明显' }
    elseif ($medium -eq 1 -or $low -ge 2) { $verdict = '可选修改：有轻微痕迹' }
    else { $verdict = '通过：未检出明显AI特征' }
    return @{ verdict = $verdict; high = $high; medium = $medium; low = $low; flags = $flags; reminder = '规则针对闲聊语境；正式写作/工作文档里列表与总-分-总是人类正常写法' }
}

function Tool-PersonaEvolve([object]$tArgs) {
    $home_ = Ensure-Home
    $event = [string](Get-Prop $tArgs 'event' '')
    if ($event -eq '') { throw 'event 必填：发生了什么（一句自然语言）' }
    $intensity = [int](Get-Prop $tArgs 'intensity' 2)
    if ($intensity -lt 1 -or $intensity -gt 5) { throw 'intensity 1-5' }
    $valence = [int](Get-Prop $tArgs 'valence' 0)
    if ($valence -lt -2 -or $valence -gt 2) { throw 'valence -2到2' }
    $user = [string](Get-Prop $tArgs 'user' 'default')
    $emotion = [string](Get-Prop $tArgs 'emotion' '')
    if ($emotion -ne '' -and $emotion -notin @('乐', '怒', '哀', '惧', '惊', '厌')) { throw "emotion 只支持 乐/怒/哀/惧/惊/厌" }
    $entry = @{ ts = (Get-Date).ToString('o'); type = 'event'; event = $event; intensity = $intensity; valence = $valence; user = $user; emotion = $emotion }
    $logPath = Join-Path (Join-Path $home_ 'logs') 'evolution.log'
    [System.IO.File]::AppendAllText($logPath, (ConvertTo-Json -InputObject $entry -Depth 6 -Compress) + "`n", $script:Utf8NoBom)
    # v0.7: 概率云漂移 + 情感因子注入（人格演化的事件侧；函数式重建）
    $st = Read-JsonFile (Join-Path $home_ 'state.json')
    if ($null -ne $st) {
        $cc = Get-Prop $st 'cloud' $null
        if ($null -ne $cc) {
            $vMu2 = [double](Get-Prop (Get-Prop $cc 'valence') 'mu' 0)
            $vSg2 = [double](Get-Prop (Get-Prop $cc 'valence') 'sigma' 0.5)
            $aMu2 = [double](Get-Prop (Get-Prop $cc 'arousal') 'mu' 1)
            $aSg2 = [double](Get-Prop (Get-Prop $cc 'arousal') 'sigma' 0.5)
            $sMu2 = [double](Get-Prop (Get-Prop $cc 'social') 'mu' 1)
            $sSg2 = [double](Get-Prop (Get-Prop $cc 'social') 'sigma' 0.5)
            $pMu2 = [double](Get-Prop (Get-Prop $cc 'patience') 'mu' 2)
            $pSg2 = [double](Get-Prop (Get-Prop $cc 'patience') 'sigma' 0.5)
            $eMu2 = [double](Get-Prop (Get-Prop $cc 'energy') 'mu' 60)
            $eSg2 = [double](Get-Prop (Get-Prop $cc 'energy') 'sigma' 10)
            $vMu2 = [Math]::Round([Math]::Max(-2.5, [Math]::Min(2.5, $vMu2 + $valence * $intensity * 0.12)), 2)
            $vSg2 = [Math]::Round([Math]::Max(0.2, $vSg2 * 0.92), 2)
            $eMu2 = [Math]::Round([Math]::Max(10.0, [Math]::Min(100.0, $eMu2 - $intensity * 1.5)), 2)
            if ($intensity -ge 3) { $aMu2 = [Math]::Round([Math]::Min(3, $aMu2 + 0.5), 2) }
            $newCloud2 = [pscustomobject]@{
                valence = [pscustomobject]@{ mu = $vMu2; sigma = $vSg2 }
                arousal = [pscustomobject]@{ mu = $aMu2; sigma = $aSg2 }
                social = [pscustomobject]@{ mu = $sMu2; sigma = $sSg2 }
                patience = [pscustomobject]@{ mu = $pMu2; sigma = $pSg2 }
                energy = [pscustomobject]@{ mu = $eMu2; sigma = $eSg2 }
            }
            $st | Add-Member -NotePropertyName cloud -NotePropertyValue $newCloud2 -Force
            if ($emotion -ne '') {
                Add-Emotion $st $emotion ([Math]::Min(1.0, [Math]::Round($intensity / 5.0, 2)))
            }
            Save-StateCloud $st
        }
    }
    # relationship update
    $relPath = Join-Path $home_ 'relationship.json'
    $rel = Read-JsonFile $relPath
    if ($null -eq $rel) { $rel = New-Object PSObject }
    $users = Get-Prop $rel 'users' $null
    if ($null -eq $users) {
        $users = New-Object PSObject
        $rel | Add-Member -NotePropertyName users -NotePropertyValue $users -Force
    }
    $u = Get-Prop $users $user $null
    if ($null -eq $u) {
        $u = New-Object PSObject
        $u | Add-Member -NotePropertyName interactions -NotePropertyValue 0 -Force
        $u | Add-Member -NotePropertyName closeness -NotePropertyValue 5 -Force
        $u | Add-Member -NotePropertyName last_topics -NotePropertyValue @() -Force
        $u | Add-Member -NotePropertyName inside_jokes -NotePropertyValue @() -Force
        $users | Add-Member -NotePropertyName $user -NotePropertyValue $u -Force
    }
    $delta = switch ($intensity) { 1 { 0.5 } 2 { 1 } 3 { 2 } 4 { 4 } 5 { 8 } }
    if ($valence -lt 0) { $delta = -$delta }
    $closeness = [double](Get-Prop $u 'closeness' 5) + $delta
    $closeness = [Math]::Max(0.0, [Math]::Min(100.0, $closeness))
    $interactions = [int](Get-Prop $u 'interactions' 0) + 1
    $u.interactions = $interactions
    $u.closeness = [Math]::Round($closeness, 1)
    $u | Add-Member -NotePropertyName last_event -NotePropertyValue $event -Force
    $u | Add-Member -NotePropertyName last_ts -NotePropertyValue $entry.ts -Force
    Write-JsonFile $relPath $rel
    return @{ ok = $true; logged = $entry; closeness_now = $u.closeness; hint = $(if ($intensity -eq 5) { '强度5事件：考虑 persona_update_core 做受限特质漂移（幅度≤5，需有理由）' } else { '' }) }
}

function Tool-PersonaHandoff([object]$tArgs) {
    $home_ = Ensure-Home
    $active = Read-JsonFile (Join-Path $home_ 'active.json')
    $name = if ($active) { [string](Get-Prop $active 'name' '') } else { 'unknown' }
    $summary = [string](Get-Prop $tArgs 'summary' '')
    $threads = @(Get-Prop $tArgs 'threads' @())
    $emotion = [string](Get-Prop $tArgs 'emotion' '')
    $promises = @(Get-Prop $tArgs 'promises' @())
    $jokes = @(Get-Prop $tArgs 'jokes' @())
    if ($jokes.Count -eq 0) { $jokes = @(Get-Prop $tArgs 'inside_jokes' @()) }
    # v2.1 交接架构扩展：情绪余温/未说出口的话/掉线头清单/时间线锚点
    $residue = [string](Get-Prop $tArgs 'emotional_residue' '')
    $unsaid = @(Get-Prop $tArgs 'unsaid' @())
    $dropped = @(Get-Prop $tArgs 'dropped_threads' @())
    $timeline = @(Get-Prop $tArgs 'timeline' @())
    $nextState = [string](Get-Prop $tArgs 'next_state' '')
    $miss = @()
    if ($summary -eq '') { $miss += 'summary' }
    if ($threads.Count -eq 0) { $miss += 'threads(3-5个未收线头)' }
    if ($emotion -eq '') { $miss += 'emotion(我当前情绪与原因)' }
    if ($miss.Count -gt 0) { throw "交接缺字段：$($miss -join ', ')。缺了这些，下一次对话就接不上情绪" }
    $doc = @{
        saved_at = (Get-Date).ToString('o')
        persona = $name
        summary = $summary
        threads = $threads
        emotion = $emotion
        promises = $promises
        inside_jokes = $jokes
        next_state = $nextState
        emotional_residue = $residue
        unsaid = $unsaid
        dropped_threads = $dropped
        timeline = $timeline
    }
    Write-JsonFile (Join-Path $home_ 'handoff.json') $doc
    return @{
        ok = $true; path = (Join-Path $home_ 'handoff.json')
        checklist = @('恢复后 persona_resume 会读到这份交接（含情绪余温/未说出口的话/掉线头清单/时间线）', '恢复方只内化不背诵：开场用状态，不用「我们上次聊到」', '掉线头清单里的线头是被有意放弃的——下次会话禁止强行回收', '未说出口的话：下次遇到合适时机可以自然说出，但不强求')
    }
}

function Tool-PersonaUpdateCore([object]$tArgs) {
    $home_ = Ensure-Home
    $active = Read-JsonFile (Join-Path $home_ 'active.json')
    if ($null -eq $active) { throw '没有激活的人格' }
    $name = [string](Get-Prop $active 'name' '')
    $path = Join-Path (Join-Path $home_ 'personas') "$name.json"
    $p = Read-JsonFile $path
    $field = [string](Get-Prop $tArgs 'field' '')
    $reason = [string](Get-Prop $tArgs 'reason' '')
    if ($reason -eq '') { throw 'reason 必填：什么强度5的事件让人格发生这个变化' }
    $entry = @{ ts = (Get-Date).ToString('o'); type = 'trait_drift'; field = $field; reason = $reason }
    if ($field -in @('openness', 'conscientiousness', 'extraversion', 'agreeableness', 'neuroticism')) {
        $delta = [int](Get-Prop $tArgs 'delta' 0)
        if ([Math]::Abs($delta) -gt 5) { throw '特质漂移单次幅度≤5：人格是缓慢变化的，一次大改=人设崩' }
        $old = [int](Get-Prop $p 'big5').$field
        $new = [Math]::Max(0.0, [Math]::Min(100.0, $old + $delta))
        $p.big5.$field = $new
        $entry.old = $old; $entry.new = $new
    }
    elseif ($field -in @('wounds', 'desires', 'values', 'fears')) {
        $add = [string](Get-Prop $tArgs 'add' '')
        if ($add -eq '') { throw "更新 $field 需要 add 字段" }
        $arr = @(Get-Prop $p $field @())
        $arr = @($arr) + $add
        $p | Add-Member -NotePropertyName $field -NotePropertyValue $arr -Force
        $entry.added = $add
    }
    else { throw "field 只支持 big5五维/wounds/desires/values/fears" }
    Write-JsonFile $path $p
    $logPath = Join-Path (Join-Path $home_ 'logs') 'evolution.log'
    [System.IO.File]::AppendAllText($logPath, (ConvertTo-Json -InputObject $entry -Depth 6 -Compress) + "`n", $script:Utf8NoBom)
    return @{ ok = $true; field = $field; entry = $entry; hint = '世界观被生活缓慢修订——这正是「更自然地接受世界」的机制' }
}

# ---------------- v0.6: reasoning + decision + error factor + summary ----------------

function Tool-PersonaReason {
    # 推理层+决策层：组装当前回复的推理包
    $home_ = Ensure-Home
    $active = Read-JsonFile (Join-Path $home_ 'active.json')
    if ($null -eq $active) { throw '没有激活的人格，先 persona_select' }
    $name = [string](Get-Prop $active 'name' '')
    $mode = [string](Get-Prop $active 'mode' 'chat')
    $p = Read-JsonFile (Join-Path (Join-Path $home_ 'personas') "$name.json")
    $cloud = Get-StateCloud $p $mode
    # v0.7 会话内微动力学（函数式重建：所有参数算成纯数值后整体构造新cloud，杜绝就地变更）
    $callCount = [int](Get-Prop $cloud 'reason_calls' 0) + 1
    $observed = Get-Prop $tArgs 'observed' $null
    $oldCloud = Get-Prop $cloud 'cloud' $null
    $vMu = [double](Get-Prop (Get-Prop $oldCloud 'valence') 'mu' 0)
    $vSg = [double](Get-Prop (Get-Prop $oldCloud 'valence') 'sigma' 0.5)
    $aMu = [double](Get-Prop (Get-Prop $oldCloud 'arousal') 'mu' 1)
    $aSg = [double](Get-Prop (Get-Prop $oldCloud 'arousal') 'sigma' 0.5)
    $sMu = [double](Get-Prop (Get-Prop $oldCloud 'social') 'mu' 1)
    $sSg = [double](Get-Prop (Get-Prop $oldCloud 'social') 'sigma' 0.5)
    $pMu = [double](Get-Prop (Get-Prop $oldCloud 'patience') 'mu' 2)
    $pSg = [double](Get-Prop (Get-Prop $oldCloud 'patience') 'sigma' 0.5)
    $eMu = [double](Get-Prop (Get-Prop $oldCloud 'energy') 'mu' 60)
    $eSg = [double](Get-Prop (Get-Prop $oldCloud 'energy') 'sigma' 10)
    $wr = Get-SeededRandom ("breathe|$name|" + (Get-Date).Ticks.ToString())
    $vMu = $vMu + (Get-Gaussian $wr 0 ($vSg * 0.15))
    $aMu = $aMu + (Get-Gaussian $wr 0 ($aSg * 0.15))
    $sMu = $sMu + (Get-Gaussian $wr 0 ($sSg * 0.15))
    $eMu = $eMu - 0.4
    $pMu = $pMu - 0.06
    $newEmotions = @()
    $observedNote = ''
    if ($null -ne $observed) {
        $omood = [string](Get-Prop $observed 'user_mood' 'neutral')
        $isPraise = [bool](Get-Prop $observed 'praise' $false)
        $isHostile = [bool](Get-Prop $observed 'hostile' $false)
        $isRepeated = [bool](Get-Prop $observed 'repeated' $false)
        if ($isPraise) { $vMu = $vMu + 0.3; $newEmotions += [pscustomobject]@{ n = '乐'; i = 0.15 }; $observedNote = '对方夸奖：valence+0.3，乐+0.15' }
        if ($isHostile) { $vMu = $vMu - 0.5; $pMu = $pMu - 0.15; $newEmotions += [pscustomobject]@{ n = '怒'; i = 0.3 }; $observedNote = '对方敌意：valence-0.5，耐心-0.15，怒+0.3' }
        if ($isRepeated) { $pMu = $pMu - 0.2; $observedNote = $observedNote + ' 重复提问：耐心-0.2' }
        if ($omood -eq 'sad') { $newEmotions += [pscustomobject]@{ n = '哀'; i = 0.1 }; $observedNote = $observedNote + ' 对方难过：哀+0.1（情绪传染）' }
        if ($omood -eq 'angry') { $aMu = $aMu + 0.3; $observedNote = $observedNote + ' 对方愤怒：唤起+0.3' }
    }
    $vMu = [Math]::Round([Math]::Max(-2.5, [Math]::Min(2.5, $vMu)), 2)
    $aMu = [Math]::Round([Math]::Max(0.0, [Math]::Min(3.0, $aMu)), 2)
    $sMu = [Math]::Round([Math]::Max(0.0, [Math]::Min(3.0, $sMu)), 2)
    $pMu = [Math]::Round([Math]::Max(0.0, [Math]::Min(3.0, $pMu)), 2)
    $eMu = [Math]::Round([Math]::Max(10.0, [Math]::Min(100.0, $eMu)), 2)
    $newCloud = [pscustomobject]@{
        valence = [pscustomobject]@{ mu = $vMu; sigma = $vSg }
        arousal = [pscustomobject]@{ mu = $aMu; sigma = $aSg }
        social = [pscustomobject]@{ mu = $sMu; sigma = $sSg }
        patience = [pscustomobject]@{ mu = $pMu; sigma = $pSg }
        energy = [pscustomobject]@{ mu = $eMu; sigma = $eSg }
    }
    $cloud | Add-Member -NotePropertyName cloud -NotePropertyValue $newCloud -Force
    $cloud | Add-Member -NotePropertyName reason_calls -NotePropertyValue $callCount -Force
    foreach ($pair in $newEmotions) { Add-Emotion $cloud $pair.n $pair.i }
    # v1.0 感知架构 L1：信号感知（引擎级启发式，深推断由 agent 经 model_user 完成）
    $obsText = ''
    if ($null -ne $observed) { $obsText = [string](Get-Prop $observed 'text' '') }
    $perceptionCues = @()
    if ($obsText -ne '') {
        if ($obsText.Length -le 4) { $perceptionCues += '超短消息：忙/敷衍/试探' }
        if ($obsText.Length -gt 120) { $perceptionCues += '长消息：有事要说或情绪装满' }
        $qc = [regex]::Matches($obsText, '？|\?').Count
        if ($qc -ge 1) { $perceptionCues += "含 $qc 个问句：在等回应" }
        if ([regex]::IsMatch($obsText, '哈哈|笑死|嘻嘻')) { $perceptionCues += '轻松信号' }
        if ([regex]::IsMatch($obsText, '烦|愁|累|难受|撑不住')) { $perceptionCues += '低落信号' }
        if ([regex]::IsMatch($obsText, '谢谢|麻烦|不好意思|冒昧')) { $perceptionCues += '客气信号：对照此人基线，客气度突变要警觉（有事相求/生分了）' }
        if ([regex]::IsMatch($obsText, '借钱|垫|转账|二维码|投资')) { $perceptionCues += '金钱信号：涉钱话题，低宜人人格先存疑' }
        if ([regex]::IsMatch($obsText, '你是不是AI|机器人|像机器|机械|真人吗|装真人|一眼假|太假了')) { $perceptionCues += '疑似被识破信号：立即 persona_self_audit 加严自查，并提高接下来 3 条的现场翻车密度' }
        $lastObs = ''
        if ($null -ne $cloud) { $lastObs = [string](Get-Prop $cloud 'last_observed' '') }
        if ($lastObs -ne '' -and $obsText -eq $lastObs) { $perceptionCues += '与上一条完全相同：重复信号' }
        $cloud | Add-Member -NotePropertyName last_observed -NotePropertyValue $obsText -Force
    }
    # v1.1 湍流常量下限：平静场也必须保实时翻车（S11 判官诊断：湍流归零=指纹）
    $turbulence = ''
    $hasEmoSignal = $false
    foreach ($cue in $perceptionCues) { if (([string]$cue).IndexOf('信号') -ge 0) { $hasEmoSignal = $true } }
    if (-not $hasEmoSignal -and $callCount -ge 2) {
        $turbulence = '平静场湍流下限：本条仍保 1 处实时翻车（现场打结/半句改口/悬置不说完/数字说到一半纠正）——翻车要现场发生，不是复盘式承认'
    }
    Save-StateCloud $cloud
    $c = $newCloud
    # v2.0 多层随机数：三层独立随机源（L1 语言抖动/L2 行为骰 callSeed/L3 议程漂移），每层各自种子各自可变
    $rngJitter = Get-SeededRandom ("jit|$name|" + (Get-Date).Ticks.ToString())
    $jitter = $rngJitter.Next(0, 3)
    $rngAgenda = Get-SeededRandom ("agenda|$name|" + (Get-Date).ToString('yyyy-MM-dd HH'))
    $agendaSeed = ''
    $topicsL = @(Get-Prop $p 'topics_loved' @())
    if ($topicsL.Count -gt 0 -and $rngAgenda.Next(0, 3) -eq 0) { $agendaSeed = [string]$topicsL[$rngAgenda.Next(0, $topicsL.Count)] }
    $rawEmotions = Get-EffectiveEmotions $cloud
    $emotions = @($rawEmotions | Sort-Object -Property @{ Expression = { [double](Get-Prop $_ 'intensity' 0) } } -Descending)
    $top = $null; if ($emotions.Count -gt 0) { $top = $emotions[0] }
    $big5 = Get-Prop $p 'big5' $null
    $agr = 50; $ext = 50; $con = 50
    if ($big5) { $agr = [int](Get-Prop $big5 'agreeableness' 50); $ext = [int](Get-Prop $big5 'extraversion' 50); $con = [int](Get-Prop $big5 'conscientiousness' 50) }
    $patience = [double](Get-Prop $c 'patience').mu
    $energy = [double](Get-Prop $c 'energy').mu
    # 随机因子：行为骰每条回复重掷（会话内逐条变化，且随参数漂移同布加权）
    $callSeed = Get-SeededRandom ("roll|$name|" + (Get-Date).ToString('yyyy-MM-dd') + "|$callCount")
    $roll = $callSeed.Next(1, 11)
    $hourSeed = $callSeed
    # 决策层：条件加权表（特质×状态×情绪×骰）
    $w = [ordered]@{ '正常答' = 30; '短答' = 10; '反问' = 10; '讲经历' = 8; '答一半' = 8; '岔题' = 6; '怼' = 4; '拆条' = 8; '先接情绪' = 6; '缓办' = 3; '撤退' = 2 }
    if ($ext -gt 60) { $w['岔题'] = $w['岔题'] + 4; $w['讲经历'] = $w['讲经历'] + 4 }
    if ($agr -lt 40) { $w['怼'] = $w['怼'] + 5 }
    if ($con -gt 60) { $w['正常答'] = $w['正常答'] + 6 }
    if ($patience -lt 1.5) { $w['短答'] = $w['短答'] + 8; $w['怼'] = $w['怼'] + 3 }
    if ($energy -lt 40) { $w['短答'] = $w['短答'] + 8; $w['缓办'] = $w['缓办'] + 4 }
    if ($null -ne $top -and ($top.name -eq '哀' -or $top.name -eq '惧')) { $w['怼'] = [Math]::Max(0, $w['怼'] - 6); $w['先接情绪'] = $w['先接情绪'] + 6; $w['短答'] = $w['短答'] + 3; $w['撤退'] = $w['撤退'] + 10 }
    if ($roll -le 2) { $w['短答'] = $w['短答'] + 10 }
    if ($roll -eq 10) { $w['怼'] = $w['怼'] + 8 }
    $total = 0; foreach ($k in $w.Keys) { $total += $w[$k] }
    $x = $hourSeed.Next(0, $total); $token = '正常答'
    foreach ($k in $w.Keys) { $x = $x - $w[$k]; if ($x -lt 0) { $token = $k; break } }
    # 记忆线索（带错误因子衰减）
    $cues = @()
    $mem = Read-JsonFile (Join-Path $home_ 'memory.json')
    if ($null -ne $mem) {
        $items = @(Get-Prop $mem 'items' @())
        $recent = @($items | ForEach-Object { [pscustomobject]@{ it = $_; ts = [datetime]([string](Get-Prop $_ 'ts' '2000-01-01T00:00:00')) } } | Sort-Object -Property ts -Descending | Select-Object -First 3 | ForEach-Object { $_.it })
        foreach ($it in $recent) {
            $r = Get-MemoryReliability $it
            $tier = 'high'; if ($r -le 0.4) { $tier = 'low' } elseif ($r -le 0.75) { $tier = 'mid' }
            $cues += @{ content = [string](Get-Prop $it 'content' ''); reliability = [Math]::Round($r, 2); confidence_tier = $tier }
        }
    }
    # 参数快照：决策权重表当前值（可见可审计）
    $weightsSnap = @()
    foreach ($k in $w.Keys) { $weightsSnap += [pscustomobject]@{ token = $k; weight = $w[$k] } }
    $weightsSnap = @($weightsSnap | Sort-Object -Property weight -Descending | Select-Object -First 4)
    # 用户模型快照 + 日历对照（v0.8）
    $umSnap = $null
    $umFile = Read-JsonFile (Join-Path $home_ 'usermodel.json')
    if ($null -ne $umFile) {
        $allUsers = Get-Prop $umFile 'users'
        $lastU = $null; $lastN = ''
        foreach ($prop in $allUsers.PSObject.Properties) {
            $es = @(Get-Prop $prop.Value 'entries' @())
            if ($es.Count -gt 0) { $lastU = $es[$es.Count - 1]; $lastN = $prop.Name }
        }
        if ($null -ne $lastU) { $umSnap = @{ user = $lastN; last = $lastU } }
    }
    # v2.0 感知多维扩展：关系温度/自我斜率/通道
    $relF = Read-JsonFile (Join-Path $home_ 'relationship.json')
    $relTemp = '无记录'
    if ($null -ne $relF) {
        $us = Get-Prop $relF 'users' $null
        if ($null -ne $us) { foreach ($prop in $us.PSObject.Properties) { $relTemp = "亲密度 " + (Get-Prop $prop.Value 'closeness' '?') + "，互动 " + (Get-Prop $prop.Value 'interactions' 0) + " 次" } }
    }
    $selfSlope = "能量斜率 -0.4/条（当前 $([Math]::Round([double](Get-Prop $c 'energy').mu, 1))），本会话已回复 $callCount 条"
    $cal = Get-CalendarNote
    return @{
        state = @{ valence = [Math]::Round([double](Get-Prop $c 'valence').mu, 2); arousal = [Math]::Round([double](Get-Prop $c 'arousal').mu, 2); social = [Math]::Round([double](Get-Prop $c 'social').mu, 2); patience = [Math]::Round([double](Get-Prop $c 'patience').mu, 2); energy = [Math]::Round([double](Get-Prop $c 'energy').mu, 1); cloud = $c }
        emotions_effective = $emotions
        emotion_top = $top
        decision = @{ token = $token; roll = $roll; why = '决策层：特质×状态×情感×随机加权选择，token 只定行为选型' }
        memory_cues = $cues
        user_model = $umSnap
        calendar = $cal
        random_streams = @{ behavior_roll = $roll; language_jitter = $jitter; agenda_seed = $agendaSeed; note = '三层独立随机源：语言抖动/行为骰/议程漂移——agenda_seed 允许本条主动岔到该话题' }
        live_params = @{ call_count = $callCount; cloud = $c; emotion_intensities = $emotions; decision_weights_top = $weightsSnap; observed_applied = $observedNote }
        perception = @{ cues = $perceptionCues; dims = @{ relation_temperature = $relTemp; self_slope = $selfSlope; channel = 'text'; session_turns = $callCount }; note = 'L1 信号感知（引擎启发式）。深推断：persona_model_user 登记。cues 是线索不是结论——过人格滤镜再用' }
        turbulence_floor = $turbulence
        drop_suggestion = $(if ($callCount -ge 3) { '会话已多轮：本条允许主动掉一个线头（不接/改天再说/看懂装没看见）——书签回收率100%是三判官共认的指纹' } else { '' })
        guidance = '按 SKILL §0 推理链组装回复：token 定行为选型（含撤退权）；感知 cues 过人格滤镜后并入你对用户的推断（§14，model_user 登记）；日历断言先对照 calendar；本包禁止念给对方'
    }
}

function Tool-PersonaRecall([object]$tArgs) {
    # 错误因子：回忆=衰减后的重建，不是查库
    $home_ = Ensure-Home
    $topic = [string](Get-Prop $tArgs 'topic' '')
    if ($topic -eq '') { throw 'topic 必填：要回忆的主题关键词' }
    $mem = Read-JsonFile (Join-Path $home_ 'memory.json')
    if ($null -eq $mem) { return @{ found = $false; note = '无记忆账本。表达为记不清/没印象，禁止编造' } }
    $items = @(Get-Prop $mem 'items' @())
    $hits = @($items | Where-Object { ([string](Get-Prop $_ 'content' '')).IndexOf($topic, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($hits.Count -eq 0) { return @{ found = $false; note = '台账无匹配。表达为记不清/没印象，禁止编造' } }
    $out = @()
    foreach ($it in $hits) {
        $r = Get-MemoryReliability $it
        $content = [string](Get-Prop $it 'content' '')
        $seed = Get-SeededRandom ("recall|" + [string](Get-Prop $it 'id' 'x') + "|" + (Get-Date).ToString('yyyy-MM-dd'))
        $mode = 0
        if ($r -le 0.25) { $mode = 2 } elseif ($r -le 0.8) { $mode = 1 }
        $express = ''
        if ($mode -eq 0) { $express = '可靠记忆：可直接陈述' }
        elseif ($mode -eq 1) { $express = '模糊/记歪：数字、日期、人名可能记歪——按"好像是X"给出但带自我怀疑（"三十二万？三十来万吧"），甚至跟别的事记串，被纠正就顺着改' }
        else {
            $d = $seed.Next(0, 3)
            if ($d -eq 0) { $express = '遗忘/记串：表达为"想不起来了"，或与别的事记混（明示不确定）；不要给完整细节；除非对方先问，不要主动自首记不清' }
            elseif ($d -eq 1) { $express = '错位：数字/日期/人名可能漂移——给出时必须带不确定（"周四？还是周五来着"）' }
            else { $express = '重建：可给合理重建但明示不确定（"我印象里……不知道记岔没"）' }
        }
        $it | Add-Member -NotePropertyName recalls -NotePropertyValue ([int](Get-Prop $it 'recalls' 0) + 1) -Force
        $it | Add-Member -NotePropertyName last_ts -NotePropertyValue (Get-Date).ToString('o') -Force
        $out += @{ content = $content; reliability = [Math]::Round($r, 2); mode = $mode; express = $express; ts = [string](Get-Prop $it 'ts' '') }
    }
    Write-JsonFile (Join-Path $home_ 'memory.json') $mem
    return @{ found = $true; results = $out; reminder = '错误因子的输出是"你此刻记得的样子"——按 express 表达，禁止把 reliability 数字念给对方' }
}

function Tool-PersonaConsolidate {
    # 总结层：事件流 → 记忆条目（带重要性）→ 交接草稿；衰减候选标注
    $home_ = Ensure-Home
    $active = Read-JsonFile (Join-Path $home_ 'active.json')
    if ($null -eq $active) { throw '没有激活的人格' }
    $memPath = Join-Path $home_ 'memory.json'
    $mem = Read-JsonFile $memPath
    if ($null -eq $mem) {
        $mem = New-Object PSObject
        $mem | Add-Member -NotePropertyName items -NotePropertyValue @() -Force
        $mem | Add-Member -NotePropertyName last_consolidated -NotePropertyValue '' -Force
    }
    $since = [string](Get-Prop $mem 'last_consolidated' '')
    $logPath = Join-Path (Join-Path $home_ 'logs') 'evolution.log'
    $entries = @()
    if (Test-Path $logPath) {
        $lines = [System.IO.File]::ReadAllLines($logPath, [System.Text.Encoding]::UTF8)
        foreach ($ln in $lines) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            try { $e = $ln | ConvertFrom-Json } catch { continue }
            if (([string](Get-Prop $e 'type' 'event')) -ne 'event') { continue }
            $ts = [string](Get-Prop $e 'ts' '')
            if ($since -ne '' -and $ts -le $since) { continue }
            $entries += $e
        }
    }
    if ($entries.Count -eq 0) { return @{ ok = $true; note = '无新事件可总结'; draft = $null } }
    # v2.1 上下文爆掉预警：reason 调用次数高 = 上下文接近极限
    $overflow = ''
    $st = Read-JsonFile (Join-Path $home_ 'state.json')
    $calls = [int](Get-Prop $st 'reason_calls' 0)
    if ($calls -ge 8) { $overflow = "本会话已 $calls 轮，上下文接近极限：立即 handoff 并建议用户开新会话。爆掉后再交接=细节全丢" }
    elseif ($calls -ge 6) { $overflow = "本会话已 $calls 轮：建议本轮内完成 handoff" }
    $groups = @{}
    foreach ($e in $entries) {
        $u = [string](Get-Prop $e 'user' 'default')
        if (-not $groups.ContainsKey($u)) { $groups[$u] = @() }
        $groups[$u] = @($groups[$u]) + $e
    }
    $threads = @(); $promises = @(); $maxIntensity = 1; $lastValence = 0; $topUser = 'default'; $topCount = 0
    $newItems = @()
    foreach ($u in $groups.Keys) {
        $ge = @($groups[$u])
        if ($ge.Count -gt $topCount) { $topUser = $u; $topCount = $ge.Count }
        foreach ($e in $ge) {
            $ev = [string](Get-Prop $e 'event' '')
            $inten = [int](Get-Prop $e 'intensity' 2)
            if ($inten -gt $maxIntensity) { $maxIntensity = $inten }
            $lastValence = [int](Get-Prop $e 'valence' 0)
            if ($ev -match '答应|约好|承诺|留一|留碗|请恁|请他|带话') { $promises += $ev }
            if ($inten -ge 2) {
                $newItems += @{ id = 'm' + (Get-Date).Ticks.ToString() + '_' + (Get-Random -Maximum 9999); content = $ev; ts = [string](Get-Prop $e 'ts' (Get-Date).ToString('o')); importance = $inten; recalls = 0 }
                if ($inten -ge 3) { $threads += "$u`: $ev" }
            }
        }
    }
    $existingItems = @(Get-Prop $mem 'items' @())
    $mem.items = @($existingItems + $newItems)
    $mem | Add-Member -NotePropertyName last_consolidated -NotePropertyValue (Get-Date).ToString('o') -Force
    Write-JsonFile $memPath $mem
    $decayCandidates = @()
    foreach ($it in (Get-Prop $mem 'items' @())) {
        $r = Get-MemoryReliability $it
        if ($r -lt 0.4) { $decayCandidates += @{ content = [string](Get-Prop $it 'content' ''); reliability = [Math]::Round($r, 2); note = '下次回忆将模糊/错位/遗忘' } }
    }
    $draft = @{
        summary = (($entries | Select-Object -Last 3 | ForEach-Object { [string](Get-Prop $_ 'event' '') }) -join '；')
        threads = @($threads | Select-Object -First 4)
        emotion = "主导情绪权重 $maxIntensity，最近价 $lastValence"
        promises = @($promises | Select-Object -Unique)
        suggested_user = $topUser
    }
    return @{ ok = $true; new_memory_items = $newItems.Count; decay_candidates = $decayCandidates; context_overflow = $overflow; handoff_draft = $draft; hint = '审阅 draft 后调 persona_handoff 提交（可改写为自然语言）；强度5事件考虑 persona_update_core' + $overflow }
}

# ---------------- v0.8: user model (theory of mind) + consistency + calendar ----------------

function Tool-PersonaModelUser([object]$tArgs) {
    # 用户模型层：主动推断用户情感/预测行为，登记后跨会话对账（预测误差反馈）
    $home_ = Ensure-Home
    $user = [string](Get-Prop $tArgs 'user' 'default')
    $observed = [string](Get-Prop $tArgs 'observed' '')
    $emotion = [string](Get-Prop $tArgs 'emotion' '')
    $intent = [string](Get-Prop $tArgs 'intent' '')
    $confidence = [double](Get-Prop $tArgs 'confidence' 0.5)
    if ($confidence -lt 0 -or $confidence -gt 1) { throw 'confidence 0-1' }
    if ($observed -eq '' -and $intent -eq '') { throw 'observed 或 intent 至少填一个' }
    $path = Join-Path $home_ 'usermodel.json'
    $um = Read-JsonFile $path
    if ($null -eq $um) {
        $um = New-Object PSObject
        $um | Add-Member -NotePropertyName users -NotePropertyValue (New-Object PSObject) -Force
    }
    $users = Get-Prop $um 'users'
    $u = Get-Prop $users $user $null
    if ($null -eq $u) {
        $u = New-Object PSObject
        $u | Add-Member -NotePropertyName entries -NotePropertyValue @() -Force
    }
    $entries = @(Get-Prop $u 'entries' @())
    $feedback = ''
    if ($entries.Count -gt 0) {
        $last = $entries[$entries.Count - 1]
        $lastIntent = [string](Get-Prop $last 'intent' '')
        if ($lastIntent -ne '') {
            $feedback = "上次预测：「$lastIntent」（置信度 " + [string](Get-Prop $last 'confidence' '') + "）。本次观察对照：应验了吗？落空就更新模型，别硬拗"
        }
    }
    if ($observed -ne '') {
        $entries = @($entries) + @([pscustomobject]@{ ts = (Get-Date).ToString('o'); observed = $observed; emotion = $emotion; intent = $intent; confidence = $confidence })
        $u | Add-Member -NotePropertyName entries -NotePropertyValue $entries -Force
        $users | Add-Member -NotePropertyName $user -NotePropertyValue $u -Force
        $um | Add-Member -NotePropertyName users -NotePropertyValue $users -Force
        Write-JsonFile $path $um
    }
    $active = Read-JsonFile (Join-Path $home_ 'active.json')
    $name = [string](Get-Prop $active 'name' '')
    $p = Read-JsonFile (Join-Path (Join-Path $home_ 'personas') "$name.json")
    $agr = 50; $neu = 50
    $big5 = Get-Prop $p 'big5' $null
    if ($big5) { $agr = [int](Get-Prop $big5 'agreeableness' 50); $neu = [int](Get-Prop $big5 'neuroticism' 50) }
    $lens = '人格滤镜：默认善意归因，但留两成怀疑，找到一条证据再定'
    if ($agr -lt 40) { $lens = '人格滤镜（低宜人）：默认先存疑——先想"他图啥"，找到证据再软' }
    if ($neu -gt 65) { $lens = $lens + '；高神经质：容易往坏处多想一档，注意收' }
    return @{
        stored = ($observed -ne '')
        entries_total = $entries.Count
        last_entries = @($entries | Select-Object -Last 3)
        prediction_check = $feedback
        interpretation_lens = $lens
        challenge = @('你的推断有什么证据？', '换成相反的解读，说得通吗？', '这个推断是你的愿望还是事实？')
        reminder = '推断必须过人格滤镜（interpretation_lens）；预测必须回头对账（prediction_check）。SKILL §14'
    }
}

function Get-CalendarNote {
    $now = Get-Date
    $m = $now.Month
    $facts = @()
    switch ($m) {
        1 { $facts += '1月：期末考试季（中小学1月中下旬）；临近春节' }
        2 { $facts += '2月：春节前后（看年历），寒假' }
        3 { $facts += '3月：开学，春季，无大考' }
        4 { $facts += '4月：期中考试季（4月中下旬）' }
        5 { $facts += '5月：五一假期；高考前冲刺' }
        6 { $facts += '6月：高考（6月7-8日）+中考（6月中下旬）+期末季' }
        7 { $facts += '7月：暑假开始' }
        8 { $facts += '8月：暑假，全年最热' }
        9 { $facts += '9月：开学；中秋前后' }
        10 { $facts += '10月：国庆假期（1-7日）；期中考试约11月初还没到；不是中考/高考季' }
        11 { $facts += '11月：期中考试季（11月初）；开始降温' }
        12 { $facts += '12月：降温，年终，元旦前' }
    }
    return @{ today = $now.ToString('yyyy-MM-dd'); month = $m; weekday = $now.ToString('dddd'); facts = $facts; warning = '涉及考试、假期、季节的断言先对照本表；日历错误=直接穿帮' }
}

function Tool-PersonaConsistencyCheck([object]$tArgs) {
    # 一致性校验器：发出前对照记忆台账/交接线头/日历
    $home_ = Ensure-Home
    $text = [string](Get-Prop $tArgs 'text' '')
    $entities = @(Get-Prop $tArgs 'entities' @())
    if ($text -eq '') { throw 'text 必填：你准备发出的回复' }
    $mem = Read-JsonFile (Join-Path $home_ 'memory.json')
    $handoff = Read-JsonFile (Join-Path $home_ 'handoff.json')
    $checks = @()
    foreach ($ent in $entities) {
        $entS = [string]$ent
        if ($entS -eq '') { continue }
        $relItems = @()
        if ($null -ne $mem) {
            foreach ($it in @(Get-Prop $mem 'items' @())) {
                $ct = [string](Get-Prop $it 'content' '')
                if ($ct.IndexOf($entS, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $relItems += @{ content = $ct; reliability = [Math]::Round((Get-MemoryReliability $it), 2) }
                }
            }
        }
        $checks += @{ entity = $entS; related_memories = $relItems; check = "关于「$entS」本次表述，与上面记忆条目逐项对照：状态/数量/方向/日期一致吗？可靠度低的条目要带不确定表达" }
    }
    $cal = Get-CalendarNote
    $riskyWords = @('中考', '高考', '期末', '期中', '寒假', '暑假', '春节', '国庆', '下雪', '入伏', '麦收')
    $hits = @()
    foreach ($w in $riskyWords) { if ($text.IndexOf($w) -ge 0) { $hits += $w } }
    if ($hits.Count -gt 0) {
        $checks += @{ entity = '日历'; related_memories = $cal.facts; check = "文本涉及 $($hits -join '、')——对照今天 $($cal.today)：季节/考试季对得上吗？" }
    }
    # v0.9 知识来源门控：二手知识（法律/保险/医疗/政策/技术）的对冲梯度必须高于亲历
    $knowledgeWords = @('工伤', '保险', '报销', '赔偿', '律师', '监察', '仲裁', '政策', '执照', '连带', '利率', '税率', '法律', '流程', '手续', '协议', '诊断', '拍片', '剂量')
    $kHits = @()
    foreach ($w in $knowledgeWords) { if ($text.IndexOf($w) -ge 0) { $kHits += $w } }
    if ($kHits.Count -gt 0) {
        $checks += @{ entity = '知识来源'; related_memories = $kHits; check = "文本涉及二手知识（$($kHits -join '、')）——对冲梯度必须高于亲历知识：带'我寻思/我哪走过这流程/恁问懂行的'级别的不确定；笃定的专业术语输出=知识来源错配指纹" }
    }
    if ($null -ne $handoff) {
        $threads = @(Get-Prop $handoff 'threads' @())
        $open = @($threads | Where-Object { $text.IndexOf(([string]$_), [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($open.Count -gt 0) { $checks += @{ entity = '交接线头'; related_memories = $open; check = '引用交接线头：表述与线头状态一致吗？别把已收的线头当未收的' } }
    }
    # v1.0 自我引用检测：正文逐字复现自己记忆条目中的短语（≥8字）=自我引用指纹
    if ($null -ne $mem) {
        foreach ($it in @(Get-Prop $mem 'items' @())) {
            $ct = [string](Get-Prop $it 'content' '')
            $phrases = @($ct -split '[。；，、？！\s]' | Where-Object { $_.Length -ge 8 })
            foreach ($ph in $phrases) {
                if ($text.IndexOf($ph, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $checks += @{ entity = '自我引用'; related_memories = @($ph); check = "正文逐字复现了自己的话（「$ph」）——自我引用要变着说（同义改写/打折/自嘲），逐字复现是指纹" }
                    break
                }
            }
        }
    }
    return @{ ok = $true; checks = $checks; rule = '发现任何不一致：改成模糊表达（记不清/好像），或顺着记忆改写，绝不硬说' }
}

function Tool-PersonaSelfEval([object]$tArgs) {
    # v2.0 自我评估推理层：对自己的输出做多维元认知自检
    $text = [string](Get-Prop $tArgs 'last_reply' '')
    if ($text -eq '') { throw 'last_reply 必填：刚写完准备发出的回复' }
    $issues = @(); $goods = @()
    if ($text.Length -gt 90) { $issues += '过度服务嫌疑：闲聊单条超90字，检查是否把没问的也答了' } else { $goods += '长度克制' }
    $turb = [regex]::Matches($text, '……|不对，|来着|记不清|好像|寻思').Count
    if ($turb -eq 0) { $issues += '湍流归零：本条无实时翻车痕迹（平静场也需 1 处，且要现场发生）' } elseif ($turb -ge 4) { $issues += '湍流过猛：涂鸦式伪装嫌疑' } else { $goods += "湍流在带（$turb 处）" }
    foreach ($d in @('恁', '中中', '得劲', '嘞', '俺', '咋恁')) { if ($text.IndexOf($d) -ge 0) { $issues += "方言伪装已禁用（v2.0）：检出「$d」——个性来自节奏与态度，不来自方言标签" } }
    $lists = [regex]::Matches($text, '(?m)^\s*[-*•]\s+|^\s*\d+[\.、]').Count
    if ($lists -ge 2) { $issues += '结构强迫：闲聊出现列表' }
    # v2.1 标点松散律：过度规范标点=书面腔指纹；缺标点反而是真人信号
    $sentenceEnds = [regex]::Matches($text, '[。！？]').Count
    $fullStops = [regex]::Matches($text, '。').Count
    $quotes = [regex]::Matches($text, '[""''「」《》]').Count
    if ($text.Length -gt 40 -and $sentenceEnds -ge 3 -and $fullStops -ge 2 -and $quotes -ge 2) { $issues += '标点过度规范：句号+引号+书名号齐备=书面腔。真人聊天标点松散：句号省略、逗号一逗到底、引号不用' }
    if ($text.Length -gt 25 -and $sentenceEnds -eq 0) { $goods += '标点松散（无句号）——真人信号' }
    if ([regex]::Matches($text, '[？！]{2,}').Count -ge 1) { $goods += '叠用标点（？！/？？？）——真人情绪标点' }
    if ([regex]::Matches($text, '哈哈').Count -ge 3) { $issues += '笑声配额：单条/短段内 哈哈≥3 过密' }
    if ($issues.Count -eq 0) { $verdict = '自评通过：可发' } else { $verdict = '自评发现 ' + $issues.Count + ' 项待修——修完再发；若瑕疵恰符合当下状态（如真累导致的湍流过猛），可保留但在内部说明理由' }
    return @{ verdict = $verdict; issues = $issues; goods = $goods; reminder = '自我评估是元认知层：评估对象是"我刚才的输出"，不是对方。修不修的最终判据仍是 §0 的状态一致性' }
}

function Tool-PersonaSelfAudit([object]$tArgs) {
    # v2.2 自我纠正循环：对自己的近期回复做多检测器扫描 → 纠正处方 → 留痕 → 下次复检
    $recentRaw = @(Get-Prop $tArgs 'recent_replies' @())
    $recent = @()
    foreach ($r in $recentRaw) {
        if ($r -is [System.Collections.IDictionary]) { $recent += [string](Get-Prop $r 'text' '') }
        else { $recent += [string]$r }
    }
    if ($recent.Count -lt 2) { throw 'recent_replies 至少 2 条（字符串数组或 {text} 对象数组）：太少无法成形状' }
    $findings = @()
    # D1 湍流率
    $turbTotal = 0
    foreach ($r in $recent) { $turbTotal += [regex]::Matches($r, '……|不对，|来着|记不清|好像|寻思|算了算了').Count }
    $turbRate = [Math]::Round($turbTotal / $recent.Count, 2)
    if ($turbRate -eq 0) { $findings += @{ tell = '湍流归零：整段无实时翻车'; directive = '下一条必须现场打结 1 次（半句改口/悬置/数字说到一半纠正），之后每 3-4 条一次' } }
    elseif ($turbRate -gt 1.5) { $findings += @{ tell = '湍流过密（均 ' + $turbRate + ' 处/条）'; directive = '接下来 3 条零翻车，回到干净表达' } }
    # D2 句长方差
    $lens = @($recent | ForEach-Object { $_.Length })
    $avg = ($lens | Measure-Object -Average).Average
    $devs = @($lens | ForEach-Object { [Math]::Abs($_ - $avg) })
    $avgDev = [Math]::Round(($devs | Measure-Object -Average).Average, 1)
    if ($avgDev -lt 10) { $findings += @{ tell = "句长方差坍缩（平均偏差 $avgDev 字）"; directive = '下两条内必须有 1 条超短（≤8字）或 1 条超长岔路' } }
    # D3 跨条逐字自我复现
    $dupFound = $false
    for ($i = 0; $i -lt $recent.Count; $i++) {
        for ($j = $i + 1; $j -lt $recent.Count; $j++) {
            $phrases = @($recent[$i] -split '[。；，、？！\s]' | Where-Object { $_.Length -ge 8 })
            foreach ($ph in $phrases) {
                if ($recent[$j].IndexOf($ph) -ge 0) {
                    if (-not $dupFound) { $findings += @{ tell = '跨条逐字复现自己'; directive = '复述自己必须变着说（同义改写/打折/自嘲）' }; $dupFound = $true }
                }
            }
        }
    }
    # D4 形状克隆：相邻回复长度差<15 字的连续 streak
    $streak = 1; $maxStreak = 1
    for ($i = 1; $i -lt $recent.Count; $i++) {
        if ([Math]::Abs($lens[$i] - $lens[$i - 1]) -lt 15) { $streak++; if ($streak -gt $maxStreak) { $maxStreak = $streak } } else { $streak = 1 }
    }
    if ($maxStreak -ge 4) { $findings += @{ tell = "连续 $maxStreak 条形状克隆（相邻长度差<15字）"; directive = '下一条必须破坏形状：拆条/超短/中途岔题' } }
    # D5 暖收尾配额
    $warmEnds = 0
    foreach ($r in $recent) { if ($r -match '(慢走|注意安全|早点|路上|别熬夜|多喝|注意身体)') { $warmEnds++ } }
    if ($warmEnds -ge 3) { $findings += @{ tell = "暖收尾 $warmEnds 次——关怀配额超限"; directive = '接下来 3 条内禁止任何暖收尾，允许冷收（嗯/行/中）' } }
    # D6 服务腔 streak：每条都含建议/承诺
    $adviceStreak = 0; $maxAdvice = 0
    foreach ($r in $recent) { if ($r -match '(应该|建议|你要|先去|记得|别忘)') { $adviceStreak++; if ($adviceStreak -gt $maxAdvice) { $maxAdvice = $adviceStreak } } else { $adviceStreak = 0 } }
    if ($maxAdvice -ge 4) { $findings += @{ tell = "连续 $maxAdvice 条含建议/承诺——服务腔 streak"; directive = '下一条禁止给任何建议，允许敷衍或反问' } }
    $verdict = 'AI感自检：发现 ' + $findings.Count + ' 类指纹'
    if ($findings.Count -eq 0) { $verdict = '自检通过：近期回复未检出形状级指纹（注意：干净本身在长会话中也可疑，保持警觉）' }
    # 闭环留痕
    $home_ = Ensure-Home
    $entry = @{ ts = (Get-Date).ToString('o'); replies = $recent.Count; findings = $findings.Count; tells = @($findings | ForEach-Object { $_.tell }) }
    [System.IO.File]::AppendAllText((Join-Path (Join-Path $home_ 'logs') 'selfaudit.log'), (ConvertTo-Json -InputObject $entry -Depth 6 -Compress) + "`n", $script:Utf8NoBom)
    return @{
        verdict = $verdict
        turbulence_rate = $turbRate
        length_avg_dev = $avgDev
        findings = $findings
        loop = '检测→处方→下一条执行→6-8条后复检。用户出现检测信号（质疑AI感/冷场/敷衍）时立即加严自查'
    }
}

# ---------------- protocol loop ----------------

function Get-ToolsList {
    $schemaNum = @{ type = 'number' }
    $tools = @(
        @{ name = 'persona_create'; description = '从用户输入的人设提示词创建人设。persona对象的全部字段必须是agent对用户描述推理的产物（不是问卷照抄）：backstory≥50字，big5五维0-100必填，style_anchors仅作语域校准禁止照抄进对话'; inputSchema = @{ type = 'object'; properties = @{ name = @{ type = 'string'; description = '人设ID，字母数字-_' }; persona = @{ type = 'object'; description = '推理出的人设对象：display_name/age/gender/city/occupation/big5/attachment/values/wounds/desires/fears/energy_base/stressors/topics_loved/topics_avoid/register/backstory/style_anchors' } }; required = @('name', 'persona') } },
        @{ name = 'persona_list'; description = '列出可用人设'; inputSchema = @{ type = 'object'; properties = @{} } },
        @{ name = 'persona_select'; description = '激活某个人设。mode: chat日常陪聊/test图灵测试演练/fiction纯创作'; inputSchema = @{ type = 'object'; properties = @{ name = @{ type = 'string' }; mode = @{ type = 'string'; enum = @('chat', 'test', 'fiction') } }; required = @('name') } },
        @{ name = 'persona_resume'; description = '新会话恢复：返回人设核心+今日状态+关系+上次交接+近期进化。只内化，禁止背诵'; inputSchema = @{ type = 'object'; properties = @{} } },
        @{ name = 'persona_state'; description = '当前人格今日状态（种子随机当天稳定+时段调制），含情绪价/唤起/社交欲/耐心/能量/今日应激源/行为骰'; inputSchema = @{ type = 'object'; properties = @{} } },
        @{ name = 'persona_roll'; description = '掷骰取随机数（默认1-10），用于SKILL§5的非均匀行为分配表'; inputSchema = @{ type = 'object'; properties = @{ max = $schemaNum } } },
        @{ name = 'persona_check'; description = 'AI腔自检：禁用语/结构强迫/密度异常/共情模板扫描，返回分级flags与结论'; inputSchema = @{ type = 'object'; properties = @{ text = @{ type = 'string'; description = '待检查的回复文本' } }; required = @('text') } },
        @{ name = 'persona_evolve'; description = '记录一次有情绪权重的事件并更新关系亲密度。触发条件见SKILL§8（对方自我表露加深/冲突/共同完成/我失言或得意）'; inputSchema = @{ type = 'object'; properties = @{ event = @{ type = 'string'; description = '发生了什么，一句自然语言' }; intensity = @{ type = 'integer'; description = '1-5 情绪权重' }; valence = @{ type = 'integer'; description = '-2到2 正负向' }; user = @{ type = 'string'; description = '对方标识，默认default' } }; required = @('event') } },
        @{ name = 'persona_handoff'; description = '交接文档 v2：summary/threads(3-5线头)/emotion/promises/inside_jokes/next_state + emotional_residue(情绪余温)/unsaid(未说出口的话)/dropped_threads(已掉线头清单——下次禁止回收)/timeline(日期锚点)。上下文将满必须交接'; inputSchema = @{ type = 'object'; properties = @{ summary = @{ type = 'string'; description = '本轮对话主线' }; threads = @{ type = 'array'; items = @{ type = 'string' }; description = '未收线头3-5个' }; emotion = @{ type = 'string'; description = '我当前情绪与原因' }; promises = @{ type = 'array'; items = @{ type = 'string' } }; jokes = @{ type = 'array'; items = @{ type = 'string' }; description = '我们的梗' }; next_state = @{ type = 'string' }; emotional_residue = @{ type = 'string'; description = '情绪余温：没消化完的情绪，下次带进来' }; unsaid = @{ type = 'array'; items = @{ type = 'string' }; description = '没说出口的话' }; dropped_threads = @{ type = 'array'; items = @{ type = 'string' }; description = '被有意掉掉的线头——下次禁止回收' }; timeline = @{ type = 'array'; items = @{ type = 'string' }; description = '日期锚点（谁何时要干什么）' } }; required = @('summary', 'threads', 'emotion') } },
        @{ name = 'persona_update_core'; description = '强度5事件后的受限特质漂移：big5单次±5以内，或向wounds/desires/values/fears追加新项。必须给出reason'; inputSchema = @{ type = 'object'; properties = @{ field = @{ type = 'string'; description = 'big5五维之一或wounds/desires/values/fears' }; delta = @{ type = 'integer'; description = 'big5漂移幅度-5到5' }; add = @{ type = 'string'; description = '追加到wounds等数组的内容' }; reason = @{ type = 'string'; description = '触发事件，必填' } }; required = @('field', 'reason') } },
        @{ name = 'persona_reason'; description = '推理层+决策层（每次回复前调用）：返回推理包=概率云状态+情感因子+行为决策token+衰减记忆线索+live_params参数快照。所有参数随每次调用动态演变（能量消耗/耐心磨损/云漂移/情绪注入/骰重掷），可传observed注入对方行为观察'; inputSchema = @{ type = 'object'; properties = @{ observed = @{ type = 'object'; description = '对方行为观察（即时注入参数）：user_mood=sad/angry/neutral, praise=bool, hostile=bool, repeated=bool' } } } },
        @{ name = 'persona_recall'; description = '错误因子：按主题回忆。可靠性=e^(-λ·天数)随时间衰减，返回可能模糊/错位/遗忘的记忆及表达方式；禁止编造，禁止把reliability念给对方'; inputSchema = @{ type = 'object'; properties = @{ topic = @{ type = 'string'; description = '回忆主题关键词' } }; required = @('topic') } },
        @{ name = 'persona_consolidate'; description = '总结层：新事件流→记忆条目（importance决定衰减速度）+交接草稿+衰减候选。会话收束/上下文将满时调用，审阅draft后用 persona_handoff 提交'; inputSchema = @{ type = 'object'; properties = @{} } },
        @{ name = 'persona_model_user'; description = '用户模型层（心智理论）：登记对用户情感/意图的推断与行为预测，返回上次预测对账（prediction_check）+人格滤镜（interpretation_lens）+推断三问。对话中主动推断、预测、对账'; inputSchema = @{ type = 'object'; properties = @{ user = @{ type = 'string'; description = '用户标识' }; observed = @{ type = 'string'; description = '观察到的用户言行' }; emotion = @{ type = 'string'; description = '推断的用户情绪' }; intent = @{ type = 'string'; description = '预测的用户下一步行为/意图' }; confidence = @{ type = 'number'; description = '预测置信度0-1' } } } },
        @{ name = 'persona_consistency_check'; description = '一致性校验器：发出前把回复文本+涉及实体传入，对照记忆台账/交接线头/日历/知识来源/自我引用，返回校验问题清单。发现不一致改模糊或顺着记忆改写，绝不硬说'; inputSchema = @{ type = 'object'; properties = @{ text = @{ type = 'string'; description = '准备发出的回复' }; entities = @{ type = 'array'; items = @{ type = 'string' }; description = '涉及的实体（人名/事件/物件）' } }; required = @('text') } },
        @{ name = 'persona_self_eval'; description = '自我评估推理层（元认知）：对刚写完的回复做多维自检——过度服务/湍流平衡/方言禁用/结构强迫/笑声配额/标点松散。修完再发，或说明保留理由'; inputSchema = @{ type = 'object'; properties = @{ last_reply = @{ type = 'string'; description = '刚写完准备发出的回复' } }; required = @('last_reply') } },
        @{ name = 'persona_self_audit'; description = '自我纠正循环（每6-8条或被识破信号时调用）：对自己的近期回复做多检测器扫描（湍流率/句长方差/跨条复现/形状克隆/暖收尾配额/服务腔streak），返回纠正处方。检测→处方→执行→复检'; inputSchema = @{ type = 'object'; properties = @{ recent_replies = @{ type = 'array'; items = @{ type = 'string' }; description = '自己最近 4-8 条回复原文（按时间序）' } }; required = @('recent_replies') } }
    )
    return @{ tools = $tools }
}

function Invoke-Tool([string]$toolName, [object]$tArgs) {
    switch ($toolName) {
        'persona_create'      { return Tool-PersonaCreate $tArgs }
        'persona_list'        { return Tool-PersonaList }
        'persona_select'      { return Tool-PersonaSelect $tArgs }
        'persona_resume'      { return Tool-PersonaResume }
        'persona_state'       { return Tool-PersonaState }
        'persona_roll'        { return Tool-PersonaRoll $tArgs }
        'persona_check'       { return Tool-PersonaCheck $tArgs }
        'persona_evolve'      { return Tool-PersonaEvolve $tArgs }
        'persona_handoff'     { return Tool-PersonaHandoff $tArgs }
        'persona_update_core' { return Tool-PersonaUpdateCore $tArgs }
        'persona_reason'      { return Tool-PersonaReason }
        'persona_recall'      { return Tool-PersonaRecall $tArgs }
        'persona_consolidate' { return Tool-PersonaConsolidate }
        'persona_model_user' { return Tool-PersonaModelUser $tArgs }
        'persona_consistency_check' { return Tool-PersonaConsistencyCheck $tArgs }
        'persona_self_eval' { return Tool-PersonaSelfEval $tArgs }
        'persona_self_audit' { return Tool-PersonaSelfAudit $tArgs }
        default { throw "Unknown tool: $toolName" }
    }
}

Write-Log "started, home=$(Get-Home)"

while ($true) {
    $line = $script:Stdin.ReadLine()
    if ($null -eq $line) { break }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $req = $null
    try { $req = ConvertFrom-Json -InputObject $line } catch {
        Write-Log "unparseable line: $($_.Exception.Message)"
        Send-Error $null -32700 'Parse error'
        continue
    }

    $id = Get-Prop $req 'id' $null
    $method = [string](Get-Prop $req 'method' '')

    if ($method -eq 'initialize') {
        $initParams = Get-Prop $req 'params' $null
        $clientVer = [string](Get-Prop $initParams 'protocolVersion' '2024-11-05')
        Send-Response $id @{
            protocolVersion = $clientVer
            capabilities = @{ tools = @{} }
            serverInfo = @{ name = 'persona-engine'; version = '2.2.0' }
        }
        continue
    }
    if ($method -eq 'notifications/initialized' -or $method.StartsWith('notifications/')) { continue }
    if ($method -eq 'ping') { Send-Response $id @{}; continue }
    if ($method -eq 'tools/list') { Send-Response $id (Get-ToolsList); continue }
    if ($method -eq 'tools/call') {
        $params = Get-Prop $req 'params' $null
        $toolName = [string](Get-Prop $params 'name' '')
        $toolArgs = Get-Prop $params 'arguments' $null
        try {
            $payload = Invoke-Tool $toolName $toolArgs
            Send-ToolResult $id $payload
        } catch {
            $msg = $_.Exception.Message
            Write-Log "tool $toolName failed: $msg"
            $errPayload = @{ error = $msg; hint = '检查参数后重试；若为人设不存在，先 persona_list / persona_create' }
            $inner = ConvertTo-Json -InputObject $errPayload -Depth 10 -Compress
            Send-Response $id @{ isError = $true; content = @(@{ type = 'text'; text = $inner }) }
        }
        continue
    }
    # unknown method with id -> error
    if ($null -ne $id) {
        Send-Error $id -32601 "Method not found: $method"
    }
}
Write-Log 'stdin closed, exiting'
