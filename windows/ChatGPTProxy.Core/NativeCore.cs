using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace ChatGPTProxy.Core;

// Both native hosts use the same versioned C ABI. Rust owns buffers and sockets.
public sealed partial class NativeCore : SafeHandleZeroOrMinusOneIsInvalid
{
    static NativeCore()
    {
        NativeLibrary.SetDllImportResolver(typeof(NativeCore).Assembly, (name, assembly, path) =>
            name == "gpt_proxy_core"
                ? NativeLibrary.Load(Path.Combine(AppContext.BaseDirectory,
                    OperatingSystem.IsWindows() ? "gpt_proxy_core.dll" : "libgpt_proxy_core.dylib"))
                : nint.Zero);
    }

    public NativeCore() : base(true)
    {
        if (AbiVersion() != 1) throw new InvalidOperationException("Unsupported Rust core ABI");
        SetHandle(Create());
        if (IsInvalid) throw new InvalidOperationException("Cannot create Rust core");
    }

    public unsafe JsonElement Call<T>(T request)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(request);
        bool retained = false;
        try
        {
            DangerousAddRef(ref retained);
            fixed (byte* input = bytes)
            {
                var buffer = Invoke(DangerousGetHandle(), input, (nuint)bytes.Length);
                try
                {
                    using var response = JsonDocument.Parse(new ReadOnlySpan<byte>((void*)buffer.Data, checked((int)buffer.Length)).ToArray());
                    var root = response.RootElement;
                    if (!root.GetProperty("ok").GetBoolean())
                        throw new InvalidOperationException(root.GetProperty("error").GetString());
                    return root.GetProperty("value").Clone();
                }
                finally { Free(buffer); }
            }
        }
        finally { if (retained) DangerousRelease(); }
    }

    protected override bool ReleaseHandle() { Destroy(handle); return true; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Buffer { public nint Data; public nuint Length; }
    [LibraryImport("gpt_proxy_core", EntryPoint = "cgp_core_abi_version")]
    private static partial uint AbiVersion();
    [LibraryImport("gpt_proxy_core", EntryPoint = "cgp_core_create")]
    private static partial nint Create();
    [LibraryImport("gpt_proxy_core", EntryPoint = "cgp_core_call")]
    private static unsafe partial Buffer Invoke(nint engine, byte* input, nuint length);
    [LibraryImport("gpt_proxy_core", EntryPoint = "cgp_core_buffer_free")]
    private static partial void Free(Buffer buffer);
    [LibraryImport("gpt_proxy_core", EntryPoint = "cgp_core_destroy")]
    private static partial void Destroy(nint engine);
}
