# Install-LinkFolderMenu.ps1
# 在文件夹右键菜单注册 4 个一级菜单（HKCU，无需管理员）：
#   链接到该目录 / 迁移并链接 / 标记 / 识别
# 说明：曾尝试「Magic Menu」级联子菜单（SubCommands + shell\<动词>\command），
#       在部分系统上 Explorer 不渲染子菜单，故改回 4 个并列一级菜单
#       （与旧版同构，该结构已验证可正常显示）。

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# 检查必需脚本
$missing = @()
foreach ($n in @("LinkFolder.ps1", "MigrateLinkFolder.ps1", "MarkFolder.ps1", "IdentifyFolder.ps1")) {
    if (-not (Test-Path -LiteralPath (Join-Path $scriptDir $n))) { $missing += $n }
}
if ($missing.Count -gt 0) {
    Write-Error "缺少脚本文件，请确认它们与安装脚本在同一目录：`n$($missing -join "`n")`n目录：$scriptDir"
    exit 1
}

# ---------- 清理旧版（含级联菜单版 MagicMenu） ----------
$cleanupKeys = @(
    "HKCU:\SOFTWARE\Classes\Directory\shell\FolderLinkTool",
    "HKCU:\SOFTWARE\Classes\Directory\shell\FolderLinkMigrateTool",
    "HKCU:\SOFTWARE\Classes\Directory\shell\MagicMenu"
)
foreach ($k in $cleanupKeys) {
    if (Test-Path $k) {
        Remove-Item -Path $k -Recurse -Force
        Write-Host "  [清理] $k" -ForegroundColor Gray
    }
}

# ---------- 注册 4 个一级菜单 ----------
$menus = @(
    @{ Key = "MagicLink";     Text = "链接到该目录"; Icon = "shell32.dll,237"; Script = "LinkFolder.ps1" },
    @{ Key = "MagicMigrate";  Text = "迁移并链接";   Icon = "shell32.dll,174"; Script = "MigrateLinkFolder.ps1" },
    @{ Key = "MagicMark";     Text = "标记";         Icon = "shell32.dll,43";  Script = "MarkFolder.ps1" },
    @{ Key = "MagicIdentify"; Text = "识别";         Icon = "shell32.dll,167"; Script = "IdentifyFolder.ps1" }
)

foreach ($m in $menus) {
    $root = "HKCU:\SOFTWARE\Classes\Directory\shell\$($m.Key)"
    if (Test-Path $root) { Remove-Item -Path $root -Recurse -Force }
    New-Item         -Path $root -Force | Out-Null
    New-ItemProperty -Path $root -Name "(Default)" -Value $m.Text -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $root -Name "Icon"      -Value $m.Icon -PropertyType String -Force | Out-Null

    $cmdRoot    = "$root\command"
    $scriptPath = Join-Path $scriptDir $m.Script
    $cmd        = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$scriptPath`" -FolderA `"%1`""
    New-Item         -Path $cmdRoot -Force | Out-Null
    New-ItemProperty -Path $cmdRoot -Name "(Default)" -Value $cmd -PropertyType String -Force | Out-Null
}

# ---------- 验证 ----------
$ok = $true
foreach ($m in $menus) {
    $root = "HKCU:\SOFTWARE\Classes\Directory\shell\$($m.Key)"
    if (-not (Test-Path "$root\command")) { $ok = $false; Write-Warning "缺少注册项：$root\command" }
}

Write-Host ""
if ($ok) {
    Write-Host "  [OK] 右键菜单注册成功！" -ForegroundColor Green
} else {
    Write-Host "  [失败] 部分注册项缺失，请检查上方警告。" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "  右键任意文件夹即可看到 4 个菜单项："
Write-Host "    · 链接到该目录   创建 Junction 或 Symlink 指向原目录"
Write-Host "    · 迁移并链接     移动数据到新位置并在原位置创建链接"
Write-Host "    · 标记           给文件夹写备注（存于脚本根目录 mark.data）"
Write-Host "    · 识别           查看链接状态与指向（含反向查找）"
Write-Host ""
Write-Host "  作用范围   : 仅文件夹（Win11 需点「显示更多选项」或 Shift+F10）"
Write-Host "  脚本根目录 : $scriptDir"
Write-Host ""
