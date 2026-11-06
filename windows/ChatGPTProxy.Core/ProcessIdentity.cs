using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace ChatGPTProxy.Core;
[System.Runtime.Versioning.SupportedOSPlatform("windows")]
public static class ProcessIdentity
{
    public const string ChatGPTFamily="OpenAI.Codex_2p2nqsd0c76g0";
    public static bool IsChatGPTPackage(string fullName)=>fullName.StartsWith("OpenAI.Codex_",StringComparison.Ordinal)&&fullName.EndsWith("_2p2nqsd0c76g0",StringComparison.Ordinal);
    public static T AsProcessUser<T>(int pid,Func<T> read)
    {
        using var process=OpenProcess(0x1000,false,pid);
        if(process.IsInvalid||!OpenProcessToken(process,0xA,out var token))throw new Win32Exception();
        using(token)return System.Security.Principal.WindowsIdentity.RunImpersonated(token,read);
    }
    public static string ImagePath(int pid)
    {
        using var process=OpenProcess(0x1000,false,pid);
        if(process.IsInvalid)throw new Win32Exception();var path=new StringBuilder(32768);uint size=(uint)path.Capacity;
        if(!QueryFullProcessImageNameW(process,0,path,ref size))throw new Win32Exception();return path.ToString();
    }
    public static string PackageFullName(int pid)
    {
        using var process=OpenProcess(0x1000,false,pid);if(process.IsInvalid)throw new Win32Exception();
        uint length=0;var result=GetPackageFullName(process,ref length,null);
        if(result!=122)throw new Win32Exception(result);var value=new StringBuilder((int)length);
        result=GetPackageFullName(process,ref length,value);if(result!=0)throw new Win32Exception(result);return value.ToString();
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true)]private static extern int GetPackageFullName(SafeProcessHandle process,ref uint length,StringBuilder? name);
    public static string OwnerSid(int pid)
    {
        using var process=OpenProcess(0x1000,false,pid);
        if(process.IsInvalid||!OpenProcessToken(process,8,out var token))throw new Win32Exception();
        using(token)using(var identity=new System.Security.Principal.WindowsIdentity(token.DangerousGetHandle()))
            return identity.User?.Value??throw new IOException("Missing process owner SID");
    }
    [DllImport("advapi32.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool OpenProcessToken(SafeProcessHandle process,uint access,out SafeAccessTokenHandle token);
    [DllImport("kernel32.dll",SetLastError=true)]private static extern SafeProcessHandle OpenProcess(uint access,[MarshalAs(UnmanagedType.Bool)]bool inherit,int pid);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool QueryFullProcessImageNameW(SafeProcessHandle process,uint flags,StringBuilder path,ref uint size);
}
