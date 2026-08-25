using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class Dota2MapSwitcherInstaller
{
    private const string ProductName = "Dota 2 地图替换器";
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Dota2MapSwitcher";
    private const string MarkerFileName = ".dota2-map-switcher-install";
    private const string MarkerContent = "Dota2MapSwitcher.Install.v1";

    private static bool HasArgument(string[] args, string expected)
    {
        foreach (string arg in args)
        {
            if (String.Equals(arg, expected, StringComparison.OrdinalIgnoreCase)) { return true; }
        }
        return false;
    }

    private static string GetInstallDirectoryArgument(string[] args)
    {
        const string prefix = "--install-dir=";
        foreach (string arg in args)
        {
            if (arg.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) { return arg.Substring(prefix.Length); }
        }
        return null;
    }

    private static string GetTestRoot()
    {
        string value = Environment.GetEnvironmentVariable("DOTA2_MAP_SWITCHER_TEST_ROOT");
        if (String.IsNullOrWhiteSpace(value)) { return null; }
        string fullPath = Path.GetFullPath(value).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (!Path.GetFileName(fullPath).StartsWith(".installer-test-", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("测试目录名称无效。");
        }
        return fullPath;
    }

    private static string GetRegisteredInstallDirectory()
    {
        if (GetTestRoot() != null) { return null; }
        try
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(UninstallKey))
            {
                if (key == null) { return null; }
                string value = key.GetValue("InstallLocation") as string;
                return String.IsNullOrWhiteSpace(value) ? null : Path.GetFullPath(value);
            }
        }
        catch { return null; }
    }

    private static string GetDefaultInstallDirectory()
    {
        string registered = GetRegisteredInstallDirectory();
        if (!String.IsNullOrWhiteSpace(registered)) { return registered; }
        string testRoot = GetTestRoot();
        if (testRoot != null) { return Path.Combine(testRoot, "LocalAppData", "Programs", "Dota2MapSwitcher"); }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Dota2MapSwitcher");
    }

    private static string GetDesktopDirectory()
    {
        string testRoot = GetTestRoot();
        return testRoot == null ? Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) : Path.Combine(testRoot, "Desktop");
    }

    private static string GetStartMenuDirectory()
    {
        string testRoot = GetTestRoot();
        return testRoot == null
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), ProductName)
            : Path.Combine(testRoot, "StartMenu", ProductName);
    }

    private static string GetTemporaryDirectory()
    {
        string testRoot = GetTestRoot();
        string parent = testRoot == null ? Path.GetTempPath() : Path.Combine(testRoot, "Temp");
        Directory.CreateDirectory(parent);
        return Path.Combine(parent, "Dota2MapSwitcherInstall_" + Guid.NewGuid().ToString("N"));
    }

    private static bool HasValidInstallMarker(string installDirectory)
    {
        try
        {
            string markerPath = Path.Combine(installDirectory, MarkerFileName);
            return File.Exists(markerPath) && String.Equals(File.ReadAllText(markerPath).Trim(), MarkerContent, StringComparison.Ordinal);
        }
        catch { return false; }
    }

    private static string GetInstallPathFromSelectedFolder(string selectedFolder)
    {
        string fullPath = Path.GetFullPath(selectedFolder).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (String.Equals(Path.GetFileName(fullPath), "Dota2MapSwitcher", StringComparison.OrdinalIgnoreCase) ||
            HasValidInstallMarker(fullPath))
        {
            return fullPath;
        }
        return Path.Combine(fullPath, "Dota2MapSwitcher");
    }

    private static string ValidateInstallDirectory(string requestedDirectory)
    {
        if (String.IsNullOrWhiteSpace(requestedDirectory)) { throw new InvalidOperationException("请选择安装路径。"); }
        string fullPath = Path.GetFullPath(requestedDirectory.Trim().Trim('"')).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (String.IsNullOrWhiteSpace(fullPath) || Directory.GetParent(fullPath) == null)
        {
            throw new InvalidOperationException("不能直接安装到磁盘根目录。");
        }

        string registered = GetRegisteredInstallDirectory();
        if (!String.IsNullOrWhiteSpace(registered) && Directory.Exists(registered) &&
            !String.Equals(Path.GetFullPath(registered).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), fullPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("已安装在：\r\n" + registered + "\r\n\r\n如需更换路径，请先卸载旧版。");
        }
        if (Directory.Exists(fullPath) && Directory.GetFileSystemEntries(fullPath).Length > 0 && !HasValidInstallMarker(fullPath))
        {
            throw new InvalidOperationException("安装目录必须是空文件夹，或者是本工具已有的安装目录。");
        }
        return fullPath;
    }

    private static void ExtractResource(string resourceName, string destinationPath)
    {
        using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
        {
            if (source == null) { throw new InvalidOperationException("安装包缺少资源：" + resourceName); }
            using (FileStream destination = new FileStream(destinationPath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                source.CopyTo(destination);
            }
        }
    }

    private static bool IsInstalledAppRunning(string appPath)
    {
        foreach (Process process in Process.GetProcessesByName("Dota2MapSwitcher"))
        {
            try
            {
                if (String.Equals(Path.GetFullPath(process.MainModule.FileName), Path.GetFullPath(appPath), StringComparison.OrdinalIgnoreCase)) { return true; }
            }
            catch { }
            finally { process.Dispose(); }
        }
        return false;
    }

    private static void RestoreExistingSwap(string installDirectory)
    {
        string appPath = Path.Combine(installDirectory, "Dota2MapSwitcher.exe");
        string uninstallerPath = Path.Combine(installDirectory, "Uninstall.exe");
        string statePath = Path.Combine(installDirectory, ".data", "active-swap.json");
        if (IsInstalledAppRunning(appPath)) { throw new InvalidOperationException("请先正常关闭已运行的地图替换器，再继续安装。"); }
        if (!File.Exists(appPath))
        {
            if (File.Exists(statePath)) { throw new InvalidOperationException("检测到地图替换记录，但旧程序文件已丢失。已停止安装。"); }
            return;
        }
        if (!File.Exists(uninstallerPath) || !HasValidInstallMarker(installDirectory))
        {
            if (File.Exists(statePath)) { throw new InvalidOperationException("旧安装不完整，且仍有地图替换记录。已停止安装。"); }
            return;
        }
        ProcessStartInfo startInfo = new ProcessStartInfo(appPath, "-RestoreAndExit");
        startInfo.WorkingDirectory = installDirectory;
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        using (Process process = Process.Start(startInfo))
        {
            process.WaitForExit();
            if (process.ExitCode != 0) { throw new InvalidOperationException("旧版程序未能在更新前恢复地图。"); }
        }
        if (File.Exists(statePath)) { throw new InvalidOperationException("地图替换记录仍然存在，已停止安装。"); }
    }

    private static void ReplaceFile(string source, string destination)
    {
        if (File.Exists(destination)) { File.Delete(destination); }
        File.Move(source, destination);
    }

    private static void WriteInstallMarker(string installDirectory)
    {
        string markerPath = Path.Combine(installDirectory, MarkerFileName);
        if (File.Exists(markerPath)) { File.SetAttributes(markerPath, FileAttributes.Normal); }
        File.WriteAllText(markerPath, MarkerContent, new UTF8Encoding(false));
        try { File.SetAttributes(markerPath, File.GetAttributes(markerPath) | FileAttributes.Hidden); } catch { }
    }

    private static void CreateShortcut(string shortcutPath, string targetPath, string workingDirectory, string description)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(shortcutPath));
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType == null) { throw new InvalidOperationException("无法创建 Windows 快捷方式。"); }
        object shell = Activator.CreateInstance(shellType);
        object shortcut = null;
        try
        {
            shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { shortcutPath });
            Type shortcutType = shortcut.GetType();
            shortcutType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { targetPath });
            shortcutType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { workingDirectory });
            shortcutType.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { description });
            shortcutType.InvokeMember("IconLocation", BindingFlags.SetProperty, null, shortcut, new object[] { targetPath + ",0" });
            shortcutType.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
        }
        finally
        {
            if (shortcut != null && Marshal.IsComObject(shortcut)) { Marshal.FinalReleaseComObject(shortcut); }
            if (Marshal.IsComObject(shell)) { Marshal.FinalReleaseComObject(shell); }
        }
    }

    private static void DeleteDesktopShortcuts()
    {
        string desktop = GetDesktopDirectory();
        string appShortcut = Path.Combine(desktop, ProductName + ".lnk");
        string uninstallShortcut = Path.Combine(desktop, "卸载 " + ProductName + ".lnk");
        if (File.Exists(appShortcut)) { File.Delete(appShortcut); }
        if (File.Exists(uninstallShortcut)) { File.Delete(uninstallShortcut); }
    }

    private static void RegisterUninstaller(string installDirectory, string appPath, string uninstallerPath)
    {
        if (GetTestRoot() != null) { return; }
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            if (key == null) { throw new InvalidOperationException("无法创建卸载信息。"); }
            key.SetValue("DisplayName", ProductName);
            key.SetValue("DisplayVersion", FileVersionInfo.GetVersionInfo(Assembly.GetExecutingAssembly().Location).ProductVersion);
            key.SetValue("Publisher", "Dota 2 Map Switcher");
            key.SetValue("DisplayIcon", appPath + ",0");
            key.SetValue("InstallLocation", installDirectory);
            key.SetValue("UninstallString", "\"" + uninstallerPath + "\"");
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            key.SetValue("EstimatedSize", 9000, RegistryValueKind.DWord);
        }
    }

    private static void Install(string requestedDirectory, bool createDesktopShortcuts)
    {
        string installDirectory = ValidateInstallDirectory(requestedDirectory);
        string appPath = Path.Combine(installDirectory, "Dota2MapSwitcher.exe");
        string uninstallerPath = Path.Combine(installDirectory, "Uninstall.exe");
        RestoreExistingSwap(installDirectory);
        string stagingDirectory = GetTemporaryDirectory();
        Directory.CreateDirectory(stagingDirectory);
        try
        {
            string stagedApp = Path.Combine(stagingDirectory, "Dota2MapSwitcher.exe");
            string stagedUninstaller = Path.Combine(stagingDirectory, "Uninstall.exe");
            ExtractResource("Dota2MapSwitcher.exe", stagedApp);
            ExtractResource("Uninstall.exe", stagedUninstaller);
            Directory.CreateDirectory(installDirectory);
            ReplaceFile(stagedApp, appPath);
            ReplaceFile(stagedUninstaller, uninstallerPath);
            WriteInstallMarker(installDirectory);
        }
        finally
        {
            if (Directory.Exists(stagingDirectory)) { Directory.Delete(stagingDirectory, true); }
        }

        string startMenu = GetStartMenuDirectory();
        CreateShortcut(Path.Combine(startMenu, ProductName + ".lnk"), appPath, installDirectory, ProductName);
        CreateShortcut(Path.Combine(startMenu, "卸载.lnk"), uninstallerPath, installDirectory, "卸载 " + ProductName);
        if (createDesktopShortcuts)
        {
            string desktop = GetDesktopDirectory();
            CreateShortcut(Path.Combine(desktop, ProductName + ".lnk"), appPath, installDirectory, ProductName);
            string legacyDesktopUninstall = Path.Combine(desktop, "卸载 " + ProductName + ".lnk");
            if (File.Exists(legacyDesktopUninstall)) { File.Delete(legacyDesktopUninstall); }
        }
        else { DeleteDesktopShortcuts(); }
        RegisterUninstaller(installDirectory, appPath, uninstallerPath);
    }

    private sealed class InstallerForm : Form
    {
        private readonly TextBox pathBox;
        private readonly Button browseButton;
        private readonly CheckBox desktopCheckBox;
        private readonly Button installButton;
        private readonly Button cancelButton;
        public int ResultCode { get; private set; }

        public InstallerForm(string initialDirectory, bool initialDesktopShortcuts)
        {
            ResultCode = 2;
            Text = ProductName + " 安装程序";
            ClientSize = new Size(620, 240);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 9F);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            Label title = new Label();
            title.Text = "安装 " + ProductName;
            title.Font = new Font(Font.FontFamily, 14F, FontStyle.Bold);
            title.AutoSize = true;
            title.Location = new Point(24, 20);
            Controls.Add(title);

            Label description = new Label();
            description.Text = "选择上一级位置时，会自动创建 Dota2MapSwitcher 子文件夹。";
            description.AutoSize = true;
            description.Location = new Point(26, 57);
            Controls.Add(description);

            Label pathLabel = new Label();
            pathLabel.Text = "安装路径：";
            pathLabel.AutoSize = true;
            pathLabel.Location = new Point(26, 91);
            Controls.Add(pathLabel);

            pathBox = new TextBox();
            pathBox.Text = initialDirectory;
            pathBox.Location = new Point(27, 113);
            pathBox.Size = new Size(470, 24);
            Controls.Add(pathBox);

            browseButton = new Button();
            browseButton.Text = "浏览…";
            browseButton.Location = new Point(508, 111);
            browseButton.Size = new Size(84, 28);
            browseButton.Click += BrowseButtonClick;
            Controls.Add(browseButton);

            desktopCheckBox = new CheckBox();
            desktopCheckBox.Text = "创建桌面启动快捷方式";
            desktopCheckBox.Checked = initialDesktopShortcuts;
            desktopCheckBox.AutoSize = true;
            desktopCheckBox.Location = new Point(29, 153);
            Controls.Add(desktopCheckBox);

            installButton = new Button();
            installButton.Text = "安装";
            installButton.Location = new Point(414, 194);
            installButton.Size = new Size(84, 30);
            installButton.Click += InstallButtonClick;
            Controls.Add(installButton);

            cancelButton = new Button();
            cancelButton.Text = "取消";
            cancelButton.Location = new Point(508, 194);
            cancelButton.Size = new Size(84, 30);
            cancelButton.Click += delegate { Close(); };
            Controls.Add(cancelButton);
            AcceptButton = installButton;
            CancelButton = cancelButton;
        }

        private void BrowseButtonClick(object sender, EventArgs eventArgs)
        {
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.Description = "选择安装位置，程序会自动创建 Dota2MapSwitcher 子文件夹";
                dialog.ShowNewFolderButton = true;
                if (Directory.Exists(pathBox.Text))
                {
                    string current = Path.GetFullPath(pathBox.Text).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                    dialog.SelectedPath = String.Equals(Path.GetFileName(current), "Dota2MapSwitcher", StringComparison.OrdinalIgnoreCase)
                        ? Path.GetDirectoryName(current)
                        : current;
                }
                else
                {
                    string parent = Path.GetDirectoryName(Path.GetFullPath(pathBox.Text));
                    if (Directory.Exists(parent)) { dialog.SelectedPath = parent; }
                }
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    pathBox.Text = GetInstallPathFromSelectedFolder(dialog.SelectedPath);
                }
            }
        }

        private void InstallButtonClick(object sender, EventArgs eventArgs)
        {
            try
            {
                UseWaitCursor = true;
                pathBox.Enabled = browseButton.Enabled = desktopCheckBox.Enabled = installButton.Enabled = cancelButton.Enabled = false;
                Install(pathBox.Text, desktopCheckBox.Checked);
                ResultCode = 0;
                RtsMessageBox.Show(this, "安装完成。", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
                Close();
            }
            catch (Exception error)
            {
                RtsMessageBox.Show(this, "安装失败：" + error.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
                pathBox.Enabled = browseButton.Enabled = desktopCheckBox.Enabled = installButton.Enabled = cancelButton.Enabled = true;
            }
            finally { UseWaitCursor = false; }
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool silent = HasArgument(args, "--silent");
        try
        {
            string requested = GetInstallDirectoryArgument(args);
            if (String.IsNullOrWhiteSpace(requested)) { requested = GetDefaultInstallDirectory(); }
            bool createDesktopShortcuts = !HasArgument(args, "--no-desktop-shortcuts");
            if (silent)
            {
                Install(requested, createDesktopShortcuts);
                return 0;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            InstallerForm form = new InstallerForm(requested, createDesktopShortcuts);
            Application.Run(form);
            return form.ResultCode;
        }
        catch (Exception error)
        {
            if (!silent) { RtsMessageBox.Show("安装失败：" + error.Message, ProductName + " 安装程序", MessageBoxButtons.OK, MessageBoxIcon.Error); }
            return 1;
        }
    }
}
