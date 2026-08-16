using System;
using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class Dota2TerrainSwitcherLauncher
{
    [DllImport("shell32.dll")]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appID);

    private static readonly string[] TerrainImageNames = new string[]
    {
        "dota_autumn.png",
        "dota_cavern.png",
        "dota_coloseum.png",
        "dota_desert.png",
        "dota_journey.png",
        "dota_jungle.png",
        "dota_reef.png",
        "dota_spring.png",
        "dota_summer.png",
        "dota_ti10.png",
        "dota_winter.png"
    };

    private static void AddForwardedArguments(PowerShell shell, string[] args)
    {
        for (int index = 0; index < args.Length; index++)
        {
            string argument = args[index];
            if (!argument.StartsWith("-", StringComparison.Ordinal))
            {
                throw new ArgumentException("无法识别的启动参数：" + argument);
            }
            string parameterName = argument.TrimStart('-');
            if (index + 1 < args.Length && !args[index + 1].StartsWith("-", StringComparison.Ordinal))
            {
                shell.AddParameter(parameterName, args[++index]);
            }
            else
            {
                shell.AddParameter(parameterName);
            }
        }
    }

    private static void ExtractResource(string resourceName, string destinationPath)
    {
        using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
        {
            if (source == null)
            {
                throw new InvalidOperationException("缺少内嵌资源：" + resourceName);
            }
            using (FileStream destination = File.Create(destinationPath))
            {
                source.CopyTo(destination);
            }
        }
    }

    private static bool IsProcessRunning(int processId)
    {
        try
        {
            using (Process process = Process.GetProcessById(processId))
            {
                return !process.HasExited;
            }
        }
        catch
        {
            return false;
        }
    }

    private static void CleanupRuntimeRoot(string runtimeRoot)
    {
        if (!Directory.Exists(runtimeRoot)) { return; }
        foreach (string directory in Directory.GetDirectories(runtimeRoot))
        {
            int processId;
            if (Int32.TryParse(Path.GetFileName(directory), out processId) && IsProcessRunning(processId))
            {
                continue;
            }
            try { Directory.Delete(directory, true); } catch { }
        }
        try
        {
            if (Directory.GetFileSystemEntries(runtimeRoot).Length == 0)
            {
                Directory.Delete(runtimeRoot, false);
            }
        }
        catch { }
    }

    private static bool HasValidInstallMarker(string applicationDirectory)
    {
        try
        {
            string markerPath = Path.Combine(applicationDirectory, ".dota2-map-switcher-install");
            return File.Exists(markerPath) &&
                String.Equals(File.ReadAllText(markerPath).Trim(), "Dota2MapSwitcher.Install.v1", StringComparison.Ordinal);
        }
        catch { return false; }
    }

    private static bool IsValidApplicationDirectory(string applicationDirectory)
    {
        bool isInstalled =
            HasValidInstallMarker(applicationDirectory) &&
            File.Exists(Path.Combine(applicationDirectory, "Uninstall.exe"));
        bool isPortable =
            String.Equals(Path.GetFileName(applicationDirectory), "Dota2MapSwitcher-Portable", StringComparison.OrdinalIgnoreCase) &&
            File.Exists(Path.Combine(applicationDirectory, "使用说明.txt"));
        if (!isInstalled && !isPortable) { return false; }

        string executablePath = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);
        foreach (string entry in Directory.GetFileSystemEntries(applicationDirectory))
        {
            string fullPath = Path.GetFullPath(entry);
            if (String.Equals(fullPath, executablePath, StringComparison.OrdinalIgnoreCase)) { continue; }

            string name = Path.GetFileName(entry);
            if (String.Equals(name, ".runtime", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(name, ".data", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(name, "Uninstall.exe", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(name, ".dota2-map-switcher-install", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(name, "使用说明.txt", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(name, "desktop.ini", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            return false;
        }
        return true;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        SetCurrentProcessExplicitAppUserModelID("Dota2.MapSwitcher");
        string applicationDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        string stateFilePath = Path.Combine(applicationDirectory, ".data", "active-swap.json");
        string runtimeRoot = Path.Combine(applicationDirectory, ".runtime");
        CleanupRuntimeRoot(runtimeRoot);
        if (!IsValidApplicationDirectory(applicationDirectory))
        {
            MessageBox.Show(
                "免安装版只能在 Dota2MapSwitcher-Portable 文件夹中运行。\r\n\r\n" +
                "请移动或分享整个文件夹，不要单独移动 EXE。如果想在桌面启动，请创建桌面快捷方式。",
                "Dota 2 地图更换器",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return 1;
        }
        string scriptPath = Path.Combine(applicationDirectory, "Dota2TerrainSwitcher.ps1");
        string catalogPath = Path.Combine(applicationDirectory, "terrain-catalog.json");
        string uiTextPath = Path.Combine(applicationDirectory, "ui.zh-CN.json");
        string iconPath = Path.Combine(applicationDirectory, "Dota2TerrainSwitcher.ico");
        string resourceDirectory = applicationDirectory;
        string temporaryDirectory = null;
        if (!File.Exists(scriptPath) || !File.Exists(catalogPath) || !File.Exists(uiTextPath) || !File.Exists(iconPath))
        {
            Directory.CreateDirectory(runtimeRoot);
            try
            {
                File.SetAttributes(runtimeRoot, File.GetAttributes(runtimeRoot) | FileAttributes.Hidden);
            }
            catch { }
            temporaryDirectory = Path.Combine(runtimeRoot, Process.GetCurrentProcess().Id.ToString());
            Directory.CreateDirectory(temporaryDirectory);
            scriptPath = Path.Combine(temporaryDirectory, "Dota2TerrainSwitcher.ps1");
            catalogPath = Path.Combine(temporaryDirectory, "terrain-catalog.json");
            uiTextPath = Path.Combine(temporaryDirectory, "ui.zh-CN.json");
            iconPath = Path.Combine(temporaryDirectory, "Dota2TerrainSwitcher.ico");
            string terrainImageDirectory = Path.Combine(temporaryDirectory, "terrains");
            Directory.CreateDirectory(terrainImageDirectory);
            ExtractResource("Dota2TerrainSwitcher.ps1", scriptPath);
            ExtractResource("terrain-catalog.json", catalogPath);
            ExtractResource("ui.zh-CN.json", uiTextPath);
            ExtractResource("Dota2TerrainSwitcher.ico", iconPath);
            foreach (string terrainImageName in TerrainImageNames)
            {
                ExtractResource(
                    "terrains." + terrainImageName,
                    Path.Combine(terrainImageDirectory, terrainImageName));
            }
            resourceDirectory = temporaryDirectory;
        }

        try
        {
            Environment.CurrentDirectory = applicationDirectory;
            string scriptText = File.ReadAllText(scriptPath, Encoding.UTF8);
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell shell = PowerShell.Create())
                {
                    shell.Runspace = runspace;
                    shell.AddScript(scriptText, true);
                    shell.AddParameter("AppDirectoryOverride", applicationDirectory);
                    shell.AddParameter("ResourceDirectoryOverride", resourceDirectory);
                    shell.AddParameter("StateFileOverridePath", stateFilePath);
                    AddForwardedArguments(shell, args);
                    shell.Invoke();
                    // WPF can leave HadErrors=true after a handled Closing event even
                    // when the error stream is empty. Only real error records are fatal.
                    if (shell.Streams.Error.Count > 0)
                    {
                        StringBuilder errorText = new StringBuilder();
                        foreach (ErrorRecord error in shell.Streams.Error)
                        {
                            if (errorText.Length > 0) { errorText.AppendLine(); }
                            errorText.Append(error.ToString());
                        }
                        throw new InvalidOperationException(errorText.ToString());
                    }
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            string detail = error.Message;
            if (String.IsNullOrWhiteSpace(detail))
            {
                detail = error.GetType().FullName;
            }
            MessageBox.Show(
                "启动失败：" + detail,
                "Dota 2 地图更换器",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            if (!String.IsNullOrEmpty(temporaryDirectory))
            {
                try { Directory.Delete(temporaryDirectory, true); } catch { }
            }
            CleanupRuntimeRoot(runtimeRoot);
        }
    }
}
