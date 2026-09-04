# MigrateLinkFolder.ps1
# 用法：被右键菜单调用，参数为右键选中的文件夹路径（即 A）
# 功能：
#   1. 自动提权（非管理员时弹 UAC，以管理员身份重启）
#   2. 用户选择迁移目录 B
#   3. 用户选择链接类型（Junction / Symlink）
#   4. 把 A 迁移到 B\A名（同卷用 Move-Item；跨卷用 robocopy /MOVE）
#   5. 在原位置 A 创建链接（用户选择的类型）
#   6. 任一步失败自动回滚数据
#   7. link.data 记录在【脚本根目录】下，文件名：<原文件夹名>.link.data
#
# 安全防护：
#   - 拒绝迁移磁盘根目录、本身已是链接的目录
#   - 拒绝把目录迁移进自己内部
#   - 目标位置已有同名项时直接取消
#
# 日志：%LOCALAPPDATA%\FolderLinkMenu\logs

param(
    [Parameter(Mandatory=$true)]
    [string]$FolderA,
    [string]$LogFile
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:scriptDir = $scriptDir

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
        $Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

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

# link.data 存在脚本根目录，文件名为 <原文件夹名>.link.data
function Update-LinkData {
    param([string]$LinkedFrom, [string]$FolderName)
    try {
        $dataFile = Join-Path $script:scriptDir "${FolderName}.link.data"
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $line = "[$timestamp]$LinkedFrom"
        if (Test-Path -LiteralPath $dataFile -PathType Leaf) {
            $lines = @(Get-Content -LiteralPath $dataFile -Encoding UTF8)
            $updated = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $m = [regex]::Match($lines[$i], '^\[[^\]]*\]\s*(.*)$')
                if ($m.Success -and $m.Groups[1].Value.Trim() -eq $LinkedFrom) {
                    $lines[$i] = $line
                    $updated = $true
                    break
                }
            }
            if (-not $updated) { $lines += $line }
            $lines | Set-Content -LiteralPath $dataFile -Encoding UTF8
        } else {
            $line | Set-Content -LiteralPath $dataFile -Encoding UTF8
        }
        Write-MigLog "link.data updated: $dataFile  <-  $line"
    } catch {
        Write-MigLog "link.data update failed: $($_.Exception.Message)"
    }
}

# robocopy 封装
function Invoke-RobocopyMove {
    param([string]$Src, [string]$Dst, [string]$Phase)
    Write-MigLog "ROBOCOPY /MOVE ($Phase): $Src -> $Dst"
    $output = robocopy $Src $Dst /E /MOVE /R:3 /W:2 /NFL /NDL /NJH /NJS /NP 2>&1 | Out-String
    $rc = $LASTEXITCODE
    Write-MigLog "robocopy exit code = $rc (phase=$Phase)"
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

# 预检锁定文件
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

# ---------- 1. 自动提权 ----------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    try {
        Write-MigLog "Not admin, relaunching elevated. FolderA=$FolderA"
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

    # ---------- 2. 校验源目录 ----------
    $FolderA = $FolderA.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($FolderA) -or
        -not (Test-Path -LiteralPath $FolderA -PathType Container)) {
        Show-ErrBox -Title "错误" -Message "路径不存在或不是文件夹：`n$FolderA"
        exit 1
    }
    $FolderA = [System.IO.Path]::GetFullPath($FolderA).TrimEnd('\')
    Write-MigLog "Normalized FolderA = $FolderA"

    $driveRoot = [System.IO.Path]::GetPathRoot($FolderA).TrimEnd('\')
    if ($FolderA -eq $driveRoot) {
        Show-ErrBox -Title "错误" -Message "不能迁移磁盘根目录：`n$FolderA"
        exit 1
    }

    $item = Get-Item -LiteralPath $FolderA -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Show-ErrBox -Title "错误" -Message "该文件夹本身已是一个链接，不能迁移：`n$FolderA"
        exit 1
    }

    $folderAName = Split-Path $FolderA -Leaf
    Write-MigLog "folderAName = $folderAName"

    # ---------- 3. 选择迁移目录 ----------
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "迁移并链接`n`n待迁移的文件夹：`n$FolderA`n`n请选择迁移目标目录 B：`n将把文件夹迁移到「B\${folderAName}」，`n并在原位置创建链接。"
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

    # ---------- 4. 计算目标路径 + 安全校验 ----------
    $targetPath = Join-Path $FolderB $folderAName
    Write-MigLog "targetPath = $targetPath"

    if ($FolderB -eq $FolderA) {
        Show-ErrBox -Title "错误" -Message "目标目录不能是待迁移文件夹本身：`n$FolderA"
        exit 1
    }
    if ($FolderB.StartsWith($FolderA + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Show-ErrBox -Title "错误" -Message "目标目录不能位于待迁移文件夹内部：`n$FolderB"
        exit 1
    }
    if ($targetPath -eq $FolderA) {
        Show-ErrBox -Title "错误" -Message "目标位置与原文件夹相同：`n$FolderA"
        exit 1
    }
    if (Test-Path -LiteralPath $targetPath) {
        Show-ErrBox -Title "错误" -Message "目标位置已存在同名项，已取消：`n$targetPath"
        exit 1
    }

    # ---------- 4.5 预检锁定文件 ----------
    $preLocked = @()
    try {
        Write-MigLog "Pre-checking locked files..."
        $preLocked = @(Get-LockedFiles -Root $FolderA)
        Write-MigLog "locked count = $($preLocked.Count)"
    } catch {
        Write-MigLog "Pre-check failed: $($_.Exception.Message)"
    }
    $lockWarn = ""
    if ($preLocked.Count -gt 0) {
        $lockWarn = "`n[警告] 检测到 $($preLocked.Count) 个文件正被其他程序占用，`n迁移可能失败。建议先关闭相关程序。"
        foreach ($f in $preLocked | Select-Object -First 3) { Write-MigLog "Pre-check locked: $f" }
    }

    # ---------- 5. 选择链接类型（Junction / Symlink）----------
    $formLinkType = New-Object System.Windows.Forms.Form
    $formLinkType.Text      = "选择链接类型"
    $formLinkType.Size      = New-Object System.Drawing.Size(440, 210)
    $formLinkType.StartPosition = "CenterScreen"
    $formLinkType.FormBorderStyle = "FixedDialog"
    $formLinkType.MaximizeBox = $false
    $formLinkType.MinimizeBox = $false

    $lblLinkType = New-Object System.Windows.Forms.Label
    $lblLinkType.Location = New-Object System.Drawing.Point(12, 12)
    $lblLinkType.Size     = New-Object System.Drawing.Size(400, 60)
    $lblLinkType.Text     = "请在原位置创建哪种类型的链接？`n`nJunction  — 同卷快速创建，无需管理员，但无法跨盘`nSymlink   — 支持跨盘，可能需要管理员权限"
    $formLinkType.Controls.Add($lblLinkType)

    $rbJunction = New-Object System.Windows.Forms.RadioButton
    $rbJunction.Location = New-Object System.Drawing.Point(20, 80)
    $rbJunction.Size     = New-Object System.Drawing.Size(380, 20)
    $rbJunction.Text     = "Junction (mklink /J) — 同卷，免管理员"
    $rbJunction.Checked  = $true
    $formLinkType.Controls.Add($rbJunction)

    $rbSymlink = New-Object System.Windows.Forms.RadioButton
    $rbSymlink.Location = New-Object System.Drawing.Point(20, 110)
    $rbSymlink.Size     = New-Object System.Drawing.Size(380, 20)
    $rbSymlink.Text     = "Symlink (mklink /D) — 跨卷支持，可能需要管理员"
    $formLinkType.Controls.Add($rbSymlink)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Location = New-Object System.Drawing.Point(196, 145)
    $btnOk.Size     = New-Object System.Drawing.Size(100, 32)
    $btnOk.Text     = "确定"
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $formLinkType.Controls.Add($btnOk)
    $formLinkType.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Location = New-Object System.Drawing.Point(306, 145)
    $btnCancel.Size     = New-Object System.Drawing.Size(100, 32)
    $btnCancel.Text     = "取消"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $formLinkType.Controls.Add($btnCancel)
    $formLinkType.CancelButton = $btnCancel

    $linkResult = $formLinkType.ShowDialog()
    if ($linkResult -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-MigLog "User cancelled at link type selection."
        exit 0
    }
    $forceSymlink = -not $rbJunction.Checked
    Write-MigLog "Link type selected: $(if($forceSymlink){'Symlink'}else{'Junction'})"

    # ---------- 6. 最终确认 ----------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "确认迁移"
    $form.Size = New-Object System.Drawing.Size(540, 320)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size     = New-Object System.Drawing.Size(504, 140)
    $label.AutoSize = $false
    $label.Text     = ("即将执行：`n`n  原位置  : $FolderA`n  迁移到  : $targetPath`n  链接类型 : $(if($forceSymlink){'Symlink (/D)'}else{'Junction (/J)'})`n$lockWarn").TrimEnd("`n")
    $form.Controls.Add($label)

    $btnYes = New-Object System.Windows.Forms.Button
    $btnYes.Location = New-Object System.Drawing.Point(268, 265)
    $btnYes.Size     = New-Object System.Drawing.Size(120, 32)
    $btnYes.Text     = "是(&Y)"
    $btnYes.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $form.Controls.Add($btnYes)
    $form.AcceptButton = $btnYes

    $btnNo = New-Object System.Windows.Forms.Button
    $btnNo.Location = New-Object System.Drawing.Point(396, 265)
    $btnNo.Size     = New-Object System.Drawing.Size(120, 32)
    $btnNo.Text     = "否(&N)"
    $btnNo.DialogResult = [System.Windows.Forms.DialogResult]::No
    $form.Controls.Add($btnNo)
    $form.CancelButton = $btnNo

    $confirm = $form.ShowDialog()
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-MigLog "User cancelled at final confirm."
        exit 0
    }

    # ---------- 7. 执行迁移 ----------
    $srcRoot = [System.IO.Path]::GetPathRoot($FolderA).TrimEnd('\').ToUpperInvariant()
    $dstRoot = [System.IO.Path]::GetPathRoot($targetPath).TrimEnd('\').ToUpperInvariant()
    $sameVolume = ($srcRoot -eq $dstRoot)
    Write-MigLog "sameVolume = $sameVolume"

    $moved = $false
    if ($sameVolume) {
        try {
            Move-Item -LiteralPath $FolderA -Destination $targetPath -ErrorAction Stop
            $moved = $true
            Write-MigLog "Move-Item OK."
        } catch {
            Write-MigLog "Move-Item failed, will try robocopy: $($_.Exception.Message)"
        }
    }
    if (-not $moved) {
        $rc = Invoke-RobocopyMove -Src $FolderA -Dst $targetPath -Phase "move"
        if ($rc -lt 8) {
            $moved = $true
            if (Test-Path -LiteralPath $FolderA) {
                Remove-Item -LiteralPath $FolderA -Recurse -Force -ErrorAction SilentlyContinue
                Write-MigLog "Cleaned leftover source dir."
            }
        } else {
            Write-MigLog "ROLLBACK (move failed, rc=$rc): $targetPath -> $FolderA"
            $rcb = Invoke-RobocopyMove -Src $targetPath -Dst $FolderA -Phase "rollback"
            if ($rcb -ge 8) {
                Write-MigLog "!!! ROLLBACK ALSO FAILED (rc=$rcb) - data may be SPLIT!"
                $msg = "迁移失败（robocopy 退出码 $rc），且回滚也失败（退出码 $rcb）！`n`n数据可能同时存在于两个位置，请先不要删除任何数据！`n`n源位置：`n$FolderA`n`n目标位置：`n$targetPath`n`n详细日志：`n$script:logPath"
                Show-ErrBox-OpenLog -Title "严重错误：回滚失败" -Message $msg
                exit 1
            } else {
                if (Test-Path -LiteralPath $targetPath) {
                    Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction SilentlyContinue
                    Write-MigLog "Cleaned empty target dir after rollback."
                }
                $msg = "迁移失败（robocopy 退出码 $rc），已把数据移回原位置。`n`n可能原因：`n- 文件夹正被程序占用`n- 权限不足`n- 路径含特殊字符`n`n详细日志：`n$script:logPath"
                Show-ErrBox-OpenLog -Title "迁移失败" -Message $msg
                exit 1
            }
        }
    }
    if (-not $moved) {
        Show-ErrBox -Title "失败" -Message "迁移失败，数据仍留在原位置。`n$FolderA`n`n详细日志：`n$script:logPath"
        exit 1
    }

    # ---------- 8. 创建链接 ----------
    $cmdArgs = if ($forceSymlink) {
        "/c mklink /D `"$FolderA`" `"$targetPath`""
    } else {
        "/c mklink /J `"$FolderA`" `"$targetPath`""
    }
    Write-MigLog "Creating link: cmd $cmdArgs"
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs `
                          -Wait -PassThru -WindowStyle Hidden
    $tag = if ($forceSymlink) { "mklink /D" } else { "mklink /J" }
    Write-MigLog "$tag exit code = $($proc.ExitCode)"

    if ($proc.ExitCode -ne 0) {
        Write-MigLog "ROLLBACK (link failed): $targetPath -> $FolderA"
        $rcb = 0
        if ($sameVolume) {
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

    # ---------- 9. 更新 link.data（存入脚本根目录）----------
    Update-LinkData -LinkedFrom $FolderA -FolderName $folderAName

    # ---------- 10. 成功提示 ----------
    [System.Windows.Forms.MessageBox]::Show(
        "迁移并链接成功！`n`n链接类型  : $(if($forceSymlink){'Symlink (/D)'}else{'Junction (/J)'})`n链接位置（原位置）: $FolderA`n    → 指向：$targetPath`n`n提示：`n- 真实数据现在位于 $targetPath`n- 原位置 $FolderA 现在是符号链接`n- 删除链接不会影响真实数据`n- 链接记录已保存至：$(Join-Path $script:scriptDir "${folderAName}.link.data")`n`n详细日志：`n$script:logPath",
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
