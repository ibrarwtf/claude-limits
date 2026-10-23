using System;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Windows;

namespace ClaudeLimits
{
    static class Program
    {
        static readonly string pipeName = $"claude-limits-{Environment.UserName}";

        [STAThread]
        static void Main(string[] args)
        {
            Log.TrimIfLarge();
            bool afterUpdate = args.Contains(SelfUpdate.AfterUpdateFlag);
            var url = args.FirstOrDefault(a => a.StartsWith(Platform.Name + ":", StringComparison.OrdinalIgnoreCase));

            // Single instance per user. A second launch (URL-scheme activation,
            // double-clicking the exe again) forwards to the running copy and
            // exits — the Mac gets this for free from LaunchServices.
            var mutex = new Mutex(false, @"Local\claude-limits");
            bool owned;
            try { owned = mutex.WaitOne(afterUpdate ? TimeSpan.FromSeconds(15) : TimeSpan.Zero); }
            catch (AbandonedMutexException) { owned = true; }
            if (!owned)
            {
                // Re-launching with no URL opens Settings (applicationShouldHandleReopen).
                Forward(url ?? $"{Platform.Name}://settings");
                return;
            }

            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            app.DispatcherUnhandledException += (_, e) =>
            {
                Log.Write($"unhandled: {e.Exception}");
                e.Handled = true;
            };
            AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"fatal: {e.ExceptionObject}");

            var tray = new TrayApp();
            app.Startup += (_, __) =>
            {
                tray.Start();
                StartPipeServer(app, tray);
                if (url != null) tray.HandleUrl(url);
            };
            Log.Write($"claude-limits v{Platform.Version} starting");
            app.Run();
            GC.KeepAlive(mutex);
        }

        static void Forward(string message)
        {
            try
            {
                using (var client = new NamedPipeClientStream(".", pipeName, PipeDirection.Out))
                {
                    client.Connect(3000);
                    using (var w = new StreamWriter(client)) w.WriteLine(message);
                }
            }
            catch (Exception e) { Log.Write($"forward to running instance failed: {e.Message}"); }
        }

        static void StartPipeServer(Application app, TrayApp tray)
        {
            var t = new Thread(() =>
            {
                // Current user only — a URL like snapshot?dest= writes files.
                var security = new PipeSecurity();
                security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User,
                    PipeAccessRights.FullControl, AccessControlType.Allow));
                while (true)
                {
                    try
                    {
                        using (var server = new NamedPipeServerStream(pipeName, PipeDirection.In, 1,
                                   PipeTransmissionMode.Byte, PipeOptions.None, 4096, 4096, security))
                        {
                            server.WaitForConnection();
                            using (var r = new StreamReader(server))
                            {
                                var line = r.ReadLine();
                                if (!string.IsNullOrWhiteSpace(line))
                                    app.Dispatcher.BeginInvoke(new Action(() => tray.HandleUrl(line.Trim())));
                            }
                        }
                    }
                    catch (Exception e)
                    {
                        Log.Write($"pipe server: {e.Message}");
                        Thread.Sleep(1000);
                    }
                }
            }) { IsBackground = true, Name = "ipc" };
            t.Start();
        }
    }
}
