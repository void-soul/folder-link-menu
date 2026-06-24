# Folder Link Menu

在 Windows 右键菜单中添加「链接到该目录」功能，一键创建文件夹的 Junction 符号链接。

## ✨ 功能

- **右键快捷操作**：在任意文件夹上右键，选择"链接到该目录"
- **图形化选择**：弹出文件夹选择对话框，选择目标容器目录
- **Junction 链接**：使用 `mklink /J` 创建目录联结，对应用程序透明
- **覆盖确认**：目标位置存在同名项时，弹出确认对话框
- **无需管理员**：注册到 HKCU，普通用户权限即可安装使用

## 📦 安装

右键点击 `Install-LinkFolderMenu.ps1`，选择**使用 PowerShell 运行**；或在 PowerShell 中执行：

```powershell
.\Install-LinkFolderMenu.ps1
```

安装成功后，右键任意文件夹即可看到「链接到该目录」菜单项。

## 🗑️ 卸载

```powershell
.\Uninstall-LinkFolderMenu.ps1
```

## 🔧 原理

| 组件 | 说明 |
|------|------|
| `Install-LinkFolderMenu.ps1` | 在 `HKCU\SOFTWARE\Classes\Directory\shell` 下注册右键菜单 |
| `LinkFolder.ps1` | 右键触发后执行，弹出目录选择对话框，调用 `mklink /J` 创建 Junction |
| `Uninstall-LinkFolderMenu.ps1` | 从注册表移除菜单项 |

## 📋 系统要求

- Windows 10 / 11
- PowerShell 5.1+
- NTFS 文件系统（Junction 仅在 NTFS 上支持）

## ⚠️ 注意事项

- Junction 链接在资源管理器中显示为文件夹图标（带快捷方式箭头），但实际是目录联结
- 删除链接不会影响原始文件夹；删除原始文件夹会导致链接失效
- 不支持跨卷（不同磁盘分区）创建 Junction，如需跨卷请使用符号链接（Symlink）

## 📄 License

[MIT](LICENSE)
