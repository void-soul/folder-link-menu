# Folder Link Menu

在 Windows 右键菜单中添加「链接到该目录」和「迁移并链接」功能。

## ✨ 功能

### 链接到该目录
- 在任意文件夹上右键，选择"链接到该目录"
- 选择目标容器目录后，在其下创建指向原目录的 **Junction** 链接（`mklink /J`）
- 目标位置存在同名项时弹出确认
- 链接创建成功后，在原目录（真实数据目录）生成/更新 `link.data`，记录何时哪个链接指向了它

### 迁移并链接
- 在任意文件夹上右键，选择"迁移并链接"
- 选择迁移目录后，把原文件夹**移动**到迁移目录下（如 `C:\afolder` → `D:\1234\afolder`）
- 迁移完成后，在原位置创建指向新位置的链接：优先 **Junction**（`mklink /J`，免管理员）；跨盘时 Junction 不支持，自动回退 **Symlink**（`mklink /D`，支持跨卷）
- 同卷迁移使用 `Move-Item`（瞬间完成）；跨卷迁移使用 `robocopy /MOVE`
- 任一步失败会自动回滚数据到原位置，不会丢失数据
- 迁移链接成功后，在新目录（真实数据目录）生成/更新 `link.data`，记录何时原位置的链接指向了它

### link.data 链接记录
两个功能完成后，都会在**真实数据目录**内生成或更新 `link.data` 文本文件，记录「何时、哪个链接指向该目录」：

- 格式：每行 `[日期时间]链接路径`，例如 `[2026-08-18 14:30]D:\ddd\1234`
- 同一链接路径再次链接时，会**更新**该行的日期时间；不同链接路径则**追加**新行
- 例如功能 A：`C:\1234` 被链接到 `D:\ddd\1234` 后，`C:\1234\link.data` 内容为 `[日期]D:\ddd\1234`
- 例如功能 B：`C:\1234` 迁移并链接到 `D:\ddd\1234` 后，`D:\ddd\1234\link.data` 内容为 `[日期]C:\1234`

## 📦 安装

右键点击 `Install-LinkFolderMenu.ps1`，选择**使用 PowerShell 运行**；或在 PowerShell 中执行：

```powershell
.\Install-LinkFolderMenu.ps1
```

安装成功后，右键任意文件夹即可看到「链接到该目录」和「迁移并链接」两个菜单项。

## 🗑️ 卸载

```powershell
.\Uninstall-LinkFolderMenu.ps1
```

## 🔧 原理

| 组件 | 说明 |
|------|------|
| `Install-LinkFolderMenu.ps1` | 在 `HKCU\SOFTWARE\Classes\Directory\shell` 下注册两个右键菜单 |
| `LinkFolder.ps1` | 「链接到该目录」：弹出目录选择对话框，调用 `mklink /J` 创建 Junction，并在真实数据目录写入 `link.data` |
| `MigrateLinkFolder.ps1` | 「迁移并链接」：自动提权 → 选择迁移目录 → 移动数据 → 在原位置 `mklink /D` 建符号链接，并在真实数据目录写入 `link.data` |
| `Uninstall-LinkFolderMenu.ps1` | 从注册表移除两个菜单项 |

## 📋 系统要求

- Windows 10 / 11
- PowerShell 5.1+
- NTFS 文件系统（Junction / 符号链接仅在 NTFS 上支持）

## ⚠️ 注意事项

- **链接到该目录**使用 Junction（`mklink /J`），**不支持跨卷**（不同磁盘分区）。
- **迁移并链接**优先使用 Junction（`mklink /J`，免管理员）；仅当**跨卷**迁移时 Junction 不支持，自动回退为符号链接（`mklink /D`，支持跨卷）。因为跨卷场景需要管理员权限创建符号链接，脚本会在启动时**自动弹 UAC 提权**（若已开启"开发者模式"则无感）。
- 迁移并链接的安全保护：
  - 拒绝迁移磁盘根目录、本身已是链接的目录
  - 拒绝把目录迁移进自己内部
  - 目标位置已有同名项时直接取消（避免覆盖真实数据）
  - 迁移或链接失败时自动回滚数据到原位置
- 删除链接不会影响真实数据；删除真实数据会导致链接失效。

## 🖥️ Windows 11 兼容性

- **Win11 新右键菜单**：Win11 默认使用新的 XAML 右键菜单，通过注册表 `Directory\shell` 注册的经典菜单项**默认不显示**在新菜单中。右键文件夹后，需点击菜单底部的**「显示更多选项」**（或按 `Shift+F10`）才能看到。
- **不再使用隐藏窗口**：旧版用 `-WindowStyle Hidden` 启动脚本，在 Win11 下隐藏窗口会导致目录选择/消息对话框显示异常甚至"一闪而过"。新版已改为正常窗口 + `-STA` 启动，确保 GUI 稳定弹出。
- **出错不再一闪而过**：脚本已加入全局异常捕获，任何错误都会弹出提示框并写入日志（`%TEMP%\LinkFolder_*.log` / `%TEMP%\MigrateLinkFolder_*.log`），便于排查。

## 📄 License

[MIT](LICENSE)
