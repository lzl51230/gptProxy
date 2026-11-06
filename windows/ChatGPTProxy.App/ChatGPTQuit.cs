using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
namespace ChatGPTProxy.App;
internal static class ChatGPTQuit
{
    [StructLayout(LayoutKind.Sequential)] private struct Keyboard {public ushort Key,Scan;public uint Flags,Time;public UIntPtr Extra;}
    [StructLayout(LayoutKind.Explicit,Size=32)] private struct InputData {[FieldOffset(0)]public Keyboard Keyboard;}
    [StructLayout(LayoutKind.Sequential)] private struct Input {public uint Type;public InputData Data;}
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool ShowWindow(nint window,int command);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll",SetLastError=true)] private static extern uint SendInput(uint count,Input[] input,int size);
    public static async Task Request(nint window)
    {
        // ChatGPT's window close keeps its background host alive. Ctrl+Q is its
        // visible File > Quit accelerator and allows the app to finish its work.
        if(window==0)throw new IOException("请先从 ChatGPT 的文件菜单正常退出，再重试");
        ShowWindow(window,9);SetForegroundWindow(window);
        for(int attempt=0;attempt<10&&GetForegroundWindow()!=window;attempt++)await Task.Delay(100);
        if(GetForegroundWindow()!=window)throw new IOException("无法向 ChatGPT 请求正常退出，请从其文件菜单退出后重试");
        foreach(var key in new[]{0x10,0x11,0x12,0x5B,0x5C})if((GetAsyncKeyState(key)&0x8000)!=0)throw new IOException("请松开修饰键后重试");
        static Input Key(ushort key,bool up)=>new(){Type=1,Data=new InputData{Keyboard=new Keyboard{Key=key,Flags=up?2u:0}}};
        var input=new[]{Key(0x11,false),Key(0x51,false),Key(0x51,true),Key(0x11,true)};
        if(SendInput((uint)input.Length,input,Marshal.SizeOf<Input>())!=input.Length)throw new IOException("ChatGPT 正常退出请求未送达");
    }
}
