using System;
using System.Diagnostics;
using System.IO;

namespace ClaudeLimits
{
    /// NSLog stand-in: a WinExe has no stdout, so append to %TEMP%\claude-limits.log
    /// (the Mac LaunchAgent sends stdout+stderr to /tmp/claude-limits.log).
    public static class Log
    {
        static readonly object gate = new object();
        public static readonly string Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "claude-limits.log");
        static readonly int pid = Process.GetCurrentProcess().Id;

        public static void Write(string message)
        {
            var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} claude-limits[{pid}] {message}{Environment.NewLine}";
            lock (gate)
            {
                try { File.AppendAllText(Path, line); } catch { }
            }
        }

        /// Keep the log from growing without bound across months of uptime.
        public static void TrimIfLarge(long maxBytes = 1_000_000)
        {
            try
            {
                var fi = new FileInfo(Path);
                if (fi.Exists && fi.Length > maxBytes) File.Delete(Path);
            }
            catch { }
        }
    }
}
