# MigrateLinkFolder.ps1
# 用法：被右键菜单调用，参数为右键选中的文件夹路径（即 A）
# 功能：
#   1. 自动提权（非管理员时弹 UAC，以管理员身份重启，应对跨盘回退到符号链接等场景）
#   2. 用户选择迁移目录 B
#   3. 把 A 迁移到 B\A名（同卷用 Move-Item 瞬间完成；跨卷用 robocopy /MOVE）
#   4. 在原位置 A 创建链接：优先 Junction（mklink /J，免管理员）；跨盘时 Junction 失败则回退 Symlink（mklink /D）
#   5. 任一步失败自动把数据回滚到原位置
#
# 安全防护：
#   - 拒绝迁移磁盘根目录、本身已是链接（Junction/符号链接）的目录
#   - 拒绝把目录迁移进自己内部、或迁移到原位置自身
#   - 目标位置已有同名项时直接取消（避免覆盖真实数据）
#
# 日志说明：
#   - 日志统一写入 %LOCALAPPDATA%\FolderLinkMenu\logs（稳定、易找，不会被 TEMP 清理）
#   - 失败时对话框会询问是否直接打开日志文件夹

param(
    [Parameter(Mandatory=$true)]
    [string]$FolderA,
    [string]$LogFile
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 日志路径 ----------
$script:logDir = if ($LogFile) {
    Split-Path $LogFile -Parent
} else {
    $dir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "FolderLinkMenu\logs" } else { Join-Path $env:TEMP "FolderLinkMenu\logs" }
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    $dir
}
if (-not (Test-Path -LiteralPath $script:logDir)) {
    New-Item -Path $script:logDir -ItemType Directory -Force | Out-Null
}
if ($LogFile) {
    $script:logPath = $LogFile
} else {
    $script:logPath = Join-Path $script:logDir "MigrateLinkFolder_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
}

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

# 错误提示 + 询问是否打开日志文件夹
function Show-ErrBox-OpenLog {
    param([string]$Title, [string]$Message)
    $r = [System.Windows.Forms.MessageBox]::Show(
        "$Message`n`n是否打开日志文件夹？",
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        explorer.exe $script:logDir | Out-Null
    }
}

# robocopy 封装：/MOVE 迁移 + 重试 + 捕获失败明细，返回退出码
# 退出码 >= 8 表示有文件复制失败
function Invoke-RobocopyMove {
    param(
        [string]$Src,
        [string]$Dst,
        [string]$Phase
    )
    Write-MigLog "ROBOCOPY /MOVE ($Phase): $Src -> $Dst"
    # R:3/W:2 = 每个失败文件重试 3 次、间隔 2 秒，应对瞬时占用
    $output = robocopy $Src $Dst /E /MOVE /R:3 /W:2 /NFL /NDL /NJH /NJS /NP 2>&1 | Out-String
    $rc = $LASTEXITCODE
    Write-MigLog "robocopy exit code = $rc (phase=$Phase)"

    # 把 robocopy 的 ERROR 明细（哪个文件、什么错误码）写入日志
    $errLines = @($output -split "`r?`n" | Where-Object { $_ -match 'ERROR' })
    if ($errLines.Count -gt 0) {
        Write-MigLog "---- robocopy errors (phase=$Phase) ----"
        foreach ($l in $errLines) { Write-MigLog $l.Trim() }
        Write-MigLog "---- end errors ----"
    } else {
        Write-MigLog "(no ERROR lines, phase=$Phase)"
    }
    return $rc
}

# 预检：扫描源目录中被独占占用的文件（用于迁移前提示，不阻断操作）
function Get-LockedFiles {
    param([string]$Root, [int]$Max = 2000)
    $locked = New-Object System.Collections.Generic.List[string]
    $count = 0
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $count++
        if ($count -gt $Max) { break }
        try {
            $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            $fs.Close()
        } catch {
            $locked.Add($f.FullName)
        }
    }
    return @($locked)
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
        # 把当前日志路径传给提权后的进程，保证整个操作只用一个日志文件
        $argList = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`" -FolderA `"$FolderA`" -LogFile `"$script:logPath`""
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
    Write-MigLog "Log file: $script:logPath"

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

    # ---------- 4.5 预检占用文件 + 迁移前最终确认 ----------
    $preLocked = @()
    try {
        Write-MigLog "Pre-checking locked files in $FolderA ..."
        $preLocked = @(Get-LockedFiles -Root $FolderA)
        Write-MigLog "Pre-check done. locked count = $($preLocked.Count)"
    } catch {
        Write-MigLog "Pre-check failed: $($_.Exception.Message)"
    }

    $lockWarn = ""
    if ($preLocked.Count -gt 0) {
        $lockWarn = "`n[警告] 检测到 $($preLocked.Count) 个文件正被其他程序占用，`n迁移可能失败。建议先关闭正在使用该文件夹的程序（如游戏、浏览器、视频播放器等）。`n`n占用示例：`n$($preLocked[0])`n"
        foreach ($f in $preLocked | Select-Object -First 3) {
            Write-MigLog "Pre-check locked: $f"
        }
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "即将执行：`n`n  原位置  : $FolderA`n  迁移到  : $targetPath`n  链接    : $FolderA → $targetPath`n`n$lockWarn`n继续吗？",
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
        $rc = Invoke-RobocopyMove -Src $FolderA -Dst $targetPath -Phase "move"
        if ($rc -lt 8) {
            $moved = $true
            # 清理可能残留的空源目录
            if (Test-Path -LiteralPath $FolderA) {
                Remove-Item -LiteralPath $FolderA -Recurse -Force -ErrorAction SilentlyContinue
                Write-MigLog "Cleaned leftover source dir."
            }
        } else {
            # 迁移失败：回滚已拷贝的内容（并校验回滚结果）
            Write-MigLog "ROLLBACK (move failed, rc=$rc): $targetPath -> $FolderA"
            $rcb = Invoke-RobocopyMove -Src $targetPath -Dst $FolderA -Phase "rollback"

            if ($rcb -ge 8) {
                # 回滚也失败：数据可能分裂在两处，严重警告
                Write-MigLog "!!! ROLLBACK ALSO FAILED (rc=$rcb) - data may be SPLIT!"
                $msg = "迁移失败（robocopy 退出码 $rc），且回滚也失败（退出码 $rcb）！`n`n数据可能同时存在于两个位置，请先不要删除任何数据！`n`n源位置：`n$FolderA`n`n目标位置：`n$targetPath`n`n详细日志：`n$script:logPath"
                Show-ErrBox-OpenLog -Title "严重错误：回滚失败" -Message $msg
                exit 1
            } else {
                # 回滚成功：清理空目标目录
                if (Test-Path -LiteralPath $targetPath) {
                    Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction SilentlyContinue
                    Write-MigLog "Cleaned empty target dir after rollback."
                }
                $msg = "迁移失败（robocopy 退出码 $rc），已把已拷贝的数据移回原位置。`n`n可能原因：`n- 文件夹正被程序占用（如 GPU 缓存、正在使用的文件）`n- 权限不足`n- 路径含特殊字符`n`n请检查：`n$FolderA`n`n详细日志：`n$script:logPath"
                Show-ErrBox-OpenLog -Title "迁移失败" -Message $msg
                exit 1
            }
        }
    }

    if (-not $moved) {
        Show-ErrBox -Title "失败" -Message "迁移失败，数据仍留在原位置。`n$FolderA`n`n详细日志：`n$script:logPath"
        exit 1
    }

    # ---------- 6. 在原位置创建链接 ----------
    # 优先 Junction（mklink /J，免管理员、同盘足够）；跨盘时 Junction 失败则回退 Symlink（mklink /D）
    $linkMade = $false
    # 优先 Junction（mklink /J，免管理员）；跨盘时 Junction 会失败，下方回退 Symlink
    Write-MigLog "Creating link (try Junction first): $FolderA -> $targetPath"
    $cmdArgs = "/c mklink /J `"$FolderA`" `"$targetPath`""
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs `
                          -Wait -PassThru -WindowStyle Hidden
    Write-MigLog "mklink /J exit code = $($proc.ExitCode)"

    if ($proc.ExitCode -ne 0) {
        # Junction 失败（常见于跨盘），回退 Symlink（需要管理员）
        Write-MigLog "Junction failed, fallback to Symlink (mklink /D): $FolderA -> $targetPath"
        $cmdArgs = "/c mklink /D `"$FolderA`" `"$targetPath`""
        $proc = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs `
                              -Wait -PassThru -WindowStyle Hidden
        Write-MigLog "mklink /D exit code = $($proc.ExitCode)"
    } else {
        $linkMade = $true
    }

    if ($proc.ExitCode -ne 0) {
        # 链接创建失败：回滚数据到原位置（并校验回滚结果）
        Write-MigLog "ROLLBACK (link failed): $targetPath -> $FolderA"
        $srcRoot = [System.IO.Path]::GetPathRoot($targetPath).TrimEnd('\').ToUpperInvariant()
        $dstRoot = [System.IO.Path]::GetPathRoot($FolderA).TrimEnd('\').ToUpperInvariant()
        $rcb = 0
        if ($srcRoot -eq $dstRoot) {
            Move-Item -LiteralPath $targetPath -Destination $FolderA -ErrorAction SilentlyContinue
            Write-MigLog "Rollback via Move-Item done."
        } else {
            $rcb = Invoke-RobocopyMove -Src $targetPath -Dst $FolderA -Phase "rollback_link"
        }

        if ($rcb -ge 8) {
            Write-MigLog "!!! ROLLBACK (link) ALSO FAILED (rc=$rcb) - data may be SPLIT!"
            $msg = "链接创建失败，且回滚也失败（退出码 $rcb）！`n`n数据可能同时存在于两个位置，请先不要删除任何数据！`n`n源位置：`n$FolderA`n`n目标位置：`n$targetPath`n`n详细日志：`n$script:logPath"
            Show-ErrBox-OpenLog -Title "严重错误：回滚失败" -Message $msg
            exit 1
        } else {
            $msg = "链接创建失败，数据已移回原位置。`n`n可能原因：`n- 权限不足（未开启开发者模式且非管理员）`n- 目标路径格式异常`n`n数据位置：`n$FolderA`n`n详细日志：`n$script:logPath"
            Show-ErrBox-OpenLog -Title "失败" -Message $msg
            exit 1
        }
    }

    # ---------- 7. 在真实数据目录记录 link.data ----------
    $dataFile = Join-Path $targetPath 'link.data'
    Update-LinkData -DataFile $dataFile -LinkedFrom $FolderA

    # ---------- 8. 成功提示 ----------
    [System.Windows.Forms.MessageBox]::Show(
        "迁移并链接成功！`n`n链接位置（原位置）：`n$FolderA`n    → 指向：`n$targetPath`n`n提示：`n- 真实数据现在位于 $targetPath`n- 原位置 $FolderA 现在是一个符号链接`n- 删除链接不会影响真实数据`n- 已记录链接来源：$dataFile`n`n详细日志：`n$script:logPath",
        "成功",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    Write-MigLog "=== Done successfully. ==="
}
catch {
    $msg = "发生未处理异常：`n$($_.Exception.Message)`n`n详细信息已写入日志：`n$script:logPath"
    Show-ErrBox-OpenLog -Title "错误" -Message $msg
    Write-MigLog "EXCEPTION: $($_.Exception.ToString())"
    exit 1
}
