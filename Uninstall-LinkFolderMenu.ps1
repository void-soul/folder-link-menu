# Uninstall-LinkFolderMenu.ps1
# 功能：从注册表移除 LinkFolder 右键菜单

$regRoot = "HKCU:\\SOFTWARE\\Classes\\Directory\\shell\\FolderLinkTool"

if (Test-Path $regRoot) {
    Remove-Item -Path $regRoot -Recurse -Force
    Write-Host "  [OK] 右键菜单已移除。" -ForegroundColor Yellow
} else {
    Write-Host "  [INFO] 菜单不存在，无需移除。" -ForegroundColor Gray
}
