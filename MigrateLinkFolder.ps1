# MigrateLinkFolder.ps1
# 用法：被右键菜单调用，参数为右键选中的文件夹路径（即 A）
# 功能：
#   1. 自动提权（非管理员时弹 UAC，以管理员身份重启，保证跨卷符号链接可创建）
#   2. 用户选择迁移目录 B
#   3. 把 A 迁移到 B\A名（同卷用 Move-Item 瞬间完成；跨卷用 robocopy /MOVE）
#   4. 在原位置 A 创建指向新位置的目录符号链接（mklink /D，支持跨卷）
#   5. 任一步失败自动把数据回滚到原位置
#
# 安全防护：
#   - 拒绝迁移磁盘根目录、本身已是链接（Junction/符号链接）的目录
#   - 拒绝把目录迁移进自己内部、或迁移到原位置自身
#   - 目标位置已有同名项时直接取消（避免覆盖真实数据）

param(
    [Parameter(Mandatory=$true)]
    [string]$FolderA
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 错误日志路径（避免"一闪而过"无迹可寻）
$script:logPath = Join-Path $env:TEMP "MigrateLinkFolder_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-MigLog {
    param([string]$Message)
    try {
        "$(Get-Date -Format 'HH:mm:ss.fff')  $Message" | Add-Content -LiteralPath $script:logPath -Encoding UTF8
    } catch { }
}

function Show-ErrBox {
    param([string]$Title, [string]$Message)
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

# 在真实数据目录维护 link.data，记录「何时、哪个链接指向该目录」
# DataFile   = link.data 的完整路径（位于真实数据目录内）
# LinkedFrom = 指向该目录的链接完整路径
# 规则：同一链接路径再次链接时更新日期；不同链接路径追加新行
function Update-LinkData {
    param(
        [string]$DataFile,
        [string]$LinkedFrom
    )
    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $line = "[$timestamp]$LinkedFrom"
        if (Test-Path -LiteralPath $DataFile -PathType Leaf) {
            $lines = @(Get-Content -LiteralPath $DataFile -Encoding UTF8)
            $updated = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $m = [regex]::Match($lines[$i], '^\[[^\]]*\]\s*(.*)$')
                if ($m.Success -and $m.Groups[1].Value.Trim() -eq $LinkedFrom) {
                    $lines[$i] = $line
                    $updated = $true
                    break
                }
            }
            if (-not $updated) {
                $lines += $line
            }
            $lines | Set-Content -LiteralPath $DataFile -Encoding UTF8
        } else {
            $line | Set-Content -LiteralPath $DataFile -Encoding UTF8
        }
        Write-MigLog "link.data updated: $DataFile  <-  $line"
    } catch {
        Write-MigLog "link.data update failed: $($_.Exception.Message)"
    }
}

# ---------- 1. 自动提权 ----------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    try {
        Write-MigLog "Not admin, relaunching elevated. FolderA=$FolderA"
        $argList = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`" -FolderA `"$FolderA`""
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argList `
                          -Verb RunAs -Wait -PassThru
        exit $p.ExitCode
    } catch {
        Write-MigLog "Elevation cancelled or failed: $($_.Exception.Message)"
        exit 0
    }
}

try {
    Write-MigLog "=== Start (elevated), FolderA = $FolderA ==="

    # ---------- 2. 校验源目录 A ----------
    $FolderA = $FolderA.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($FolderA) -or
        -not (Test-Path -LiteralPath $FolderA -PathType Container)) {
        Show-ErrBox -Title "错误" -Message "路径不存在或不是文件夹：`n$FolderA"
        Write-MigLog "Invalid FolderA: $FolderA"
        exit 1
    }

    $FolderA = [System.IO.Path]::GetFullPath($FolderA).TrimEnd('\')
    Write-MigLog "Normalized FolderA = $FolderA"

    # 拒绝迁移磁盘根目录
    $driveRoot = [System.IO.Path]::GetPathRoot($FolderA).TrimEnd('\')
    if ($FolderA -eq $driveRoot) {
        Show-ErrBox -Title "错误" -Message "不能迁移磁盘根目录：`n$FolderA"
        Write-MigLog "Rejected drive root."
        exit 1
    }

    # 拒绝迁移本身已是链接的目录（reparse point）
    $item = Get-Item -LiteralPath $FolderA -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Show-ErrBox -Title "错误" -Message "该文件夹本身已是一个链接（Junction/符号链接），不能迁移：`n$FolderA"
        Write-MigLog "Rejected reparse point source."
        exit 1
    }

    $folderAName = Split-Path $FolderA -Leaf
    Write-MigLog "folderAName = $folderAName"

    # ---------- 3. 选择迁移目录 B ----------
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "迁移并链接`n`n待迁移的文件夹：`n$FolderA`n`n请选择迁移目标目录 B：`n将把文件夹迁移到「B\${folderAName}」，`n并在原位置创建指向新位置的链接。"
    $dialog.ShowNewFolderButton = $true
    $result = $dialog.ShowDialog()
    Write-MigLog "Dialog result = $result"

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-MigLog "User cancelled."
        exit 0
    }

    $FolderB = [System.IO.Path]::GetFullPath($dialog.SelectedPath).TrimEnd('\')
    Write-MigLog "Selected FolderB = $FolderB"

    if (-not (Test-Path -LiteralPath $FolderB -PathType Container)) {
        Show-ErrBox -Title "错误" -Message "选择的目录无效：`n$FolderB"
        exit 1
    }

    # ---------- 4. 计算目标路径并做安全校验 ----------
    $targetPath = Join-Path $FolderB $folderAName
    Write-MigLog "targetPath = $targetPath"

    # 目标目录不能等于待迁移文件夹本身
    if ($FolderB -eq $FolderA) {
        Show-ErrBox -Title "错误" -Message "目标目录不能是待迁移文件夹本身：`n$FolderA`n`n请选择其他目录。"
        exit 1
    }

    # 目标不能位于待迁移文件夹内部（把 A 移进自己内部会形成递归）
    if ($FolderB.StartsWith($FolderA + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Show-ErrBox -Title "错误" -Message "目标目录不能位于待迁移文件夹内部：`n$FolderB`n`n已取消操作。"
        exit 1
    }

    # 目标路径不能等于源目录本身（即 B 是 A 的父目录）
    if ($targetPath -eq $FolderA) {
        Show-ErrBox -Title "错误" -Message "目标位置与原文件夹相同：`n$FolderA`n`n请选择其他目录。"
        exit 1
    }

    # 目标路径已存在同名项：为保护真实数据，直接取消
    if (Test-Path -LiteralPath $targetPath) {
        Show-ErrBox -Title "错误" -Message "目标位置已存在同名项，为避免覆盖真实数据，已取消：`n$targetPath"
        Write-MigLog "Rejected: target already exists."
        exit 1
    }

    # 迁移前最终确认
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "即将执行：`n`n  原位置  : $FolderA`n  迁移到  : $targetPath`n  链接    : $FolderA → $targetPath`n`n继续吗？",
        "确认迁移",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-MigLog "User cancelled at final confirm."
        exit 0
    }

    # ---------- 5. 执行迁移 ----------
    $srcRoot = [System.IO.Path]::GetPathRoot($FolderA).TrimEnd('\').ToUpperInvariant()
    $dstRoot = [System.IO.Path]::GetPathRoot($targetPath).TrimEnd('\').ToUpperInvariant()
    $sameVolume = ($srcRoot -eq $dstRoot)
    Write-MigLog "sameVolume = $sameVolume"

    $moved = $false
    if ($sameVolume) {
        # 同卷：Move-Item 本质是重命名，瞬间完成
        try {
            Move-Item -LiteralPath $FolderA -Destination $targetPath -ErrorAction Stop
            $moved = $true
            Write-MigLog "Move-Item OK."
        } catch {
            Write-MigLog "Move-Item failed, will try robocopy: $($_.Exception.Message)"
        }
    }

    if (-not $moved) {
        # 跨卷（或 Move-Item 失败兜底）：robocopy /MOVE
        Write-MigLog "Executing robocopy /MOVE: $FolderA -> $targetPath"
        robocopy $FolderA $targetPath /E /MOVE /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        $rc = $LASTEXITCODE
        Write-MigLog "robocopy exit code = $rc"
        if ($rc -lt 8) {
            $moved = $true
            # 清理可能残留的空源目录
            if (Test-Path -LiteralPath $FolderA) {
                Remove-Item -LiteralPath $FolderA -Recurse -Force -ErrorAction SilentlyContinue
                Write-MigLog "Cleaned leftover source dir."
            }
        } else {
            # 迁移失败：回滚已拷贝的内容
            Write-MigLog "ROLLBACK (move failed): $targetPath -> $FolderA"
            robocopy $targetPath $FolderA /E /MOVE /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            Show-ErrBox -Title "失败" -Message "迁移失败（robocopy 退出码 $rc），已尝试把已拷贝的数据移回原位置。`n`n请检查：`n$FolderA`n`n详细日志：`n$script:logPath"
            exit 1
        }
    }

    if (-not $moved) {
        Show-ErrBox -Title "失败" -Message "迁移失败，数据仍留在原位置。`n$FolderA`n`n详细日志：`n$script:logPath"
        exit 1
    }

    # ---------- 6. 在原位置创建符号链接 ----------
    Write-MigLog "Creating symlink: $FolderA -> $targetPath"
    $cmdArgs = "/c mklink /D `"$FolderA`" `"$targetPath`""
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs `
                          -Wait -PassThru -WindowStyle Hidden
    Write-MigLog "mklink exit code = $($proc.ExitCode)"

    if ($proc.ExitCode -ne 0) {
        # 链接创建失败：回滚数据到原位置
        Write-MigLog "ROLLBACK (link failed): $targetPath -> $FolderA"
        $srcRoot = [System.IO.Path]::GetPathRoot($targetPath).TrimEnd('\').ToUpperInvariant()
        $dstRoot = [System.IO.Path]::GetPathRoot($FolderA).TrimEnd('\').ToUpperInvariant()
        if ($srcRoot -eq $dstRoot) {
            Move-Item -LiteralPath $targetPath -Destination $FolderA -ErrorAction SilentlyContinue
        } else {
            robocopy $targetPath $FolderA /E /MOVE /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        }
        Show-ErrBox -Title "失败" -Message "链接创建失败，数据已移回原位置。`n`n可能原因：`n- 权限不足（未开启开发者模式且非管理员）`n- 目标路径格式异常`n`n数据位置：`n$FolderA`n`n详细日志：`n$script:logPath"
        exit 1
    }

    # ---------- 7. 在真实数据目录记录 link.data ----------
    $dataFile = Join-Path $targetPath 'link.data'
    Update-LinkData -DataFile $dataFile -LinkedFrom $FolderA

    # ---------- 8. 成功提示 ----------
    [System.Windows.Forms.MessageBox]::Show(
        "迁移并链接成功！`n`n链接位置（原位置）：`n$FolderA`n    → 指向：`n$targetPath`n`n提示：`n- 真实数据现在位于 $targetPath`n- 原位置 $FolderA 现在是一个符号链接`n- 删除链接不会影响真实数据`n- 已记录链接来源：$dataFile",
        "成功",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    Write-MigLog "=== Done successfully. ==="
}
catch {
    $msg = "发生未处理异常：`n$($_.Exception.Message)`n`n详细信息已写入日志：`n$script:logPath"
    Show-ErrBox -Title "错误" -Message $msg
    Write-MigLog "EXCEPTION: $($_.Exception.ToString())"
    exit 1
}
