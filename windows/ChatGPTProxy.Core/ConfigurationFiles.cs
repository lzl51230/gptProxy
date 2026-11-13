using System.Text;

namespace ChatGPTProxy.Core;

public static class ConfigurationFiles
{
    public const int MaximumConfigurationSize = 32 * 1024 * 1024;
    public const int MaximumResponseSize = 128 * 1024 * 1024;
    public const int MaximumRecoverySize = 256 * 1024 * 1024;
    private static readonly UTF8Encoding StrictUTF8 = new(false, true);

    public static string ReadSource(string path) => ReadText(path, MaximumConfigurationSize, "Clash 工作配置");
    public static string ReadRecovery(string path) => ReadText(path, MaximumRecoverySize, "DNS 恢复记录");

    private static string ReadText(string path, int maximum, string label)
    {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        ValidateSize(input.Length, maximum, label);
        using var output = new MemoryStream();
        var buffer = new byte[64 * 1024];
        int count;
        while ((count = input.Read(buffer, 0, (int)Math.Min(buffer.Length, maximum + 1L - output.Length))) > 0)
        {
            ValidateSize(output.Length + count, maximum, label);
            output.Write(buffer, 0, count);
        }
        ValidateSize(input.Length, maximum, label);
        if (input.Length != output.Length) throw new IOException($"{label}在读取期间发生变化，请重试");
        var text = StrictUTF8.GetString(output.GetBuffer(), 0, checked((int)output.Length));
        return text.StartsWith('\uFEFF') ? text[1..] : text;
    }

    public static void ValidateSize(long size, int maximum, string label)
    {
        if (size < 0 || size > maximum)
            throw new IOException($"{label}大小为 {size / 1024d / 1024d:F2} MiB（{size} 字节），超过 {maximum / 1024 / 1024} MiB 上限");
    }
}
