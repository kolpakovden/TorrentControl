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
}
