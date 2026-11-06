using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using Microsoft.Win32.SafeHandles;

namespace ChatGPTProxy.Service;
internal static partial class LocalPipe
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes { public uint Length; public nint Descriptor; public int Inherit; }
    [LibraryImport("kernel32.dll",EntryPoint="CreateNamedPipeW",StringMarshalling=StringMarshalling.Utf16,SetLastError=true)]
    private static partial SafePipeHandle Create(string name,uint openMode,uint pipeMode,uint instances,uint outputSize,uint inputSize,uint timeout,ref SecurityAttributes security);
    public static NamedPipeServerStream Open(string name,PipeSecurity security)
    {
        var descriptor=security.GetSecurityDescriptorBinaryForm();
        var memory=Marshal.AllocHGlobal(descriptor.Length);
        try {
            Marshal.Copy(descriptor,0,memory,descriptor.Length);
            var attributes=new SecurityAttributes{Length=(uint)Marshal.SizeOf<SecurityAttributes>(),Descriptor=memory};
            // Duplex, overlapped; byte mode with PIPE_REJECT_REMOTE_CLIENTS.
            var handle=Create(@"\\.\pipe\"+name,0x40000003,0x8,16,65536,65536,0,ref attributes);
            if(handle.IsInvalid){var error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}
            try{return new NamedPipeServerStream(PipeDirection.InOut,true,false,handle);}catch{handle.Dispose();throw;}
        } finally{Marshal.FreeHGlobal(memory);}
    }
}
