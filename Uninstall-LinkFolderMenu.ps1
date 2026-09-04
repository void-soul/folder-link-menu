# Uninstall-LinkFolderMenu.ps1
# 从注册表移除 4 个右键菜单及历史遗留键（含级联菜单版 MagicMenu）

$keys = @(
    "HKCU:\SOFTWARE\Classes\Directory\shell\MagicLink",
    "HKCU:\SOFTWARE\Classes\Directory\shell\MagicMigrate",
    "HKCU:\SOFTWARE\Classes\Directory\shell\MagicMark",
    "HKCU:\SOFTWARE\Classes\Directory\shell\MagicIdentify",
    "HKCU:\SOFTWARE\Classes\Directory\shell\MagicMenu",
    "HKCU:\SOFTWARE\Classes\Directory\shell\FolderLinkTool",
    "HKCU:\SOFTWARE\Classes\Directory\shell\FolderLinkMigrateTool"
)

$removedAny = $false
foreach ($key in $keys) {
    if (Test-Path $key) {
        Remove-Item -Path $key -Recurse -Force
        Write-Host "  [OK] 已移除：$key" -ForegroundColor Yellow
        $removedAny = $true
    }
}

if (-not $removedAny) {
    Write-Host "  [INFO] 菜单不存在，无需移除。" -ForegroundColor Gray
}
