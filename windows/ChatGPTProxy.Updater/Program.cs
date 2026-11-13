using ChatGPTProxy.Core;
try
{
    if (args.Length != 2) return 2;
    if (args[0] == "recover") {
        var tx=UpdateInstaller.ReadTransaction(args[1]);
        try {using var parent=System.Diagnostics.Process.GetProcessById(tx.Parent);if(!parent.HasExited)throw new IOException("请先退出启动器再恢复");}catch(ArgumentException){}
        foreach(var suffix in new[]{".ready",".installed",".healthy",".decision",".error",".abort"})File.Delete(args[1]+suffix);
        File.WriteAllText(args[1]+".recover","");File.WriteAllText(args[1]+".commit","");
        await UpdateInstaller.Coordinate(args[1]);
    }
    else if (args[0] == "coordinate") await UpdateInstaller.Coordinate(args[1]);
    else if (args[0] == "worker") await UpdateInstaller.Worker(args[1]);
    else return 2;
    return 0;
}
catch (Exception error)
{
    if (args.Length == 2) File.WriteAllText(args[1] + ".error", error.ToString());
    return 1;
}
