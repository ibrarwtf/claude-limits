using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;

using static ClaudeLimits.Logic;

namespace ClaudeLimits
{
    /// In-place update from a GitHub release zip — the Windows counterpart of
    /// `brew upgrade --cask`. Windows lets you rename a running exe (but not
    /// overwrite it), so: rename self to .old, drop the new exe in place, launch
    /// it, quit. The new process deletes the .old on startup.
    public static class SelfUpdate
    {
        public const string AfterUpdateFlag = "--after-update";
        static string OldPath => Platform.ExePath + ".old";

        /// Download, verify and swap in the release's exe. Throws on any failure,
        /// after restoring the original exe if the swap got that far.
        public static async Task InstallAsync(GitHubRelease release)
        {
            var asset = WindowsAsset(release) ?? throw new Exception("release has no Windows zip");
            var work = Path.Combine(Path.GetTempPath(), "claude-limits-update");
            if (Directory.Exists(work)) Directory.Delete(work, true);
            Directory.CreateDirectory(work);
            var zipPath = Path.Combine(work, asset.Name);

            var bytes = await Api.Http.GetByteArrayAsync(asset.BrowserDownloadUrl).ConfigureAwait(false);
            if (asset.Digest != null && asset.Digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
            {
                string actual;
                using (var sha = SHA256.Create())
                    actual = string.Concat(sha.ComputeHash(bytes).Select(b => b.ToString("x2")));
                if (!string.Equals(actual, asset.Digest.Substring(7), StringComparison.OrdinalIgnoreCase))
                    throw new Exception("downloaded zip failed its sha256 check");
            }
            File.WriteAllBytes(zipPath, bytes);

            var extractDir = Path.Combine(work, "x");
            ZipFile.ExtractToDirectory(zipPath, extractDir);
            var newExe = Directory.GetFiles(extractDir, Platform.Name + ".exe", SearchOption.AllDirectories).FirstOrDefault()
                         ?? throw new Exception("zip doesn't contain claude-limits.exe");

            var exe = Platform.ExePath;
            if (File.Exists(OldPath)) File.Delete(OldPath);
            File.Move(exe, OldPath);
            try { File.Copy(newExe, exe); }
            catch
            {
                File.Move(OldPath, exe);
                throw;
            }
            Log.Write($"self-update: installed {release.TagName}");
        }

        public static void Relaunch()
        {
            Process.Start(new ProcessStartInfo(Platform.ExePath, AfterUpdateFlag) { UseShellExecute = false });
        }

        public static void CleanupOldExe()
        {
            try { if (File.Exists(OldPath)) File.Delete(OldPath); } catch { }
        }
    }
}
