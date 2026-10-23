using System.IO;
using System.Runtime.Serialization.Json;
using System.Text;

namespace ClaudeLimits
{
    // DataContractJsonSerializer is the JSON codec that ships in .NET Framework
    // 4.8 — System.Text.Json would be a NuGet dependency there.
    public static class Json
    {
        public static T Parse<T>(string text) where T : class
        {
            using (var ms = new MemoryStream(Encoding.UTF8.GetBytes(text)))
                return new DataContractJsonSerializer(typeof(T)).ReadObject(ms) as T;
        }

        public static T Parse<T>(byte[] data) where T : class
        {
            using (var ms = new MemoryStream(data))
                return new DataContractJsonSerializer(typeof(T)).ReadObject(ms) as T;
        }

        public static string Write<T>(T value)
        {
            using (var ms = new MemoryStream())
            {
                new DataContractJsonSerializer(typeof(T)).WriteObject(ms, value);
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        /// Write-then-replace so a crash mid-write never leaves a truncated file.
        public static void WriteFileAtomic(string path, string contents)
        {
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, contents, new UTF8Encoding(false));
            if (File.Exists(path)) File.Replace(tmp, path, null);
            else File.Move(tmp, path);
        }
    }
}
