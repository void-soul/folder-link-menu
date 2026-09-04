# IdentifyFolder.ps1
# 「识别」：检测文件夹的链接状态
#   1. 自身是链接？→ 用 Reparse Tag 精确区分 Junction / Symlink，并显示指向目标、链接创建时间
#   2. 自身不是链接？→ 扫描各本地磁盘上的 Junction/Symlink，找出指向该目录的链接（含链接创建时间）
#   3. 附带显示脚本根目录 <文件夹名>.link.data 的历史记录
#
# 说明：Reparse Tag 通过 DeviceIoControl(FSCTL_GET_REPARSE_POINT) 读取，
#       0xA0000003 = Junction(Mount Point)，0xA000000C = Symbolic Link。无需管理员。

param(
    [Parameter(Mandatory=$true)]
    [string]$FolderA
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$logPath   = Join-Path $env:TEMP "IdentifyFolder_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-IdLog {
    param([string]$Message)
    try { "$(Get-Date -Format 'HH:mm:ss.fff')  $Message" | Add-Content -LiteralPath $logPath -Encoding UTF8 } catch { }
}

function Show-Box {
    param([string]$Text, [string]$Title, [System.Windows.Forms.MessageBoxIcon]$Icon)
    [System.Windows.Forms.MessageBox]::Show($Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK, $Icon) | Out-Null
}

# ---------- 原生 API：读取 reparse tag 与目标 ----------
Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class ReparseQuery
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(IntPtr h, uint code, IntPtr inBuf, uint inSize, byte[] outBuf, uint outSize, out uint returned, IntPtr overlapped);

    // 返回 "" 表示目标解析失败；tag 返回 0 表示失败
    public static string Query(string path, out uint tag)
    {
        tag = 0;
        // access 0（仅查询属性），share Read|Write|Delete,
        // OPEN_EXISTING=3, FILE_FLAG_BACKUP_SEMANTICS=0x02000000, FILE_FLAG_OPEN_REPARSE_POINT=0x00200000
        IntPtr h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero);
        if (h == (IntPtr)(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            byte[] buf = new byte[16 * 1024];
            uint returned;
            if (!DeviceIoControl(h, 0x900A8 /*FSCTL_GET_REPARSE_POINT*/, IntPtr.Zero, 0, buf, (uint)buf.Length, out returned, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            tag = BitConverter.ToUInt32(buf, 0);
            // REPARSE_DATA_BUFFER: Tag(4)@0, DataLength(2)@4, Reserved(2)@6
            // MountPointReparseBuffer:     SubNameOff@8  SubNameLen@10 PrintOff@12 PrintLen@14 PathBuffer@16
            // SymbolicLinkReparseBuffer:   Flags@8 SubNameOff@12 SubNameLen@14 PrintOff@16 PrintLen@18 PathBuffer@20
            // 名称偏移均相对各自 PathBuffer 基址
            ushort subOff, subLen, baseOff;
            if (tag == 0xA0000003)          // Mount Point (Junction)
            {
                subOff  = BitConverter.ToUInt16(buf, 8);
                subLen  = BitConverter.ToUInt16(buf, 10);
                baseOff = 16;
            }
            else if (tag == 0xA000000C)     // Symbolic Link
            {
                subOff  = BitConverter.ToUInt16(buf, 12);
                subLen  = BitConverter.ToUInt16(buf, 14);
                baseOff = 20;
            }
            else
            {
                return "";
            }
            if (subLen == 0) return "";
            return Encoding.Unicode.GetString(buf, baseOff + subOff, subLen);
        }
        finally { CloseHandle(h); }
    }
}
"@

function Get-LinkInfo {
    # 返回 @{ Type = 'Junction'|'Symlink'|'Other'; Target = '...'; Tag = uint }
    param([string]$Path)
    $tag = [uint32]0
    try {
        $raw = [ReparseQuery]::Query($Path, [ref]$tag)
    } catch {
        return $null
    }
    $target = ""
    if ($raw) {
        $target = $raw -replace '^\\\?\?\\', ''      # 去掉 \??\ 前缀
        $target = $target.TrimEnd('\', '/')
    }
    # 注意：PS 5.1 中 0xA0000003 被解析为负 Int32，任何十六进制写法都踩坑。
    # 直接用十进制字面量：0xA0000003 = 2684354563 (Junction)，0xA000000C = 2684354572 (Symlink)
    $tagJ = [uint32]2684354563
    $tagS = [uint32]2684354572
    $type = if ($tag -eq $tagJ) { "Junction" }
            elseif ($tag -eq $tagS) { "Symlink" }
            else { "Other(0x{0:X8})" -f $tag }
    return @{ Type = $type; Target = $target; Tag = $tag }
}

function Get-LinkHistory {
    # 读取脚本根目录 <name>.link.data，返回行数组
    param([string]$Name)
    $f = Join-Path $scriptDir "${Name}.link.data"
    if (Test-Path -LiteralPath $f -PathType Leaf) {
        return @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })
    }
    return @()
}

try {
    $FolderA = $FolderA.Trim().Trim('"').Trim("'")
    Write-IdLog "=== Start, FolderA = $FolderA ==="

    if ([string]::IsNullOrWhiteSpace($FolderA) -or -not (Test-Path -LiteralPath $FolderA -PathType Container)) {
        Show-Box -Text "路径不存在或不是文件夹：`n$FolderA" -Title "识别" -Icon Error
        exit 1
    }
    $FolderA = [System.IO.Path]::GetFullPath($FolderA).TrimEnd('\')
    $folderAName = Split-Path $FolderA -Leaf

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("==============================================")
    $out.Add(" 识别报告")
    $out.Add(" 目标：$FolderA")
    $out.Add("==============================================")
    $out.Add("")

    # ---------- 1. 自身是否是链接 ----------
    $selfInfo = Get-LinkInfo -Path $FolderA
    if ($selfInfo) {
        $item = Get-Item -LiteralPath $FolderA -Force
        $linkTime = $item.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
        $out.Add("[自身状态] 是链接")
        $out.Add("  类型     : $($selfInfo.Type)")
        if ($selfInfo.Target) {
            $out.Add("  指向     : $($selfInfo.Target)")
            $tgtExists = Test-Path -LiteralPath $selfInfo.Target -PathType Container
            $out.Add("  目标有效 : $(if ($tgtExists) { '是' } else { '否（目标不存在，链接已失效！）' })")
        } else {
            $out.Add("  指向     : （未能解析，链接可能已损坏）")
        }
        $out.Add("  创建时间 : $linkTime")
    } else {
        $out.Add("[自身状态] 普通目录（不是链接）")
    }
    $out.Add("")

    # ---------- 2. 反向查找（仅当自身不是链接时） ----------
    if (-not $selfInfo) {
        $out.Add("[反向查找] 指向此目录的链接：")
        $out.Add("  正在扫描本地磁盘的 Junction / Symlink（大磁盘可能需要一些时间）...")

        # 非模态进度提示窗
        $prog = New-Object System.Windows.Forms.Form
        $prog.Text            = "识别"
        $prog.Size            = New-Object System.Drawing.Size(380, 110)
        $prog.StartPosition   = "CenterScreen"
        $prog.FormBorderStyle = "FixedDialog"
        $prog.ControlBox      = $false
        $prog.TopMost         = $true
        $progLabel = New-Object System.Windows.Forms.Label
        $progLabel.Dock      = "Fill"
        $progLabel.TextAlign = "MiddleCenter"
        $progLabel.Font      = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
        $progLabel.Text      = "准备扫描..."
        $prog.Controls.Add($progLabel)
        $prog.Show()
        [System.Windows.Forms.Application]::DoEvents()

        $found = New-Object System.Collections.Generic.List[string]
        try {
            $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq [System.IO.DriveType]::Fixed }
            foreach ($d in $drives) {
                $progLabel.Text = "正在扫描 $($d.Name) ..."
                [System.Windows.Forms.Application]::DoEvents()
                Write-IdLog "Scanning $($d.Name)"
                # /a:l 仅列 reparse point；dir /s 会跟随 junction 可能重复输出，用对象去重
                $listed = cmd /c "dir `"$($d.Name)`" /a:l /s /b 2>nul" 2>$null
                if (-not $listed) { continue }
                $seen = @{}
                foreach ($p in $listed) {
                    $p = "$p".Trim()
                    if (-not $p -or $seen.ContainsKey($p.ToUpperInvariant())) { continue }
                    $seen[$p.ToUpperInvariant()] = $true
                    try {
                        $info = Get-LinkInfo -Path $p
                        if ($info -and $info.Target -and
                            ($info.Target -ieq $FolderA)) {
                            $ctime = (Get-Item -LiteralPath $p -Force).CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
                            $found.Add("  [$($info.Type)] $p  ->  $($info.Target)   (创建时间: $ctime)")
                            Write-IdLog "FOUND: $p -> $($info.Target)"
                        }
                    } catch { }
                }
            }
        } catch {
            Write-IdLog "Scan error: $($_.Exception.Message)"
        } finally {
            $prog.Close()
            $prog.Dispose()
        }

        if ($found.Count -gt 0) {
            $out.Add("  找到 $($found.Count) 个链接：")
            $out.Add("")
            foreach ($l in $found) { $out.Add($l) }
        } else {
            $out.Add("  （没有找到指向此目录的链接）")
        }
        $out.Add("")
    }

    # ---------- 3. 历史记录 ----------
    $out.Add("[链接历史] $($scriptDir)\<$folderAName>.link.data")
    $history = Get-LinkHistory -Name $folderAName
    if ($history.Count -eq 0) {
        $out.Add("  （无记录）")
    } else {
        foreach ($h in $history) { $out.Add("  $h") }
    }
    $out.Add("")
    $out.Add("==============================================")
    $out.Add(" 日志：$logPath")

    $report = $out -join "`n"
    Write-IdLog "---- REPORT ----"
    Write-IdLog $report
    Show-Box -Text $report -Title "识别结果" -Icon Information
    exit 0
}
catch {
    Write-IdLog "EXCEPTION: $($_.Exception.ToString())"
    Show-Box -Text "发生未处理异常：`n$($_.Exception.Message)`n`n日志：`n$logPath" -Title "错误" -Icon Error
    exit 1
}
