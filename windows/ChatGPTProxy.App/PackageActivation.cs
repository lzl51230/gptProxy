using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using ChatGPTProxy.Core;
namespace ChatGPTProxy.App;
internal static class PackageActivation
{
    [ComImport,Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationActivationManager
    {
        void ActivateApplication([MarshalAs(UnmanagedType.LPWStr)]string appId,[MarshalAs(UnmanagedType.LPWStr)]string arguments,uint options,out uint processId);
        void ActivateForFile([MarshalAs(UnmanagedType.LPWStr)]string appId,nint items,[MarshalAs(UnmanagedType.LPWStr)]string verb,out uint processId);
        void ActivateForProtocol([MarshalAs(UnmanagedType.LPWStr)]string appId,nint items,out uint processId);
    }
    public static Process Launch(string appId,string fullName)
    {
        var type=Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C"),true)!;
        var manager=(IApplicationActivationManager)Activator.CreateInstance(type)!;
        try {
            // Activation preserves MSIX identity and the app's update/sandbox lifecycle.
            // Network interception is already active before this native operation.
            manager.ActivateApplication(appId,"",2,out var pid);
            if(ProcessIdentity.PackageFullName((int)pid)!=fullName)throw new InvalidOperationException("ChatGPT 进程缺少预期的应用包身份");
            return Process.GetProcessById((int)pid);
        } finally {Marshal.FinalReleaseComObject(manager);}
    }
}
