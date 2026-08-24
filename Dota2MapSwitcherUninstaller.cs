using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class Dota2MapSwitcherUninstaller
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
        string directory = testRoot == null ? Path.GetTempPath() : Path.Combine(testRoot, "Temp");
        Directory.CreateDirectory(directory);
        return directory;
    }

    private static string GetCurrentInstallDirectory()
    {
        return Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
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

    private static string EncodePath(string path)
    {
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(Path.GetFullPath(path)));
    }

    private static string DecodePath(string encoded)
    {
        return Path.GetFullPath(Encoding.UTF8.GetString(Convert.FromBase64String(encoded))).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
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

    private static void RestoreMapBeforeUninstall(string installDirectory)
    {
        if (!HasValidInstallMarker(installDirectory)) { throw new InvalidOperationException("安装标记缺失或无效，已停止卸载。"); }
        string appPath = Path.Combine(installDirectory, "Dota2MapSwitcher.exe");
        string statePath = Path.Combine(installDirectory, ".data", "active-swap.json");
        if (IsInstalledAppRunning(appPath)) { throw new InvalidOperationException("请先正常关闭地图替换器，再运行卸载。"); }
        if (!File.Exists(appPath))
        {
            if (File.Exists(statePath)) { throw new InvalidOperationException("地图替换记录仍然存在，但主程序已丢失。已停止卸载。"); }
            return;
        }
        ProcessStartInfo startInfo = new ProcessStartInfo(appPath, "-RestoreAndExit");
        startInfo.WorkingDirectory = installDirectory;
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        using (Process process = Process.Start(startInfo))
        {
            process.WaitForExit();
            if (process.ExitCode != 0) { throw new InvalidOperationException("地图未能恢复，本次没有删除安装信息。"); }
        }
        if (File.Exists(statePath)) { throw new InvalidOperationException("地图替换记录未清除，已停止卸载。"); }
    }

    private static void DeleteDirectoryWithRetry(string directory)
    {
        Exception lastError = null;
        for (int attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                if (Directory.Exists(directory)) { Directory.Delete(directory, true); }
                return;
            }
            catch (Exception error)
            {
                lastError = error;
                Thread.Sleep(300);
            }
        }
        throw new InvalidOperationException("无法删除程序数据：" + lastError.Message, lastError);
    }

    private static void DeleteFileWithRetry(string path)
    {
        Exception lastError = null;
        for (int attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                if (File.Exists(path)) { File.SetAttributes(path, FileAttributes.Normal); File.Delete(path); }
                return;
            }
            catch (Exception error)
            {
                lastError = error;
                Thread.Sleep(300);
            }
        }
        throw new InvalidOperationException("无法删除程序文件：" + lastError.Message, lastError);
    }

    private static void DeleteShortcut(string path)
    {
        if (File.Exists(path)) { File.Delete(path); }
    }

    private static void RemoveRegistryEntry(string installDirectory)
    {
        if (GetTestRoot() != null) { return; }
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(UninstallKey))
        {
            if (key == null) { return; }
            string registered = key.GetValue("InstallLocation") as string;
            if (!String.IsNullOrWhiteSpace(registered) &&
                !String.Equals(Path.GetFullPath(registered).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), installDirectory, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("卸载项指向了另一个安装目录，已停止删除该卸载项。");
            }
        }
        Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false);
    }

    private static bool RemoveInstalledFiles(string installDirectory)
    {
        installDirectory = Path.GetFullPath(installDirectory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (Directory.GetParent(installDirectory) == null || !HasValidInstallMarker(installDirectory))
        {
            throw new InvalidOperationException("卸载目录校验失败。");
        }

        DeleteDirectoryWithRetry(Path.Combine(installDirectory, ".runtime"));
        DeleteDirectoryWithRetry(Path.Combine(installDirectory, ".data"));
        DeleteFileWithRetry(Path.Combine(installDirectory, "Dota2MapSwitcher.exe"));
        DeleteFileWithRetry(Path.Combine(installDirectory, "Uninstall.exe"));
        DeleteFileWithRetry(Path.Combine(installDirectory, MarkerFileName));

        string desktop = GetDesktopDirectory();
        DeleteShortcut(Path.Combine(desktop, ProductName + ".lnk"));
        DeleteShortcut(Path.Combine(desktop, "卸载 " + ProductName + ".lnk"));
        string startMenu = GetStartMenuDirectory();
        if (Directory.Exists(startMenu)) { Directory.Delete(startMenu, true); }
        RemoveRegistryEntry(installDirectory);

        if (Directory.Exists(installDirectory) && Directory.GetFileSystemEntries(installDirectory).Length == 0)
        {
            Directory.Delete(installDirectory, false);
        }
        return Directory.Exists(installDirectory);
    }

    private static void ScheduleSelfDelete()
    {
        string executable = Path.GetFullPath(Process.GetCurrentProcess().MainModule.FileName);
        string temporaryRoot = Path.GetFullPath(GetTemporaryDirectory()).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (!String.Equals(Path.GetDirectoryName(executable).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), temporaryRoot, StringComparison.OrdinalIgnoreCase)) { return; }
        ProcessStartInfo startInfo = new ProcessStartInfo("cmd.exe");
        startInfo.Arguments = "/d /c ping 127.0.0.1 -n 2 > nul & del /f /q \"" + executable + "\"";
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.WindowStyle = ProcessWindowStyle.Hidden;
        Process.Start(startInfo);
    }

    private static int CleanupMode(string[] args, bool silent)
    {
        try
        {
            int parentId;
            if (args.Length < 3 || !Int32.TryParse(args[1], out parentId)) { throw new InvalidOperationException("卸载参数无效。"); }
            string installDirectory = DecodePath(args[2]);
            try { using (Process parent = Process.GetProcessById(parentId)) { parent.WaitForExit(10000); } } catch { }
            bool directoryRemains = RemoveInstalledFiles(installDirectory);
            if (!silent)
            {
                string message = directoryRemains
                    ? "卸载完成。程序文件和记录已删除；安装文件夹中有用户自行放入的文件，因此保留了该文件夹。"
                    : "卸载完成，程序、记录、快捷方式和卸载项已删除。";
                RtsMessageBox.Show(message, ProductName, MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            return 0;
        }
        catch (Exception error)
        {
            if (!silent) { RtsMessageBox.Show("卸载未完成：" + error.Message, ProductName, MessageBoxButtons.OK, MessageBoxIcon.Error); }
            return 1;
        }
        finally { ScheduleSelfDelete(); }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool silent = HasArgument(args, "--silent");
        if (args.Length > 0 && String.Equals(args[0], "--cleanup", StringComparison.OrdinalIgnoreCase)) { return CleanupMode(args, silent); }
        try
        {
            string installDirectory = GetCurrentInstallDirectory();
            if (!silent)
            {
                DialogResult answer = RtsMessageBox.Show(
                    "确定卸载 " + ProductName + " 吗？\r\n\r\n如果存在地图替换记录，卸载器会先恢复地图。",
                    ProductName,
                    MessageBoxButtons.OKCancel,
                    MessageBoxIcon.Question);
                if (answer != DialogResult.OK) { return 2; }
            }
            RestoreMapBeforeUninstall(installDirectory);
            string self = Path.GetFullPath(Process.GetCurrentProcess().MainModule.FileName);
            string temporaryCopy = Path.Combine(GetTemporaryDirectory(), "Dota2MapSwitcherUninstall_" + Guid.NewGuid().ToString("N") + ".exe");
            File.Copy(self, temporaryCopy, true);
            ProcessStartInfo startInfo = new ProcessStartInfo(temporaryCopy);
            startInfo.Arguments = "--cleanup " + Process.GetCurrentProcess().Id + " " + EncodePath(installDirectory) + (silent ? " --silent" : "");
            // A shortcut starts this process with the installation directory as
            // its working directory. Do not let the temporary cleanup process
            // inherit it, otherwise Windows keeps the final empty folder in use.
            startInfo.WorkingDirectory = GetTemporaryDirectory();
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            Process.Start(startInfo);
            return 0;
        }
        catch (Exception error)
        {
            if (!silent) { RtsMessageBox.Show("无法卸载：" + error.Message, ProductName, MessageBoxButtons.OK, MessageBoxIcon.Error); }
            return 1;
        }
    }
}
