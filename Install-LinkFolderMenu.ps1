# Install-LinkFolderMenu.ps1
# 功能：将 LinkFolder 右键菜单注册到 Windows 注册表（写 HKCU，无需管理员）

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$psScript  = Join-Path $scriptDir "LinkFolder.ps1"

if (-not (Test-Path $psScript)) {
    Write-Error "找不到 LinkFolder.ps1，请确保它和本脚本在同一目录下：`n$psScript"
    exit 1
}

$regRoot    = "HKCU:\\SOFTWARE\\Classes\\Directory\\shell\\FolderLinkTool"
$regCommand = "$regRoot\\command"

$menuText = "链接到该目录"
$iconPath = "shell32.dll,237"
$command  = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$psScript`" -FolderA `"%1`""

New-Item         -Path $regRoot    -Force | Out-Null
New-ItemProperty -Path $regRoot    -Name "(Default)"  -Value $menuText  -PropertyType String -Force | Out-Null
New-ItemProperty -Path $regRoot    -Name "Icon"       -Value $iconPath  -PropertyType String -Force | Out-Null

New-Item         -Path $regCommand -Force | Out-Null
New-ItemProperty -Path $regCommand -Name "(Default)"  -Value $command   -PropertyType String -Force | Out-Null

Write-Host ""
Write-Host "  [OK] 右键菜单注册成功！" -ForegroundColor Green
Write-Host ""
Write-Host "  菜单文字 : $menuText"
Write-Host "  作用范围 : 仅文件夹（右键文件夹时显示）"
Write-Host "  脚本路径 : $psScript"
Write-Host ""
