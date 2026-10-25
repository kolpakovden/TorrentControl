using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

// Read-only bencode decoder. Byte strings remain bytes (including binary info hashes).
public sealed class TorrentMetadata {
    byte[] data; int pos; int infoStart=-1, infoEnd=-1;
    TorrentMetadata(byte[] bytes) { data = bytes; }
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
                string name=Encoding.UTF8.GetString(key); int begin=pos;
                dict.Add(name, Read(depth+1));
                if (depth==0 && name=="info") { infoStart=begin; infoEnd=pos; }
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
    static string Component(object value) {
        var raw=value as byte[];
        if(raw==null) throw new FormatException("Path type");
        string s=new UTF8Encoding(false,true).GetString(raw);
        if(s.Length==0 || s.Length>180 || s=="." || s==".." || s.EndsWith(".") || s.EndsWith(" ")) throw new FormatException("Unsafe component");
        foreach(char c in s) if(c<32 || "<>:\"/\\|?*".IndexOf(c)>=0) throw new FormatException("Unsafe component");
        string stem=s.Split('.')[0].ToUpperInvariant();
        if(System.Text.RegularExpressions.Regex.IsMatch(stem,@"^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$")) throw new FormatException("Device path");
        return s;
    }
    static void NoLink(Dictionary<string,object> d) {
        if(d.ContainsKey("symlink path")) throw new FormatException("Symlink");
        if(d.ContainsKey("attr") && Encoding.ASCII.GetString((byte[])d["attr"]).Contains("l")) throw new FormatException("Symlink");
    }
    static string Name(Dictionary<string,object> d) {
        string name=Component(d["name"]);
        if(d.ContainsKey("name.utf-8") && name!=Component(d["name.utf-8"])) throw new FormatException("Ambiguous name encoding");
        return name;
    }
    static void NoExecutable(string path) {
        string ext=Path.GetExtension(path).ToLowerInvariant();
        if(Array.IndexOf(new[]{".exe",".com",".bat",".cmd",".ps1",".vbs",".js",".jse",".vbe",".msi",".scr",".lnk",".url",".hta",".reg",".dll"},ext)>=0) throw new FormatException("Executable in movie torrent");
    }
    static void ValidatePaths(Dictionary<string,object> info) {
        NoLink(info); string root=Name(info);
        if(!info.ContainsKey("files")) { NoExecutable(root); return; }
        var files=(List<object>)info["files"];
        if(files.Count==0 || files.Count>10000) throw new FormatException("File count");
        var paths=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(var item in files) {
            var f=(Dictionary<string,object>)item; NoLink(f);
            string chosen=null;
            foreach(string key in new[]{"path","path.utf-8"}) {
                if(!f.ContainsKey(key)) continue;
                var parts=(List<object>)f[key]; if(parts.Count==0 || parts.Count>16) throw new FormatException("Path depth");
                string relative=root;
                foreach(var part in parts) relative+="\\"+Component(part);
                if(relative.Length>190) throw new FormatException("Path length");
                NoExecutable(relative);
                if(chosen!=null && chosen!=relative) throw new FormatException("Ambiguous path encoding");
                chosen=relative;
            }
            if(chosen==null || !paths.Add(chosen)) throw new FormatException("Duplicate or missing path");
        }
        foreach(string path in paths) {
            string parent=Path.GetDirectoryName(path);
            while(!String.IsNullOrEmpty(parent)) {if(paths.Contains(parent)) throw new FormatException("File-directory collision"); parent=Path.GetDirectoryName(parent);}
        }
    }
    public static long Verify(string path, string expectedHash) {
        var fi=new FileInfo(path);
        if (fi.Length>4000000) throw new FormatException("Metadata too large");
        byte[] raw=File.ReadAllBytes(path);
        var parser=new TorrentMetadata(raw);
        var top=parser.Read(0) as Dictionary<string,object>;
        if(top==null || parser.pos!=raw.Length || parser.infoStart<0) throw new FormatException("Invalid torrent");
        using(var sha=System.Security.Cryptography.SHA1.Create()) {
            string hash=BitConverter.ToString(sha.ComputeHash(raw,parser.infoStart,parser.infoEnd-parser.infoStart)).Replace("-", "");
            if(!String.Equals(hash,expectedHash,StringComparison.OrdinalIgnoreCase)) throw new FormatException("Infohash mismatch");
        }
        var info=top["info"] as Dictionary<string,object>;
        if(info==null) throw new FormatException("Invalid info");
        ValidatePaths(info);
        long size=0;
        if(info.ContainsKey("files")) {
            foreach(var item in (List<object>)info["files"]) {
                long length=(long)((Dictionary<string,object>)item)["length"];
                if(length<0) throw new FormatException("Negative size");
                size=checked(size+length);
            }
        } else { size=(long)info["length"]; if(size<0) throw new FormatException("Negative size"); }
        return size;
    }
    public static void Sanitize(string path, string expectedHash) {
        Verify(path,expectedHash);
        byte[] raw=File.ReadAllBytes(path); var parser=new TorrentMetadata(raw); parser.Read(0);
        // Top-level URLs are outside the infohash. Keep only verified info and the known public tracker.
        string tracker="http://bt.t-ru.org/ann?magnet";
        byte[] head=Encoding.ASCII.GetBytes("d8:announce"+tracker.Length+":"+tracker+"4:info");
        using(var stream=new MemoryStream()) {
            stream.Write(head,0,head.Length);
            stream.Write(raw,parser.infoStart,parser.infoEnd-parser.infoStart);
            stream.WriteByte((byte)'e');
            File.WriteAllBytes(path,stream.ToArray());
        }
    }
}
