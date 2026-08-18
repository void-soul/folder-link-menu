# LinkFolder.ps1
# 用法：被右键菜单调用，参数为右键选中的文件夹路径（即 A）
# 功能：弹出对话框让用户选择容器目录 B，然后在 B 下建立指向 A 的 Junction 链接，链接名称与 A 相同

param(
    [Parameter(Mandatory=$true)]
    [string]$FolderA
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 错误日志路径（避免"一闪而过"无迹可寻）
$script:logPath = Join-Path $env:TEMP "LinkFolder_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-LinkLog {
    param([string]$Message)
    try {
        "$(Get-Date -Format 'HH:mm:ss.fff')  $Message" | Add-Content -LiteralPath $script:logPath -Encoding UTF8
    } catch { }
}

function Show-ErrorBox {
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
        Write-LinkLog "link.data updated: $DataFile  <-  $line"
    } catch {
        Write-LinkLog "link.data update failed: $($_.Exception.Message)"
    }
}

try {
    Write-LinkLog "=== Start, FolderA = $FolderA ==="

    # 1. 验证 A 的路径（去掉可能的多余引号/空白）
    $FolderA = $FolderA.Trim().Trim('"').Trim("'")
    Write-LinkLog "Normalized FolderA = $FolderA"

    if ([string]::IsNullOrWhiteSpace($FolderA) -or
        -not (Test-Path -LiteralPath $FolderA -PathType Container)) {
        Show-ErrorBox -Title "错误" -Message "路径不存在或不是文件夹：`n$FolderA"
        Write-LinkLog "Invalid FolderA: $FolderA"
        exit 1
    }

    $folderAName = Split-Path $FolderA -Leaf
    if ([string]::IsNullOrWhiteSpace($folderAName)) {
        $folderAName = "linked_folder_$(Get-Date -Format 'HHmmss')"
    }
    Write-LinkLog "folderAName = $folderAName"

    # 2. 弹出目录选择对话框，让用户选择容器目录 B
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "请选择目标容器目录 B`n将在 B 下建立名为「$folderAName」的链接，指向：`n$FolderA"
    $dialog.ShowNewFolderButton = $true
    # Win11 兼容：使用默认根，不强制 MyComputer，避免部分系统上 RootFolder 枚举异常
    $result = $dialog.ShowDialog()
    Write-LinkLog "Dialog result = $result"

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-LinkLog "User cancelled."
        exit 0
    }

    $FolderB = $dialog.SelectedPath
    Write-LinkLog "Selected FolderB = $FolderB"

    # 3. 验证 B 的路径
    if (-not (Test-Path -LiteralPath $FolderB -PathType Container)) {
        Show-ErrorBox -Title "错误" -Message "选择的目录无效：`n$FolderB"
        Write-LinkLog "Invalid FolderB: $FolderB"
        exit 1
    }

    # 4. 确定链接完整路径：B\A名称
    $linkFullPath = Join-Path $FolderB $folderAName
    Write-LinkLog "linkFullPath = $linkFullPath"

    # 如果 B 下已存在同名项，询问是否覆盖
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

    # 5. 建立 Junction 链接：mklink /J B\A名 A路径
    $cmdArgs = "/c mklink /J `"$linkFullPath`" `"$FolderA`""
    Write-LinkLog "Executing: cmd $cmdArgs"
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs `
                          -Wait -PassThru -WindowStyle Hidden
    Write-LinkLog "mklink exit code = $($proc.ExitCode)"

    if ($proc.ExitCode -eq 0) {
        # 在真实数据目录（FolderA）创建/更新 link.data，记录哪个链接指向了该目录
        $dataFile = Join-Path $FolderA 'link.data'
        Update-LinkData -DataFile $dataFile -LinkedFrom $linkFullPath

        [System.Windows.Forms.MessageBox]::Show(
            "链接创建成功！`n`n链接位置：`n$linkFullPath`n`n指向：`n$FolderA`n`n已记录：`n$dataFile",
            "成功",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        Write-LinkLog "Link created successfully."
    } else {
        Show-ErrorBox -Title "失败" -Message "创建链接失败！`n`n可能原因：`n- B 下已有同名真实目录（非链接）`n- 权限不足`n- 路径含特殊字符`n`n详细日志：`n$script:logPath"
        exit 1
    }
}
catch {
    $msg = "发生未处理异常：`n$($_.Exception.Message)`n`n详细信息已写入日志：`n$script:logPath"
    Show-ErrorBox -Title "错误" -Message $msg
    Write-LinkLog "EXCEPTION: $($_.Exception.ToString())"
    exit 1
}
