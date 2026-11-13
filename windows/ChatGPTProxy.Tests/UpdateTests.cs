using System.IO.Compression;
using ChatGPTProxy.Core;
using Xunit;
public class UpdateTests {
    [Fact] public void VersionComparisonIsNumeric(){Assert.True(AppUpdates.ParseVersion("2.10.0")>AppUpdates.ParseVersion("2.9.9"));Assert.Throws<InvalidDataException>(()=>AppUpdates.ParseVersion("2.4.0-beta"));}
    [Theory][InlineData("../settings.json")][InlineData("/etc/passwd")][InlineData("Data/../../x")]
    public void PathsCannotEscape(string path){Assert.Throws<InvalidDataException>(()=>UpdateInstaller.SafePath(Path.GetTempPath(),path));}
    [Fact] public void ExplicitProxyDoesNotBypassHosts(){using var h=AppUpdates.CreateHandler(12345);Assert.True(h.UseProxy);Assert.False(h.Proxy!.IsBypassed(new Uri("https://github.com")));Assert.Equal(12345,h.Proxy.GetProxy(new Uri("https://github.com"))!.Port);Assert.False(h.AllowAutoRedirect);}
    [Fact] public void ZipTraversalIsRejected(){var root=Path.Combine(Path.GetTempPath(),Guid.NewGuid().ToString());Directory.CreateDirectory(root);try{var zip=Path.Combine(root,"bad.zip");using(var a=ZipFile.Open(zip,ZipArchiveMode.Create)){a.CreateEntry("../escape");}Assert.Throws<InvalidDataException>(()=>UpdateInstaller.Extract(zip,Path.Combine(root,"out")));Assert.False(File.Exists(Path.Combine(root,"escape")));}finally{Directory.Delete(root,true);}}
}

public class UpdateCheckLifecycleTests {
    private sealed class BlockedHandler: System.Net.Http.HttpMessageHandler {
        internal readonly TaskCompletionSource Started=new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal int Calls;
        protected override async Task<System.Net.Http.HttpResponseMessage> SendAsync(System.Net.Http.HttpRequestMessage request,CancellationToken token) {
            Interlocked.Increment(ref Calls);Started.TrySetResult();await Task.Delay(Timeout.Infinite,token);throw new InvalidOperationException();
        }
    }
    [Fact] public async Task ConcurrentChecksCoalesceAndCancellationReleasesBusyState() {
        var handler=new BlockedHandler();
        using var updates=new AppUpdates(()=>7890,()=>handler);
        var first=updates.CheckAsync();await handler.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await updates.CheckAsync();Assert.Equal(1,handler.Calls);updates.Cancel();await first;
        Assert.False(updates.Busy);Assert.Contains("取消",updates.Status);
    }
}

public class UpdateAuthorizationTests {
    [Fact] public async Task CanceledUacIsReportedAsCancellation() {
        var directory=Path.Combine(Path.GetTempPath(),Guid.NewGuid().ToString());Directory.CreateDirectory(directory);
        try {
            var signal=Path.Combine(directory,"transaction.json.ready");
            File.WriteAllText(Path.ChangeExtension(signal,".error"),"System.ComponentModel.Win32Exception (1223): User canceled authorization");
            var start=new System.Diagnostics.ProcessStartInfo(OperatingSystem.IsWindows()?"cmd.exe":"/bin/sh"){UseShellExecute=false,CreateNoWindow=true};
            start.ArgumentList.Add(OperatingSystem.IsWindows()?"/c":"-c");start.ArgumentList.Add("exit 1");
            using var child=System.Diagnostics.Process.Start(start)!;await child.WaitForExitAsync();
            await Assert.ThrowsAsync<OperationCanceledException>(()=>UpdateInstaller.WaitFile(signal,TimeSpan.FromSeconds(1),child));
        }finally{Directory.Delete(directory,true);}
    }
}
