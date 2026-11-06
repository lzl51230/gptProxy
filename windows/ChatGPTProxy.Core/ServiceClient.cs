using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Microsoft.Win32.SafeHandles;

namespace ChatGPTProxy.Core;
public static partial class ServiceClient
{
    public const string PipeName="ChatGPTProxy.Control.v1";
    public static async Task<JsonNode> Call(JsonObject request,CancellationToken cancellation=default)
    {
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(cancellation);timeout.CancelAfter(TimeSpan.FromSeconds(90));
        using var pipe=new NamedPipeClientStream(".",PipeName,PipeDirection.InOut,PipeOptions.Asynchronous,System.Security.Principal.TokenImpersonationLevel.Impersonation);
        await pipe.ConnectAsync(3000,timeout.Token);
        if(!GetNamedPipeServerProcessId(pipe.SafePipeHandle,out var pid))throw new IOException("Cannot authenticate service");
        if(pid != ServiceIdentity.RunningProcessId())throw new IOException("Unexpected service identity");
        await Write(pipe,request,timeout.Token);var response=await Read(pipe,timeout.Token);
        if(response["ok"]?.GetValue<bool>()!=true)throw new IOException(response["error"]?.GetValue<string>()??"服务请求失败");
        return response["value"]?.DeepClone()??new JsonObject();
    }
    public static async Task Write(Stream stream,JsonNode value,CancellationToken token)
    {
        var bytes=System.Text.Encoding.UTF8.GetBytes(value.ToJsonString());if(bytes.Length>65536)throw new IOException("IPC request too large");
        var size=new byte[4];BinaryPrimitives.WriteInt32LittleEndian(size,bytes.Length);await stream.WriteAsync(size,token);await stream.WriteAsync(bytes,token);await stream.FlushAsync(token);
    }
    public static async Task<JsonNode> Read(Stream stream,CancellationToken token)
    {
        var size=new byte[4];await stream.ReadExactlyAsync(size,token);var count=BinaryPrimitives.ReadInt32LittleEndian(size);
        if(count<2||count>65536)throw new IOException("Invalid IPC frame length");var bytes=new byte[count];await stream.ReadExactlyAsync(bytes,token);return JsonNode.Parse(bytes)??throw new IOException("Invalid IPC JSON");
    }
    [LibraryImport("kernel32.dll",SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetNamedPipeServerProcessId(SafePipeHandle pipe,out uint pid);
}
