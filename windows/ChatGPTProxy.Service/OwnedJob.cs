using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace ChatGPTProxy.Service;
internal sealed class OwnedJob : SafeHandleZeroOrMinusOneIsInvalid
{
    public OwnedJob(Process process):base(true)
    {
        SetHandle(CreateJobObjectW(nint.Zero,null));
        if(IsInvalid)throw new Win32Exception();
        var limits=new ExtendedLimits();limits.Basic.LimitFlags=0x2000; // KILL_ON_JOB_CLOSE
        if(!SetInformationJobObject(handle,9,ref limits,(uint)Marshal.SizeOf<ExtendedLimits>())||!AssignProcessToJobObject(handle,process.Handle)){Dispose();throw new Win32Exception();}
    }
    protected override bool ReleaseHandle()=>CloseHandle(handle);
    [StructLayout(LayoutKind.Sequential)]private struct BasicLimits{public long PerProcess,PerJob;public uint LimitFlags;public nuint Minimum,Maximum;public uint Active;public nuint Affinity;public uint Priority,Scheduling;}
    [StructLayout(LayoutKind.Sequential)]private struct Counters{public ulong ReadOperations,WriteOperations,OtherOperations,ReadBytes,WriteBytes,OtherBytes;}
    [StructLayout(LayoutKind.Sequential)]private struct ExtendedLimits{public BasicLimits Basic;public Counters Io;public nuint ProcessMemory,JobMemory,PeakProcessMemory,PeakJobMemory;}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]private static extern nint CreateJobObjectW(nint attributes,string? name);
    [DllImport("kernel32.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool SetInformationJobObject(nint job,int type,ref ExtendedLimits information,uint size);
    [DllImport("kernel32.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool AssignProcessToJobObject(nint job,nint process);
    [DllImport("kernel32.dll")][return:MarshalAs(UnmanagedType.Bool)]private static extern bool CloseHandle(nint handle);
}
