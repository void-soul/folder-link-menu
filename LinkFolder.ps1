# LinkFolder.ps1
# 用法：被右键菜单调用，参数为右键选中的文件夹路径（即 A）
# 功能：弹出对话框让用户选择容器目录 B，选择链接类型（Junction/Symlink），
#        在 B 下建立指向 A 的链接，链接名称与 A 相同。
#        link.data 记录在【脚本根目录】下，文件名：<原文件夹名>.link.data

param(
    [Parameter(Mandatory=$true)]
    [string]$FolderA
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:logPath = Join-Path $env:TEMP "LinkFolder_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:scriptDir = $scriptDir

function Write-LinkLog {
    param([string]$Message)
    try {
        "$(Get-Date -Format 'HH:mm:ss.fff')  $Message" | Add-Content -LiteralPath $script:logPath -Encoding UTF8
    } catch { }
}

function Show-ErrorBox {
    param([string]$Title, [string]$Message)
    [System.Windows.Forms.MessageBox]::Show(
        $Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

# link.data 存在脚本根目录，文件名为 <原文件夹名>.link.data
# 记录「何时、哪个链接指向该目录」
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
        Write-LinkLog "link.data updated: $dataFile  <-  $line"
    } catch {
        Write-LinkLog "link.data update failed: $($_.Exception.Message)"
    }
}

try {
    Write-LinkLog "=== Start, FolderA = $FolderA ==="

    # 1. 校验路径
    $FolderA = $FolderA.Trim().Trim('"').Trim("'")
    Write-LinkLog "Normalized FolderA = $FolderA"

    if ([string]::IsNullOrWhiteSpace($FolderA) -or
        -not (Test-Path -LiteralPath $FolderA -PathType Container)) {
        Show-ErrorBox -Title "错误" -Message "路径不存在或不是文件夹：`n$FolderA"
        exit 1
    }

    $folderAName = Split-Path $FolderA -Leaf
    if ([string]::IsNullOrWhiteSpace($folderAName)) {
        $folderAName = "linked_folder_$(Get-Date -Format 'HHmmss')"
    }
    Write-LinkLog "folderAName = $folderAName"

    # 2. 选择链接类型：Junction / Symlink
    $form = New-Object System.Windows.Forms.Form
    $form.Text      = "选择链接类型"
    $form.Size      = New-Object System.Drawing.Size(440, 210)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size     = New-Object System.Drawing.Size(400, 60)
    $lbl.Text     = "请选择要创建的链接类型：`n`nJunction  — 同卷快速创建，无需管理员，但无法跨盘`nSymlink   — 支持跨盘，可能需要管理员权限"
    $form.Controls.Add($lbl)

    $rbJunction = New-Object System.Windows.Forms.RadioButton
    $rbJunction.Location = New-Object System.Drawing.Point(20, 80)
    $rbJunction.Size     = New-Object System.Drawing.Size(380, 20)
    $rbJunction.Text     = "Junction (mklink /J) — 同卷，免管理员"
    $rbJunction.Checked  = $true
    $form.Controls.Add($rbJunction)

    $rbSymlink = New-Object System.Windows.Forms.RadioButton
    $rbSymlink.Location = New-Object System.Drawing.Point(20, 110)
    $rbSymlink.Size     = New-Object System.Drawing.Size(380, 20)
    $rbSymlink.Text     = "Symlink (mklink /D) — 跨卷支持，可能需要管理员"
    $form.Controls.Add($rbSymlink)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Location = New-Object System.Drawing.Point(196, 145)
    $btnOk.Size     = New-Object System.Drawing.Size(100, 32)
    $btnOk.Text     = "确定"
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOk)
    $form.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Location = New-Object System.Drawing.Point(306, 145)
    $btnCancel.Size     = New-Object System.Drawing.Size(100, 32)
    $btnCancel.Text     = "取消"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-LinkLog "User cancelled link type selection."
        exit 0
    }
    $useSymlink = -not $rbJunction.Checked
    Write-LinkLog "Link type selected: $(if($useSymlink){'Symlink'}else{'Junction'})"

    # 3. 选择目标容器目录 B
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $linkTypeLabel = if ($useSymlink) { "Symlink" } else { "Junction" }
    $dialog.Description = "请选择目标容器目录 B`n将在此目录下创建名为「$folderAName」的 $linkTypeLabel 链接，指向：`n$FolderA"
    $dialog.ShowNewFolderButton = $true
    $result = $dialog.ShowDialog()
    Write-LinkLog "Dialog result = $result"

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-LinkLog "User cancelled."
        exit 0
    }

    $FolderB = $dialog.SelectedPath
    Write-LinkLog "Selected FolderB = $FolderB"

    if (-not (Test-Path -LiteralPath $FolderB -PathType Container)) {
        Show-ErrorBox -Title "错误" -Message "选择的目录无效：`n$FolderB"
        exit 1
    }

    # 4. 确定链接完整路径
    $linkFullPath = Join-Path $FolderB $folderAName
    Write-LinkLog "linkFullPath = $linkFullPath"

    if (Test-Path -LiteralPath $linkFullPath) {
        $overwrite = [System.Windows.Forms.MessageBox]::Show(
            "目标位置已存在同名项，是否覆盖？`n`n$linkFullPath",
            "确认覆盖",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($overwrite -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-LinkLog "User chose not to overwrite."
            exit 0
        }
        cmd /c "rd `"$linkFullPath`"" 2>$null
        Remove-Item -LiteralPath $linkFullPath -Force -ErrorAction SilentlyContinue
    }

    # 5. 创建链接
    $cmdArgs = if ($useSymlink) {
        "/c mklink /D `"$linkFullPath`" `"$FolderA`""
    } else {
        "/c mklink /J `"$linkFullPath`" `"$FolderA`""
    }
    Write-LinkLog "Executing: cmd $cmdArgs"
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs `
                          -Wait -PassThru -WindowStyle Hidden
    Write-LinkLog "mklink exit code = $($proc.ExitCode)"

    if ($proc.ExitCode -eq 0) {
        Update-LinkData -LinkedFrom $linkFullPath -FolderName $folderAName

        [System.Windows.Forms.MessageBox]::Show(
            "链接创建成功！`n`n链接类型  : $(if($useSymlink){'Symlink (/D)'}else{'Junction (/J)'})`n链接位置  : $linkFullPath`n指向      : $FolderA`n记录文件  : $(Join-Path $script:scriptDir "${folderAName}.link.data")",
            "成功",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        Write-LinkLog "Link created successfully."
    } else {
        Show-ErrorBox -Title "失败" -Message "创建链接失败！`n`n可能原因：`n- 目标位置已有同名真实目录（非链接）`n- 权限不足（Symlink 可能需要管理员）`n- 路径含特殊字符`n`n详细日志：`n$script:logPath"
        exit 1
    }
}
catch {
    $msg = "发生未处理异常：`n$($_.Exception.Message)`n`n详细信息已写入日志：`n$script:logPath"
    Show-ErrorBox -Title "错误" -Message $msg
    Write-LinkLog "EXCEPTION: $($_.Exception.ToString())"
    exit 1
}
