using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.Serialization;
using System.Text;
using System.Threading.Tasks;
using static ClaudeLimits.Logic;

namespace ClaudeLimits
{
    [DataContract]
    sealed class CredentialsOAuth
    {
        [DataMember(Name = "accessToken", EmitDefaultValue = false)] public string AccessToken { get; set; }
    }

    [DataContract]
    sealed class CredentialsFile
    {
        [DataMember(Name = "claudeAiOauth", EmitDefaultValue = false)] public CredentialsOAuth ClaudeAiOauth { get; set; }
        [DataMember(Name = "accessToken", EmitDefaultValue = false)] public string AccessToken { get; set; }
    }

    public static class Token
    {
        /// Claude Code on Windows stores credentials in a plain file (no
        /// Credential Manager entry), so auto-detect is just a path walk.
        /// WSL distros are deliberately not probed: touching \\wsl.localhost\
        /// boots the WSL VM on every poll. The shell mode covers that case.
        public static IReadOnlyList<string> KnownCredentialPaths
        {
            get
            {
                var paths = new List<string>();
                var configDir = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
                if (!string.IsNullOrWhiteSpace(configDir)) paths.Add(Path.Combine(configDir, ".credentials.json"));
                paths.Add(@"~\.claude\.credentials.json");
                paths.Add(@"%APPDATA%\Claude\claude-code\.credentials.json");
                paths.Add(@"%APPDATA%\Claude\.credentials.json");
                return paths;
            }
        }

        public const string ShellCommandExample = "ssh devbox 'cat ~/.claude/.credentials.json'";

        public static string ExpandPath(string raw)
        {
            var p = (raw ?? "").Trim().Trim('"');
            if (p == "~" || p.StartsWith("~/") || p.StartsWith(@"~\"))
                p = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + p.Substring(1);
            return Environment.ExpandEnvironmentVariables(p);
        }

        public static string ExtractTokenFromText(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return null;
            try
            {
                var obj = Json.Parse<CredentialsFile>(text.Trim());
                var tok = obj?.ClaudeAiOauth?.AccessToken;
                if (!string.IsNullOrEmpty(tok)) return tok;
                if (!string.IsNullOrEmpty(obj?.AccessToken)) return obj.AccessToken;
            }
            catch { }
            return RawToken(text);
        }

        public static string LoadTokenFromFile(string rawPath)
        {
            var path = ExpandPath(rawPath);
            if (!File.Exists(path)) throw AppError.TokenNotFound();
            var text = File.ReadAllText(path, Encoding.UTF8);
            var tok = ExtractTokenFromText(text);
            if (tok != null) return tok;
            throw AppError.ParseFailed($"no accessToken in {path}");
        }

        /// Runs the command through Windows PowerShell (always present). Passed as
        /// -EncodedCommand so user quoting survives intact, and with UTF-8 console
        /// output forced — the default OEM codepage would mangle non-ASCII JSON.
        public static string RunShell(string cmd, double timeoutSeconds = 10.0)
        {
            var script = "$ProgressPreference = 'SilentlyContinue'; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; " + cmd;
            var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encoded)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            using (var p = Process.Start(psi))
            {
                // Drain both pipes concurrently with the wait — NOT after it. Reading
                // only once the process has exited deadlocks if the child writes more
                // than the pipe buffer: it blocks in write(), never exits, and we'd
                // spuriously time out.
                var outTask = Task.Run(() => p.StandardOutput.ReadToEnd());
                var errTask = Task.Run(() => p.StandardError.ReadToEnd());
                if (!p.WaitForExit((int)(timeoutSeconds * 1000)))
                {
                    // Kill the whole tree: a hung `ssh` under powershell would
                    // otherwise outlive us, leaking a process on every poll.
                    try
                    {
                        using (var k = Process.Start(new ProcessStartInfo("taskkill", $"/T /F /PID {p.Id}")
                               { UseShellExecute = false, CreateNoWindow = true }))
                            k?.WaitForExit(3000);
                    }
                    catch { }
                    try { if (!p.HasExited) p.Kill(); } catch { }
                    throw AppError.CommandFailed($"timed out after {(int)timeoutSeconds}s");
                }
                p.WaitForExit(); // flush async readers
                var output = outTask.Result;
                if (p.ExitCode != 0)
                    throw AppError.CommandFailed($"exit {p.ExitCode}: {Prefix(errTask.Result.Trim(), 200)}");
                return output;
            }
        }

        public static string LoadTokenFromShell(string cmd)
        {
            if (string.IsNullOrWhiteSpace(cmd)) throw AppError.TokenNotFound();
            var output = RunShell(cmd);
            var tok = ExtractTokenFromText(output);
            if (tok != null) return tok;
            throw AppError.ParseFailed("shell command output didn't contain a token");
        }

        /// Track which source produced the most recent token so we only log on change —
        /// keeps the log free of repetition while still recording fall-through events.
        static string lastLoggedTokenSource;
        static void LogTokenSourceOnce(string source)
        {
            if (lastLoggedTokenSource != source)
            {
                Log.Write($"claude-limits token from: {source}");
                lastLoggedTokenSource = source;
            }
        }

        public static string LoadAccessToken()
        {
            switch (Settings.Shared.TokenSource)
            {
                case TokenSource.File:
                {
                    var path = Settings.Shared.CustomFilePath;
                    if (string.IsNullOrWhiteSpace(path)) throw AppError.TokenNotFound();
                    var tok = LoadTokenFromFile(path);
                    LogTokenSourceOnce($"file {path} (custom)");
                    return tok;
                }
                case TokenSource.Shell:
                {
                    var tok = LoadTokenFromShell(Settings.Shared.CustomShellCommand);
                    LogTokenSourceOnce("shell command (custom)");
                    return tok;
                }
                default:
                    foreach (var path in KnownCredentialPaths)
                    {
                        try
                        {
                            var tok = LoadTokenFromFile(path);
                            LogTokenSourceOnce($"file {path} (auto)");
                            return tok;
                        }
                        catch (AppError) { }
                        catch (IOException) { }
                        catch (UnauthorizedAccessException) { }
                    }
                    throw AppError.TokenNotFound();
            }
        }
    }
}
