# MarkFolder.ps1
# 「标记」：给文件夹写备注。数据存于脚本根目录 mark.data，格式：文件夹名<TAB>备注
# 弹框会按「文件夹名称（不含路径）」查找并加载已有备注，可编辑/新增/删除。
# 「搜索」按钮：用默认浏览器（Bing，失败回退百度）搜索文件夹名称。

param(
    [Parameter(Mandatory=$true)]
    [string]$FolderA
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$markDataFile = Join-Path $scriptDir "mark.data"
$logPath      = Join-Path $env:TEMP "MarkFolder_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-MarkLog {
    param([string]$Message)
    try { "$(Get-Date -Format 'HH:mm:ss.fff')  $Message" | Add-Content -LiteralPath $logPath -Encoding UTF8 } catch { }
}

# 读取 mark.data → hashtable{ 文件夹名: 备注 }
function Load-MarkData {
    param([string]$FilePath)
    $result = @{}
    if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $FilePath -Encoding UTF8 -ErrorAction SilentlyContinue)
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $idx = $line.IndexOf("`t")
            if ($idx -lt 0) {
                # 无 TAB：整行视为名称，备注为空
                $name = $line.Trim()
                if ($name) { $result[$name] = "" }
                continue
            }
            $name = $line.Substring(0, $idx).Trim()
            $val  = $line.Substring($idx + 1)
            if ($name) { $result[$name] = $val }
        }
    }
    return $result
}

# 写回 mark.data（按名称排序，保证稳定输出）
function Save-MarkData {
    param([string]$FilePath, [hashtable]$Data)
    $lines = @()
    foreach ($k in ($Data.Keys | Sort-Object)) {
        $v = $Data[$k] -replace "`r`n", "`n"
        $lines += "$k`t$v"
    }
    $lines | Set-Content -LiteralPath $FilePath -Encoding UTF8
}

try {
    $FolderA = $FolderA.Trim().Trim('"').Trim("'")
    $folderName = Split-Path $FolderA -Leaf
    if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = "(未知文件夹)" }
    Write-MarkLog "=== Start, FolderA = $FolderA, name = $folderName ==="

    $marks = Load-MarkData -FilePath $markDataFile
    $existingMark = if ($marks.ContainsKey($folderName)) { $marks[$folderName] } else { "" }

    # ---------- 弹框 ----------
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "标记"
    $form.Size            = New-Object System.Drawing.Size(580, 420)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Location = New-Object System.Drawing.Point(12, 12)
    $lblTitle.Size     = New-Object System.Drawing.Size(540, 40)
    $lblTitle.Font     = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Text     = "文件夹：$folderName`n路径：$FolderA"
    $form.Controls.Add($lblTitle)

    $lblEditor = New-Object System.Windows.Forms.Label
    $lblEditor.Location = New-Object System.Drawing.Point(12, 58)
    $lblEditor.Size     = New-Object System.Drawing.Size(200, 18)
    $lblEditor.Text     = "备注（保存到 mark.data）："
    $form.Controls.Add($lblEditor)

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Location    = New-Object System.Drawing.Point(12, 78)
    $rtb.Size        = New-Object System.Drawing.Size(450, 250)
    $rtb.Text        = $existingMark
    $rtb.ScrollBars  = "Vertical"
    $rtb.WordWrap    = $true
    $rtb.Font        = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $form.Controls.Add($rtb)

    # 搜索按钮（竖排右侧）
    $btnSearch = New-Object System.Windows.Forms.Button
    $btnSearch.Location = New-Object System.Drawing.Point(472, 78)
    $btnSearch.Size     = New-Object System.Drawing.Size(80, 40)
    $btnSearch.Text     = "搜索(&F)"
    $btnSearch.Font     = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $form.Controls.Add($btnSearch)

    $btnSearch.Add_Click({
        $q = [uri]::EscapeDataString($folderName)
        try {
            Start-Process "https://www.bing.com/search?q=$q"
        } catch {
            try { Start-Process "https://www.baidu.com/s?wd=$q" } catch { }
        }
    })

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Location = New-Object System.Drawing.Point(12, 344)
    $btnSave.Size     = New-Object System.Drawing.Size(120, 36)
    $btnSave.Text     = "保存(&S)"
    $btnSave.Font     = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnSave.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnSave)
    $form.AcceptButton = $btnSave

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Location = New-Object System.Drawing.Point(142, 344)
    $btnCancel.Size     = New-Object System.Drawing.Size(120, 36)
    $btnCancel.Text     = "取消(&C)"
    $btnCancel.Font     = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Location = New-Object System.Drawing.Point(272, 344)
    $btnDelete.Size     = New-Object System.Drawing.Size(110, 36)
    $btnDelete.Text     = "删除标记(&D)"
    $btnDelete.Font     = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $form.Controls.Add($btnDelete)

    $btnDelete.Add_Click({
        $r = [System.Windows.Forms.MessageBox]::Show(
            "确定删除「$folderName」的标记吗？", "确认删除",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            if ($marks.ContainsKey($folderName)) { $marks.Remove($folderName) | Out-Null }
            Save-MarkData -FilePath $markDataFile -Data $marks
            $rtb.Text = ""
            Write-MarkLog "Mark deleted: $folderName"
        }
    })

    $lblTip = New-Object System.Windows.Forms.Label
    $lblTip.Location  = New-Object System.Drawing.Point(396, 350)
    $lblTip.Size      = New-Object System.Drawing.Size(156, 24)
    $lblTip.Text      = "存储位置：mark.data"
    $lblTip.Font      = New-Object System.Drawing.Font("Microsoft YaHei UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblTip.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($lblTip)

    $result = $form.ShowDialog()
    Write-MarkLog "Dialog result = $result"

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $newMark = $rtb.Text.Trim()
        if ($newMark -eq "") {
            if ($marks.ContainsKey($folderName)) { $marks.Remove($folderName) | Out-Null }
        } else {
            $marks[$folderName] = $newMark
        }
        Save-MarkData -FilePath $markDataFile -Data $marks
        Write-MarkLog "Mark saved: $folderName"
        [System.Windows.Forms.MessageBox]::Show(
            "标记已保存。`n`n文件夹：$folderName`n存储位置：$markDataFile",
            "成功",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
}
catch {
    Write-MarkLog "EXCEPTION: $($_.Exception.ToString())"
    [System.Windows.Forms.MessageBox]::Show(
        "发生未处理异常：`n$($_.Exception.Message)`n`n日志：`n$logPath",
        "错误",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}
