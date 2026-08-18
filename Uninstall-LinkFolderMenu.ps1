# Uninstall-LinkFolderMenu.ps1
# 功能：从注册表移除「链接到该目录」和「迁移并链接」右键菜单

$regRoot          = "HKCU:\\SOFTWARE\\Classes\\Directory\\shell\\FolderLinkTool"
$regMigrateRoot   = "HKCU:\\SOFTWARE\\Classes\\Directory\\shell\\FolderLinkMigrateTool"

$removedAny = $false

foreach ($key in @($regRoot, $regMigrateRoot)) {
    if (Test-Path $key) {
        Remove-Item -Path $key -Recurse -Force
        Write-Host "  [OK] 已移除菜单：$key" -ForegroundColor Yellow
        $removedAny = $true
    }
}

if (-not $removedAny) {
    Write-Host "  [INFO] 菜单不存在，无需移除。" -ForegroundColor Gray
}
