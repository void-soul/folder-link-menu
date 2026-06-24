# LinkFolder.ps1
# 用法：被右键菜单调用，参数为右键选中的文件夹路径（即 A）
# 功能：弹出对话框让用户选择容器目录 B，然后在 B 下建立指向 A 的 Junction 链接，链接名称与 A 相同

param(
    [Parameter(Mandatory=$true)]
    [string]$FolderA
)

Add-Type -AssemblyName System.Windows.Forms

# 1. 验证 A 的路径
if (-not (Test-Path -LiteralPath $FolderA -PathType Container)) {
    [System.Windows.Forms.MessageBox]::Show(
        "路径不存在或不是文件夹：`n$FolderA",
        "错误",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

$folderAName = Split-Path $FolderA -Leaf

# 2. 弹出目录选择对话框，让用户选择容器目录 B
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = "请选择目标容器目录 B`n将在 B 下建立名为「$folderAName」的链接，指向：`n$FolderA"
$dialog.ShowNewFolderButton = $true
$dialog.RootFolder = [System.Environment+SpecialFolder]::MyComputer

$result = $dialog.ShowDialog()

if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    exit 0
}

$FolderB = $dialog.SelectedPath

# 3. 验证 B 的路径
if (-not (Test-Path -LiteralPath $FolderB -PathType Container)) {
    [System.Windows.Forms.MessageBox]::Show(
        "选择的目录无效：`n$FolderB",
        "错误",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

# 4. 确定链接完整路径：B\\A名称
$linkFullPath = Join-Path $FolderB $folderAName

# 如果 B 下已存在同名项，询问是否覆盖
if (Test-Path -LiteralPath $linkFullPath) {
    $overwrite = [System.Windows.Forms.MessageBox]::Show(
        "目标位置已存在同名项，是否覆盖？`n`n$linkFullPath",
        "确认覆盖",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($overwrite -ne [System.Windows.Forms.DialogResult]::Yes) {
        exit 0
    }
    cmd /c "rd `"$linkFullPath`"" 2>$null
    Remove-Item -LiteralPath $linkFullPath -Force -ErrorAction SilentlyContinue
}

# 5. 建立 Junction 链接：mklink /J B\\A名 A路径
$cmdArgs = "/c mklink /J `"$linkFullPath`" `"$FolderA`""
$proc    = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs `
                         -Wait -PassThru -WindowStyle Hidden

if ($proc.ExitCode -eq 0) {
    [System.Windows.Forms.MessageBox]::Show(
        "链接创建成功！`n`n链接位置：`n$linkFullPath`n`n指向：`n$FolderA",
        "成功",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
} else {
    [System.Windows.Forms.MessageBox]::Show(
        "创建链接失败！`n`n可能原因：`n- B 下已有同名真实目录（非链接）`n- 权限不足`n- 路径含特殊字符",
        "失败",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}
