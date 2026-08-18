# Install-LinkFolderMenu.ps1
# 功能：将「链接到该目录」和「迁移并链接」右键菜单注册到 Windows 注册表（写 HKCU，无需管理员）

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$psScript        = Join-Path $scriptDir "LinkFolder.ps1"
$psMigrateScript = Join-Path $scriptDir "MigrateLinkFolder.ps1"

if (-not (Test-Path $psScript)) {
    Write-Error "找不到 LinkFolder.ps1，请确保它和本脚本在同一目录下：`n$psScript"
    exit 1
}

# ============ 菜单 1：链接到该目录 ============
$regRoot    = "HKCU:\\SOFTWARE\\Classes\\Directory\\shell\\FolderLinkTool"
$regCommand = "$regRoot\\command"

$menuText = "链接到该目录"
$iconPath = "shell32.dll,237"
# 注意：不能加 -WindowStyle Hidden！
# Win11 下隐藏窗口作为 GUI 对话框（MessageBox / FolderBrowserDialog）的宿主，
# 会导致对话框显示异常甚至脚本"一闪而过"。故用正常窗口 + -STA 显式启动 STA 线程。
$command  = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$psScript`" -FolderA `"%1`""

New-Item         -Path $regRoot    -Force | Out-Null
New-ItemProperty -Path $regRoot    -Name "(Default)"  -Value $menuText  -PropertyType String -Force | Out-Null
New-ItemProperty -Path $regRoot    -Name "Icon"       -Value $iconPath  -PropertyType String -Force | Out-Null

New-Item         -Path $regCommand -Force | Out-Null
New-ItemProperty -Path $regCommand -Name "(Default)"  -Value $command   -PropertyType String -Force | Out-Null

# ============ 菜单 2：迁移并链接 ============
if (Test-Path $psMigrateScript) {
    $regMigrateRoot    = "HKCU:\\SOFTWARE\\Classes\\Directory\\shell\\FolderLinkMigrateTool"
    $regMigrateCommand = "$regMigrateRoot\\command"

    $migrateMenuText = "迁移并链接"
    $migrateIconPath = "shell32.dll,174"
    $migrateCommand  = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$psMigrateScript`" -FolderA `"%1`""

    New-Item         -Path $regMigrateRoot    -Force | Out-Null
    New-ItemProperty -Path $regMigrateRoot    -Name "(Default)"  -Value $migrateMenuText  -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regMigrateRoot    -Name "Icon"       -Value $migrateIconPath  -PropertyType String -Force | Out-Null

    New-Item         -Path $regMigrateCommand -Force | Out-Null
    New-ItemProperty -Path $regMigrateCommand -Name "(Default)"  -Value $migrateCommand   -PropertyType String -Force | Out-Null

    $migrateMsg = "`n  菜单文字 : $migrateMenuText（迁移数据到目标盘，并在原位置创建链接，自动提权）"
} else {
    Write-Warning "未找到 MigrateLinkFolder.ps1，「迁移并链接」菜单未注册：`n$psMigrateScript"
    $migrateMsg = ""
}

Write-Host ""
Write-Host "  [OK] 右键菜单注册成功！" -ForegroundColor Green
Write-Host ""
Write-Host "  菜单文字 : $menuText（在目标目录下创建指向原目录的链接）"
Write-Host "$migrateMsg"
Write-Host "  作用范围 : 仅文件夹（右键文件夹时显示）"
Write-Host "  脚本路径 : $psScript"
if (Test-Path $psMigrateScript) {
    Write-Host "            $psMigrateScript"
}
Write-Host ""
