using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace ChatGPTProxy.Core;
internal static class ServiceIdentity
{
    // SCM state is readable by a normal user, unlike a LocalSystem process image.
    // Only an administrator can replace the registered service or start its PID.
    public static uint RunningProcessId()
    {
        using var manager=OpenSCManagerW(null,null,1);
        using var service=OpenServiceW(manager,"ChatGPTProxy",4);
        if(manager.IsInvalid||service.IsInvalid)throw new Win32Exception();
        if(!QueryServiceStatusEx(service,0,out var status,(uint)Marshal.SizeOf<Status>(),out _))throw new Win32Exception();
        if(status.State!=4||status.ProcessId==0)throw new IOException("Protection service is not running");return status.ProcessId;
    }
    [StructLayout(LayoutKind.Sequential)]private struct Status{public uint Type,State,Controls,ExitCode,SpecificExitCode,Checkpoint,WaitHint,ProcessId,Flags;}
    private sealed class ServiceHandle:SafeHandleZeroOrMinusOneIsInvalid{public ServiceHandle():base(true){}protected override bool ReleaseHandle()=>CloseServiceHandle(handle);}
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]private static extern ServiceHandle OpenSCManagerW(string? machine,string? database,uint access);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]private static extern ServiceHandle OpenServiceW(ServiceHandle manager,string name,uint access);
    [DllImport("advapi32.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool QueryServiceStatusEx(ServiceHandle service,int level,out Status status,uint size,out uint needed);
    [DllImport("advapi32.dll")][return:MarshalAs(UnmanagedType.Bool)]private static extern bool CloseServiceHandle(nint handle);
}
