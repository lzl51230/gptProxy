using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace ChatGPTProxy.Core;

public static class UpdateInstaller
{
    public static string InstallRoot() => OperatingSystem.IsMacOS() ? Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../..")) : Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
    public static string ManifestPath(string root) => Path.Combine(root, OperatingSystem.IsMacOS() ? "Contents/Resources/update-manifest.json" : "update-manifest.json");
    public static Process Start(string executable, params string[] args)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, WorkingDirectory = Path.GetTempPath() };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return Process.Start(info) ?? throw new IOException("无法启动更新辅助程序");
    }
    public static void Extract(string zip, string target)
    {
        using var archive = ZipFile.OpenRead(zip);
        long total = 0;
        foreach (var entry in archive.Entries)
        {
            var name = entry.FullName.Replace('\\', '/');
            if (name.StartsWith('/') || name.Split('/').Any(p => p is ".." or "." || p.Contains(':')) || ((entry.ExternalAttributes >> 16) & 0xf000) == 0xa000)
                throw new InvalidDataException("安装包包含不安全路径或链接");
            total += entry.Length; if (total > 2L * 1024 * 1024 * 1024) throw new InvalidDataException("安装包解压体积过大");
        }
        Directory.CreateDirectory(target);
        if (OperatingSystem.IsMacOS())
        {
            if (RunMacCommand("/usr/bin/ditto", "-x", "-k", zip, target) != 0) throw new IOException("解压失败");
        }
        else ZipFile.ExtractToDirectory(zip, target);
    }
    public static UpdateManifest Validate(string root, string version, string runtime)
    {
        var manifest = JsonSerializer.Deserialize<UpdateManifest>(File.ReadAllText(ManifestPath(root))) ?? throw new InvalidDataException("安装清单缺失");
        if (AppUpdates.ParseVersion(manifest.Version) != AppUpdates.ParseVersion(version) || manifest.Runtime != runtime) throw new InvalidDataException("安装包版本或架构不符");
        foreach (var file in manifest.Files) { if(file.Replace('\\','/').Split('/')[0].Equals("Data", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("安装包不得包含用户数据"); var path = SafePath(root, file); if (!File.Exists(path)) throw new InvalidDataException("安装包文件缺失：" + file); }
        foreach(var item in new DirectoryInfo(root).EnumerateFileSystemInfos("*",SearchOption.AllDirectories)) {
            if((item.Attributes & FileAttributes.ReparsePoint)!=0)throw new InvalidDataException("安装目录包含链接");
        }
        var executable = Path.Combine(root, OperatingSystem.IsMacOS() ? "Contents/MacOS/ChatGPTProxy.App" : "ChatGPTProxy.App.exe");
        if (!File.Exists(executable)) throw new InvalidDataException("安装包应用缺失");
        var assembly = Path.Combine(root, OperatingSystem.IsMacOS() ? "Contents/MacOS/ChatGPTProxy.App.dll" : "ChatGPTProxy.App.dll");
        var identity = System.Reflection.AssemblyName.GetAssemblyName(assembly);
        if (identity.Name != "ChatGPTProxy.App" || identity.Version is not { } actual || new Version(actual.Major, actual.Minor, actual.Build) != AppUpdates.ParseVersion(version))
            throw new InvalidDataException("应用身份或实际版本与清单不符");
        if (OperatingSystem.IsMacOS())
        {
            if (RunMacCommand("/usr/bin/codesign", "--verify", "--deep", "--strict", root) != 0) throw new InvalidDataException("应用签名校验失败");
        }
        return manifest;
    }
    public static string SafePath(string root, string relative)
    {
        if (Path.IsPathRooted(relative) || relative.Replace('\\', '/').Split('/').Any(p => p is ".." or "." || p.Contains(':'))) throw new InvalidDataException("文件清单路径无效");
        var path = Path.GetFullPath(Path.Combine(root, relative));
        if (!path.StartsWith(Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) throw new InvalidDataException("路径越界");
        return path;
    }
    public static async Task WaitFile(string path, TimeSpan timeout, Process? process = null, CancellationToken ct = default)
    {
        var watch = Stopwatch.StartNew();
        while (!File.Exists(path))
        {
            if(path.EndsWith(".commit",StringComparison.Ordinal)&&File.Exists(path[..^7]+".abort"))throw new OperationCanceledException();
            if(process?.HasExited == true) {
                var errorFile=Path.ChangeExtension(path,".error");
                if(File.Exists(errorFile)) {
                    using var reader=File.OpenText(errorFile);var detail=reader.ReadLine()??"更新辅助程序退出";
                    if(detail.Contains("Win32Exception (1223)",StringComparison.Ordinal))throw new OperationCanceledException("用户取消了管理员授权");
                    throw new IOException(detail);
                }
                throw new IOException("更新辅助程序已退出："+Path.GetFileName(path));
            }
            if (watch.Elapsed > timeout) throw new IOException("更新步骤超时：" + Path.GetFileName(path));
            await Task.Delay(100, ct);
        }
    }
    public static UpdateTransaction ReadTransaction(string file)
    {
        var tx = JsonSerializer.Deserialize<UpdateTransaction>(File.ReadAllText(file)) ?? throw new InvalidDataException("更新事务无效");
        if (!Path.IsPathFullyQualified(tx.Target) || !Path.IsPathFullyQualified(tx.Stage) || tx.Backup != tx.Target + ".update-backup" || tx.Target == Path.GetPathRoot(tx.Target)) throw new InvalidDataException("更新目标无效");
        return tx;
    }
    private static void CopyTree(string source, string target)
    {
        if (OperatingSystem.IsMacOS())
        {
            foreach (var item in new DirectoryInfo(source).EnumerateFileSystemInfos("*", SearchOption.AllDirectories))
                if ((item.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("更新目录包含链接：" + item.Name);
            if (RunMacCommand("/usr/bin/ditto", source, target) != 0) throw new IOException("复制应用失败");
            return;
        }
        Directory.CreateDirectory(target);
        foreach (var item in new DirectoryInfo(source).EnumerateFileSystemInfos())
        {
            if ((item.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("更新目录包含链接：" + item.Name);
            var destination = Path.Combine(target, item.Name);
            if (item is DirectoryInfo) CopyTree(item.FullName, destination);
            else { File.Copy(item.FullName, destination, true); if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(destination, File.GetUnixFileMode(item.FullName)); }
        }
    }
    public static async Task Worker(string file)
    {
        var tx = ReadTransaction(file); var next = tx.Target + ".update-next";
        if (File.Exists(file + ".recover")) { await Restore(file, tx); return; }
        if (Directory.Exists(tx.Backup) || Directory.Exists(next)) throw new IOException("存在未完成更新，请先恢复备份：" + tx.Backup);
        var staged=Validate(tx.Stage, tx.Version, AppUpdates.Runtime);
        foreach(var path in Directory.EnumerateFiles(tx.Stage,"*",SearchOption.AllDirectories)) {
            var relative=Path.GetRelativePath(tx.Stage,path).Replace('\\','/');
            if(relative=="update-manifest.json")continue;
            if(relative.Split('/')[0].Equals("Data",StringComparison.OrdinalIgnoreCase)||!staged.Files.Contains(relative,StringComparer.OrdinalIgnoreCase))throw new InvalidDataException("安装包包含未登记文件");
        }
        try
        {
            // Construct the complete replacement before releasing the running application.
            if (OperatingSystem.IsMacOS()) CopyTree(tx.Stage, next);
            else
            {
                CopyTree(tx.Target, next);
                var previous = JsonSerializer.Deserialize<UpdateManifest>(File.ReadAllText(ManifestPath(tx.Target)))!;
                foreach (var name in previous.Files) { if(name.Replace('\\','/').Split('/')[0].Equals("Data",StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("旧清单包含用户数据");File.Delete(SafePath(next, name)); }
                CopyTree(tx.Stage, next);
            }
            Validate(next, tx.Version, AppUpdates.Runtime);
            File.WriteAllText(file + ".ready", "");
            await WaitFile(file + ".commit", TimeSpan.FromMinutes(5));
            try { using var parent = Process.GetProcessById(tx.Parent); await parent.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(60)); } catch (ArgumentException) { }
            // Refresh mutable portable data only after the old application stopped.
            if(OperatingSystem.IsWindows() && Directory.Exists(Path.Combine(tx.Target,"Data"))) {
                var data=Path.Combine(next,"Data");if(Directory.Exists(data))Directory.Delete(data,true);
                CopyTree(Path.Combine(tx.Target,"Data"),data);
            }
            File.WriteAllText(file + ".phase", "replacing");
            Directory.Move(tx.Target, tx.Backup);
            try { Directory.Move(next, tx.Target); }
            catch { Directory.Move(tx.Backup, tx.Target); throw; }
            File.WriteAllText(file + ".installed", "");
            await WaitFile(file + ".decision", TimeSpan.FromSeconds(100));
            if (File.ReadAllText(file + ".decision") != "success")
            {
                if(OperatingSystem.IsWindows() && Directory.Exists(Path.Combine(tx.Target,"Data")))CopyTree(Path.Combine(tx.Target,"Data"),Path.Combine(tx.Backup,"Data"));
                Directory.Move(tx.Target, next); Directory.Move(tx.Backup, tx.Target);
                File.WriteAllText(file + ".phase", "rolled-back");
            }
            else { File.WriteAllText(file + ".phase", "complete"); Directory.Delete(tx.Backup, true); }
        }
        catch
        {
            if (!Directory.Exists(tx.Target) && Directory.Exists(tx.Backup)) Directory.Move(tx.Backup, tx.Target);
            throw;
        }
        finally { if (Directory.Exists(next)) Directory.Delete(next, true); }
    }
    // Authorization Services can launch a worker in a context where managed child
    // exit notifications stall. Own these short native commands and reap them directly.
    [DllImport("libSystem.B.dylib", EntryPoint = "posix_spawn")]
    private static extern int Spawn(out int pid, string path, nint actions, nint attributes, nint argv, nint environment);
    [DllImport("libSystem.B.dylib", EntryPoint = "_NSGetEnviron")]
    private static extern nint GetEnvironment();
    [DllImport("libSystem.B.dylib", EntryPoint = "waitpid", SetLastError = true)]
    private static extern int WaitPid(int pid, out int status, int options);
    [DllImport("libSystem.B.dylib", EntryPoint = "kill", SetLastError = true)]
    private static extern int Kill(int pid, int signal);
    private static int RunMacCommand(string executable, params string[] arguments)
    {
        var strings = new[] { executable }.Concat(arguments).Select(Marshal.StringToCoTaskMemUTF8).ToArray();
        var argv = Marshal.AllocHGlobal((strings.Length + 1) * IntPtr.Size);
        try
        {
            for (var i = 0; i < strings.Length; i++) Marshal.WriteIntPtr(argv, i * IntPtr.Size, strings[i]);
            Marshal.WriteIntPtr(argv, strings.Length * IntPtr.Size, 0);
            var error = Spawn(out var pid, executable, 0, 0, argv, Marshal.ReadIntPtr(GetEnvironment()));
            if (error != 0) throw new IOException($"无法启动 {executable}：{error}");
            var watch = Stopwatch.StartNew();
            while (true)
            {
                var result = WaitPid(pid, out var status, 1); // WNOHANG
                if (result == pid) return status;
                if (result < 0 && Marshal.GetLastPInvokeError() != 4) throw new IOException("无法读取安装命令的退出状态");
                if (watch.Elapsed > TimeSpan.FromMinutes(2))
                { Kill(pid, 9); WaitPid(pid, out _, 0); throw new TimeoutException("安装命令执行超时"); }
                Thread.Sleep(20);
            }
        }
        finally { foreach (var value in strings) Marshal.FreeCoTaskMem(value); Marshal.FreeHGlobal(argv); }
    }
    private static string ShellQuote(string value) => "'" + value.Replace("'", "'\\''") + "'";
    private static Process WorkerProcess(string helper, string file, bool elevated)
    {
        if (!elevated) return Start(helper, "worker", file);
        if (OperatingSystem.IsWindows())
        {
            var info = new ProcessStartInfo(helper) { UseShellExecute = true, Verb = "runas", Arguments = "worker \"" + file + "\"", WorkingDirectory = Path.GetTempPath() };
            return Process.Start(info) ?? throw new IOException("系统授权失败");
        }
        var command = ShellQuote(helper) + " worker " + ShellQuote(file);
        var apple = "do shell script \"" + command.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\" with administrator privileges";
        return Start("/usr/bin/osascript", "-e", apple);
    }
    private static async Task Restore(string file, UpdateTransaction tx)
    {
        var previous = JsonSerializer.Deserialize<UpdateManifest>(File.ReadAllText(ManifestPath(tx.Backup)))!;
        Validate(tx.Backup, previous.Version, AppUpdates.Runtime);
        File.WriteAllText(file + ".ready", "");
        await WaitFile(file + ".commit", TimeSpan.FromMinutes(5));
        try { using var parent = Process.GetProcessById(tx.Parent); await parent.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(60)); } catch (ArgumentException) { }
        var failed = tx.Target + ".failed-" + Guid.NewGuid().ToString("N");
        if (Directory.Exists(tx.Target)) Directory.Move(tx.Target, failed);
        try { Directory.Move(tx.Backup, tx.Target); }
        catch { if (Directory.Exists(failed)) Directory.Move(failed, tx.Target); throw; }
        File.WriteAllText(file + ".phase", "rolled-back");
        File.WriteAllText(file + ".installed", "");
        if (Directory.Exists(failed)) Directory.Delete(failed, true);
    }
    public static async Task Coordinate(string file)
    {
        File.WriteAllText(file + ".coordinator", Environment.ProcessId.ToString());
        var tx = ReadTransaction(file); var helper = Environment.ProcessPath!;
        var elevated = false;
        try { var probe = tx.Target + ".write-test-" + Guid.NewGuid().ToString("N"); Directory.CreateDirectory(probe); Directory.Delete(probe); }
        catch (UnauthorizedAccessException) { elevated = true; }
        using var worker = WorkerProcess(helper, file, elevated);
        try { await WaitFile(file + ".installed", TimeSpan.FromMinutes(7), worker); }
        catch
        {
            bool parentAlive;
            try { using var parent = Process.GetProcessById(tx.Parent); parentAlive = !parent.HasExited; } catch (ArgumentException) { parentAlive = false; }
            if (!parentAlive && Directory.Exists(tx.Target)) Launch(tx, file).Dispose();
            throw;
        }
        if (File.Exists(file + ".recover")) { await worker.WaitForExitAsync(); Launch(tx, file).Dispose(); return; }
        Process? launched = null;
        try
        {
            launched = Launch(tx, file);
            await WaitFile(file + ".healthy", TimeSpan.FromSeconds(60), launched);
            File.WriteAllText(file + ".decision", "success");
        }
        catch
        {
            if (launched is not null && !launched.HasExited) { launched.Kill(true); await launched.WaitForExitAsync(); }
            File.WriteAllText(file + ".decision", "rollback");
            await worker.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
            if (File.ReadAllText(file + ".phase") == "rolled-back") Launch(tx, file).Dispose();
            throw;
        }
        finally { launched?.Dispose(); }
        await worker.WaitForExitAsync();
        if (worker.ExitCode == 0 && File.ReadAllText(file + ".phase") == "complete")
        {
            try { Directory.Delete(tx.Stage, true); File.Delete(Path.Combine(Path.GetDirectoryName(file)!, "download.zip")); }
            catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
    private static Process Launch(UpdateTransaction tx, string file) => OperatingSystem.IsMacOS()
        ? Start(Path.Combine(tx.Target, "Contents/MacOS/ChatGPTProxy.App"), "--update-restart", file)
        : Start(Path.Combine(tx.Target, "ChatGPTProxy.App.exe"), "--update-restart", file);
    public static UpdateTransaction? RestartContext(out string? file)
    {
        file = null; var args = Environment.GetCommandLineArgs(); var index = Array.IndexOf(args, "--update-restart");
        if (index < 0 || index + 1 >= args.Length) return null;
        var path = Path.GetFullPath(args[index + 1]);
        if (!path.StartsWith(Path.GetFullPath(AppUpdates.Cache) + Path.DirectorySeparatorChar, StringComparison.Ordinal)) return null;
        var tx = ReadTransaction(path);
        if (Path.TrimEndingDirectorySeparator(tx.Target) != InstallRoot() || !File.Exists(path + ".commit")) return null;
        file = path; return tx;
    }
}
