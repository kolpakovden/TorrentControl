using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

// Read-only bencode decoder. Byte strings remain bytes (including binary info hashes).
public sealed class ResumePaths {
    byte[] data; int pos;
    ResumePaths(byte[] bytes) { data = bytes; }
    byte Peek() { if (pos >= data.Length) throw new FormatException("Truncated bencode"); return data[pos]; }
    object Read(int depth) {
        if (depth > 64) throw new FormatException("Nesting limit");
        byte ch = Peek();
        if (ch == (byte)'i') {
            int start = ++pos;
            while (Peek() != (byte)'e') pos++;
            long value = long.Parse(Encoding.ASCII.GetString(data, start, pos-start), System.Globalization.CultureInfo.InvariantCulture);
            pos++; return value;
        }
        if (ch == (byte)'d') {
            pos++; var dict = new Dictionary<string,object>(StringComparer.Ordinal);
            while (Peek() != (byte)'e') {
                var key = Read(depth+1) as byte[];
                if (key == null) throw new FormatException("Invalid key");
                dict.Add(Encoding.UTF8.GetString(key), Read(depth+1));
            }
            pos++; return dict;
        }
        if (ch == (byte)'l') {
            pos++; var list = new List<object>();
            while (Peek() != (byte)'e') list.Add(Read(depth+1));
            pos++; return list;
        }
        if (ch < (byte)'0' || ch > (byte)'9') throw new FormatException("Invalid value");
        int size = 0;
        while (Peek() != (byte)':') {
            byte digit = Peek();
            if (digit < 48 || digit > 57) throw new FormatException("Invalid size");
            size = checked(size*10 + digit-48); pos++;
        }
        pos++;
        if (size > data.Length-pos) throw new FormatException("Truncated string");
        var valueBytes = new byte[size]; Buffer.BlockCopy(data,pos,valueBytes,0,size); pos+=size;
        return valueBytes;
    }
    public static Dictionary<string,string> Load(string path) {
        byte[] bytes;
        using (var stream = new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
            if (stream.Length > 134217728) throw new FormatException("File too large");
            using (var buffer = new MemoryStream()) { stream.CopyTo(buffer); bytes=buffer.ToArray(); }
        }
        var parser = new ResumePaths(bytes);
        var top = parser.Read(0) as Dictionary<string,object>;
        if (top == null || parser.pos != bytes.Length) throw new FormatException("Invalid resume root");
        var result = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        var conflicts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in top.Values) {
            var dict = entry as Dictionary<string,object>;
            if (dict == null || !dict.ContainsKey("info") || !dict.ContainsKey("path")) continue;
            var hash = dict["info"] as byte[]; var rawPath = dict["path"] as byte[];
            if (hash == null || hash.Length != 20 || rawPath == null) continue;
            string dest;
            try { dest = new UTF8Encoding(false,true).GetString(rawPath); }
            catch (DecoderFallbackException) { continue; }
            if (dest.IndexOf('\0') >= 0) continue;
            var id = BitConverter.ToString(hash).Replace("-", "");
            if (conflicts.Contains(id)) continue;
            if (result.ContainsKey(id) && !String.Equals(result[id],dest,StringComparison.OrdinalIgnoreCase)) {
                result.Remove(id); conflicts.Add(id); continue;
            }
            result[id] = dest;
        }
        return result;
    }
}
