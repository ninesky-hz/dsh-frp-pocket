# =============================================================================
# install-pc.ps1 — Windows PC 侧安装 frpc（配合 dsh-frp-pocket 插件使用）
#
# 正常情况下你**不需要**这个脚本：插件设置页会自己下载/管理 frpc 并生成配置。
# 它的用途：
#   1) 不装插件时手工验证隧道（排查到底是 frp 的问题还是插件的问题）
#   2) 插件报 frpc_not_found 时，先把 frpc.exe 落到固定位置
#   3) 需要 frpc 开机自启、而插件没跑的时候
#
# 用法（普通 PowerShell 即可，注册计划任务建议用管理员）：
#   .\install-pc.ps1 -Subdomain home -ServerAddr VPS_IP -Token 'FRP_TOKEN'
#   .\install-pc.ps1 -Subdomain studio -ServerAddr VPS_IP -Token 'FRP_TOKEN' -Mode None
#
# 参数：
#   -Subdomain   必填。home / studio（对应 https://<sub>.<domain>）
#   -ServerAddr  必填。VPS 公网 IP 或域名
#   -Token       必填。与 frps 的 auth.token 一致
#   -ServerPort  默认 7000
#   -LocalPort   默认 3081（dsh-frp-pocket 网关端口，不是 dsh web 端口）
#   -Mode        ScheduledTask(默认，登录自启) | Service(需管理员+NSSM) | None(只装不注册)
#   -FrpVersion  默认 0.71.1
#
# 产物：
#   %LOCALAPPDATA%\dsh-frp-pocket\frp\frpc.exe
#   %LOCALAPPDATA%\dsh-frp-pocket\frpc.toml
#   %LOCALAPPDATA%\dsh-frp-pocket\logs\frpc.out.log
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Subdomain,
    [Parameter(Mandatory = $true)][string]$ServerAddr,
    [Parameter(Mandatory = $true)][string]$Token,
    [int]$ServerPort = 7000,
    [int]$LocalPort = 3081,
    [ValidateSet('ScheduledTask', 'Service', 'None')][string]$Mode = 'ScheduledTask',
    [string]$FrpVersion = '0.71.1'
)

$ErrorActionPreference = 'Stop'
function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "[ok] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

# ---------- 0. 参数校验 ----------
if ($Subdomain -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') {
    throw "-Subdomain 不合法：$Subdomain（小写字母/数字/连字符）"
}
if ($Token -notmatch '^[A-Za-z0-9._~-]{16,128}$') {
    throw "-Token 只能用 [A-Za-z0-9._~-] 且 16-128 位（与 install-vps.sh 的约束一致）"
}
if ($ServerPort -lt 1 -or $ServerPort -gt 65535) { throw "-ServerPort 越界" }
if ($LocalPort -lt 1 -or $LocalPort -gt 65535) { throw "-LocalPort 越界" }

$Root = Join-Path $env:LOCALAPPDATA 'dsh-frp-pocket'
$BinDir = Join-Path $Root 'frp'
$LogDir = Join-Path $Root 'logs'
$Frpc = Join-Path $BinDir 'frpc.exe'
$Conf = Join-Path $Root 'frpc.toml'
$TaskName = "dsh-frp-pocket-$Subdomain"

New-Item -ItemType Directory -Force -Path $BinDir, $LogDir | Out-Null
Say "工作目录 $Root"

# ---------- 1. 准备 frpc.exe ----------
function Get-FrpcVersion($exe) {
    try { return (& $exe --version 2>&1 | Select-Object -First 1).ToString().Trim() } catch { return $null }
}

$haveVer = if (Test-Path $Frpc) { Get-FrpcVersion $Frpc } else { $null }
if ($haveVer -eq $FrpVersion) {
    Ok "frpc $FrpVersion 已存在，跳过下载"
}
else {
    if (Test-Path $Frpc) { Warn "已装 frpc $haveVer，升级到 $FrpVersion" }
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
    $zipName = "frp_${FrpVersion}_windows_$arch.zip"
    $url = "https://github.com/fatedier/frp/releases/download/v$FrpVersion/$zipName"
    $tmp = Join-Path $env:TEMP "dsh-frp-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    Say "下载 $url"
    try {
        # 老 PowerShell 默认不启用 TLS1.2，GitHub 会直接断
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmp $zipName) -UseBasicParsing
    }
    catch {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        throw "下载失败：$($_.Exception.Message)`n可手动下载 $url 解压出 frpc.exe 放到 $BinDir"
    }

    Expand-Archive -Path (Join-Path $tmp $zipName) -DestinationPath $tmp -Force
    $found = Get-ChildItem -Path $tmp -Recurse -Filter 'frpc.exe' | Select-Object -First 1
    if (-not $found) {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        throw "压缩包里没找到 frpc.exe"
    }
    Copy-Item $found.FullName $Frpc -Force
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Ok "安装 $Frpc ($(Get-FrpcVersion $Frpc))"
}

# ---------- 2. 生成 frpc.toml ----------
# 注意：必须写成 UTF-8 无 BOM，frp 的 TOML 解析器遇到 BOM 会报语法错。
$toml = @"
# 由 install-pc.ps1 生成 — 手改会被覆盖
serverAddr = "$ServerAddr"
serverPort = $ServerPort

auth.method = "token"
auth.token = "$Token"

transport.tls.enable = false
log.to = "console"
log.level = "info"

[[proxies]]
name = "dsh-frp-$Subdomain"
type = "http"
localIP = "127.0.0.1"
localPort = $LocalPort
subdomain = "$Subdomain"
"@

if (Test-Path $Conf) {
    $old = Get-Content -Raw -Path $Conf
    if ($old -eq $toml) { Ok "frpc.toml 无变化" }
    else {
        Copy-Item $Conf "$Conf.bak" -Force
        [IO.File]::WriteAllText($Conf, $toml, (New-Object Text.UTF8Encoding($false)))
        Ok "写入 frpc.toml（旧文件备份为 frpc.toml.bak）"
    }
}
else {
    [IO.File]::WriteAllText($Conf, $toml, (New-Object Text.UTF8Encoding($false)))
    Ok "写入 frpc.toml"
}

# ---------- 3. 校验配置 ----------
Say "校验配置"
& $Frpc verify -c $Conf
if ($LASTEXITCODE -ne 0) { throw "frpc verify 失败，配置未生效" }
Ok "配置语法正确"

# 端口占用提醒：网关没起时 frpc 仍能连上 frps，但访问会 502
$busy = Get-NetTCPConnection -State Listen -LocalPort $LocalPort -ErrorAction SilentlyContinue
if (-not $busy) {
    Warn "本机 $LocalPort 端口没人监听 —— 插件网关可能没开；此时公网访问会 502（frpc 本身正常）"
}

# ---------- 4. 注册自启 ----------
function Stop-ExistingFrpc {
    Get-Process -Name 'frpc' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force } catch {}
    }
}

# 先把已有的手工进程停掉，避免同名代理互相踢
Stop-ExistingFrpc

switch ($Mode) {
    'ScheduledTask' {
        Say "注册登录自启计划任务：$TaskName"
        $action = New-ScheduledTaskAction -Execute $Frpc -Argument "-c `"$Conf`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1)
        try {
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -Settings $settings -Description 'dsh-frp-pocket frpc' -Force | Out-Null
            Ok "计划任务已注册（登录后自动启动，无窗口）"
        }
        catch {
            Warn "注册计划任务失败：$($_.Exception.Message)"
            Warn "请用『管理员 PowerShell』重跑，或改用 -Mode None 手动启动"
        }
        Start-Process -FilePath $Frpc -ArgumentList @('-c', "`"$Conf`"") -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $LogDir 'frpc.out.log') `
            -RedirectStandardError (Join-Path $LogDir 'frpc.err.log')
    }
    'Service' {
        Say "以 Windows 服务方式安装"
        # 关键事实：frpc.exe 不是服务程序（不会调 StartServiceCtrlDispatcher），
        # 直接 New-Service 会失败并报 1053（服务没有及时响应启动请求）。
        # 必须用 NSSM 这类包装器，或用计划任务。
        $nssm = (Get-Command nssm.exe -ErrorAction SilentlyContinue).Source
        if (-not $nssm) {
            throw "未找到 nssm.exe。frpc.exe 不能直接注册为服务（会 1053）。`n装 NSSM：winget install NSSM.NSSM，或 https://nssm.cc/download ，然后重跑。`n或者用 -Mode ScheduledTask（推荐，不需要管理员）"
        }
        & $nssm stop $TaskName 2>$null
        & $nssm remove $TaskName confirm 2>$null
        & $nssm install $TaskName $Frpc "-c `"$Conf`""
        & $nssm set $TaskName AppStdout (Join-Path $LogDir 'frpc.out.log')
        & $nssm set $TaskName AppStderr (Join-Path $LogDir 'frpc.err.log')
        & $nssm set $TaskName Start SERVICE_AUTO_START
        & $nssm start $TaskName
        Ok "服务 $TaskName 已安装并启动（NSSM 包装）"
    }
    'None' {
        Say "只安装不注册（-Mode None）"
        Start-Process -FilePath $Frpc -ArgumentList @('-c', "`"$Conf`"") -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $LogDir 'frpc.out.log') `
            -RedirectStandardError (Join-Path $LogDir 'frpc.err.log')
        Ok "已后台启动（本次登录有效）"
    }
}

# ---------- 5. 验证 ----------
Say "等待 frpc 连上 frps（最多 10 秒）"
$logFile = Join-Path $LogDir 'frpc.out.log'
$okProxy = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $logFile) {
        $tail = Get-Content -Path $logFile -Tail 40 -ErrorAction SilentlyContinue
        if ($tail -match 'start proxy success') { $okProxy = $true; break }
        if ($tail -match 'login to server failed|authorization failed|token') { break }
    }
}

if ($okProxy) {
    Ok "frpc 已连上 frps，代理 dsh-frp-$Subdomain 注册成功"
}
else {
    Warn "10 秒内没看到 'start proxy success'，日志尾部："
    if (Test-Path $logFile) { Get-Content -Path $logFile -Tail 15 } else { Warn "没有日志文件" }
    Warn "常见原因：token 不对 / 7000 没放行 / frps 没起 / 子域名已被别的机器占用"
}

$publicUrl = "https://$Subdomain.dsh.example.com"
Write-Host ""
Write-Host "下一步：" -ForegroundColor Cyan
Write-Host "  1) 确认 VPS 上已配好 $Subdomain.dsh.example.com 的 DNS 与 Caddy"
Write-Host "  2) 打开插件设置页 → 开启隧道（网关必须在 $LocalPort 监听）"
Write-Host "  3) 验证：curl -I $publicUrl   （应返回 200 登录页，未开网关则 502）"
Write-Host "  4) 日志：Get-Content '$logFile' -Tail 50 -Wait"
Write-Host "  5) 停止：Stop-Process -Name frpc  或  Unregister-ScheduledTask -TaskName '$TaskName'"
