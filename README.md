# Folder Link Menu — README

在 Windows 右键菜单中添加 4 个一级菜单项：**链接到该目录 / 迁移并链接 / 标记 / 识别**。

> **从旧版升级**：直接运行一次 `Install-LinkFolderMenu.ps1`，会自动清理旧菜单（含之前的
> Magic Menu 级联菜单版）并注册新结构。

## ✨ 功能概览

右键任意文件夹（Win11 需点「显示更多选项」或 Shift+F10）即可看到 4 个菜单项：

| 菜单项 | 功能 |
|--------|------|
| 链接到该目录 | 在目标目录下创建指向原目录的链接（Junction 或 Symlink） |
| 迁移并链接 | 移动数据到新位置，在原位置创建链接（自动提权、失败回滚） |
| 标记 | 给文件夹添加备注，备注存储在脚本根目录的 `mark.data` 中 |
| 识别 | 检测文件夹是否是链接（Junction/Symlink），以及哪些链接指向它 |

---

### 链接到该目录

1. 右键文件夹 → Magic Menu → 链接到该目录
2. 选择链接类型：**Junction**（同卷，免管理员）或 **Symlink**（支持跨盘）
3. 选择目标容器目录 B
4. 在 B 下创建指向原目录的链接
5. 目标位置存在同名项时弹出确认
6. 链接记录写入脚本根目录的 `<原文件夹名>.link.data`

### 迁移并链接

1. 右键文件夹 → Magic Menu → 迁移并链接
2. 非管理员时自动弹 UAC 提权
3. 选择迁移目标目录 B
4. 选择链接类型：**Junction** 或 **Symlink**
5. 执行迁移（同卷用 `Move-Item`，跨卷用 `robocopy /MOVE`）
6. 在原位置创建对应类型的链接
7. 任一步失败自动回滚数据
8. 链接记录写入脚本根目录的 `<原文件夹名>.link.data`

**安全防护：**
- 拒绝迁移磁盘根目录、本身已是链接的目录
- 拒绝把目录迁移进自己内部
- 目标位置已有同名项时直接取消
- 迁移或链接失败时自动回滚数据到原位置

### 标记

1. 右键文件夹 → Magic Menu → 标记
2. 弹框显示该文件夹名称和路径
3. 自动从 `mark.data` 中加载已有备注（如有）
4. 可编辑、新增、删除备注
5. 点击「搜索」按钮用默认浏览器查询文件夹名称
6. 备注文件存放在脚本根目录的 `mark.data`（格式：`文件夹名<TAB>备注内容`）

### 识别

1. 右键文件夹 → Magic Menu → 识别
2. 报告内容包括：
   - **自身状态**：是否是 Junction/Symlink，指向哪里（含创建时间）
   - **反向查找**：如果不是链接，扫描所有驱动器找出哪些链接指向它（含时间）
   - **链接历史**：读取脚本根目录下 `<原文件夹名>.link.data` 的历史记录

---

## 📦 安装

右键点击 `Install-LinkFolderMenu.ps1`，选择**使用 PowerShell 运行**；或在 PowerShell 中执行：

```powershell
.\Install-LinkFolderMenu.ps1
```

安装成功后，右键任意文件夹即可看到「Magic Menu」。

> 脚本文件必须保持 **UTF-8 with BOM** 编码保存（已内置）。
> Windows PowerShell 5.1 读取无 BOM 的 UTF-8 脚本时会按 ANSI/GBK 解码，中文会乱码甚至解析失败。

## 🗑️ 卸载

```powershell
.\Uninstall-LinkFolderMenu.ps1
```

## 📁 数据存储

| 文件 | 位置 | 说明 |
|------|------|------|
| `mark.data` | 脚本根目录 | 文件夹标记/备注缓存（K-V 格式） |
| `<文件夹名>.link.data` | 脚本根目录 | 链接历史记录（何时、哪个链接指向该目录） |
| `MigrateLinkFolder_*.log` | `%LOCALAPPDATA%\FolderLinkMenu\logs` | 迁移操作日志 |
| `LinkFolder_*.log` | `%TEMP%` | 链接创建操作日志 |
| `IdentifyFolder_*.log` | `%TEMP%` | 识别操作日志 |

## 🖥️ Windows 11 兼容性

- Win11 新右键菜单：需点击「显示更多选项」才能看到 Magic Menu
- 已修复隐藏窗口导致的对话框异常问题
- 出错时弹出提示框并写入日志，不再一闪而过

## 📋 系统要求

- Windows 10 / 11
- PowerShell 5.1+
- NTFS 文件系统

## 📄 License

[MIT](LICENSE)
