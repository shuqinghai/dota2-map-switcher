# Dota 2 地图更换器

这是一个仅用于更换 Dota 2 本机地形文件的 Windows 图形工具。

## 发布方式

项目同时生成安装版和免安装版。

安装版：

```text
dist\Dota2MapSwitcherSetup.exe
```

安装器默认使用当前用户的 `%LOCALAPPDATA%\Programs\Dota2MapSwitcher`，不需要管理员权限。点击“浏览…”时只需选择上一级位置，安装器会自动追加并创建 `Dota2MapSwitcher` 子文件夹；如果选中的本身已是 `Dota2MapSwitcher` 或现有安装目录，则不会重复追加。手动输入时仍视为完整安装路径。“创建桌面启动快捷方式”可由用户勾选；桌面不会创建卸载快捷方式。开始菜单保留启动和卸载入口，Windows“已安装的应用”也保留卸载项。

免安装版：

```text
dist\Dota2MapSwitcher-Portable.zip
dist\Dota2MapSwitcher-Portable\Dota2MapSwitcher.exe
```

分享时可直接发送 ZIP；解压后必须保留整个 `Dota2MapSwitcher-Portable` 文件夹。文件夹初始包含 `Dota2MapSwitcher.exe` 和 `使用说明.txt`；EXE 已内嵌主脚本、11 张地图图片、中文文案和应用图标，启动时不会显示命令提示行。

免安装版会校验父文件夹名称和内容。单独移动 EXE、改名文件夹或把额外文件放入该文件夹时，程序会拒绝运行且不会解压运行资源。如需从桌面启动，请为文件夹内的 EXE 创建桌面快捷方式。

工具不会复制或备份 VPK。运行资源临时解压到程序文件夹内的隐藏目录 `.runtime`；隐藏目录 `.data` 只保存当前替换记录和上一次选择。正常关闭会恢复地图、删除当前替换记录和运行资源，但会保留很小的 `preferences.json` 以记住上一次选择。该记录不会写到程序文件夹之外。

## 图片选择逻辑

1. 完全退出 Dota 2。
2. 启动工具；程序会自动读取 Steam 注册表、`libraryfolders.vdf` 和 `appmanifest_570.acf` 定位 Dota 2。
3. 如果没有自动找到，程序会弹出目录选择窗口；可以选择 `dota 2 beta`、`game`、`dota` 或 `maps` 文件夹。
4. 第一次点击地图图片，将它标记为“我已拥有”。
5. 再点击另一张地图图片，将它标记为“替换为”并立即执行更换。
6. 当前已有“替换为”时，点击另一张地图图片会先恢复上一组，再更换为新目标。
7. 再次点击当前“替换为”图片，会取消目标选择、恢复这一组文件并清除替换记录；“我已拥有”仍保留，方便继续选择。
8. 如需改选“我已拥有”，先取消当前“替换为”，再点击当前“我已拥有”取消它，然后重新选择。
9. 替换后保持工具打开，再启动 Dota 2；退出游戏后关闭工具，程序会自动恢复并删除记录。
10. 下次启动时会读取上一次的“我已拥有”和“替换为”；如果 Dota 2 未运行，会自动重新应用该组替换。主动取消“替换为”会清除记忆中的目标。

主窗口只显示标题、右上角帮助按钮、地图图片、中文名称以及两个选中标记。点击 `?` 可查看简要操作说明和注意事项。默认地形不会出现在地图卡片中。

## 自动恢复

- 每次更换前，程序都会先对上一组文件再次执行一次文件名交换，使其恢复原状。
- 随后通过一个短暂的临时文件名互换本次选择的两个 VPK；不会复制 VPK 内容。
- `.data\active-swap.json` 只在替换生效期间记录当前安装目录、两个文件名和对应地图名。
- `.data\preferences.json` 记录上一次选择的两张地图和 Dota 2 地图目录。
- 取消当前“替换为”图片，只对当前文件对再次交换，并删除记录。
- 正常关闭程序也会执行相同恢复并删除记录；如果 Dota 2 仍在运行，程序会阻止关闭。
- 如果重命名过程中出现错误，程序会根据已完成的阶段立即逆向改回。

如果程序崩溃或被意外中断，`.data` 记录会保留。退出 Dota 2 并重新启动工具后，程序会先自动恢复地图，再删除记录。恢复完成前不要删除程序文件夹。

安装版卸载时，可使用开始菜单中的“卸载”或 Windows“已安装的应用”。卸载器会先调用地图恢复流程；只有恢复成功才会删除安装目录、替换记录、快捷方式和卸载项。如果 Dota 2 仍在运行或恢复失败，卸载会停止并保留恢复信息。安装包 `Dota2MapSwitcherSetup.exe` 是用户自行保存的下载文件，卸载器不会删除它。

免安装版删除时，先退出 Dota 2，再正常关闭工具，最后删除整个 `Dota2MapSwitcher-Portable` 文件夹。不要通过任务管理器强制结束，也不要在替换生效时断电或直接删除文件夹。

请不要在软件外手动改名或移动相关 VPK。Steam 更新或“验证游戏文件完整性”也可能恢复地图文件。

Dota 2 地图目录通常为：

```text
<Steam库>\steamapps\common\dota 2 beta\game\dota\maps
```

## 自检

地图逻辑自检：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Dota2TerrainSwitcher.ps1 -SelfTest
```

GUI 加载测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Dota2TerrainSwitcher.ps1 -UiSmokeTest
```

自检只在系统临时目录创建微型测试 VPK，不会修改真实游戏文件。
