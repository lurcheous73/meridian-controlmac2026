using System;
using System.IO;
using System.Text;

internal static class FlacMetadataTests {
    static byte[] Fixture(string[] tags) {
        using (var s = new MemoryStream()) using (var w = new BinaryWriter(s)) {
            w.Write(Encoding.ASCII.GetBytes("fLaC")); w.Write(new byte[] {0,0,0,34});
            byte[] info = new byte[34];
            ulong packed = ((ulong)44100 << 44) | ((ulong)1 << 41) | ((ulong)23 << 36) | 88200;
            for (int i=17;i>=10;--i) {info[i]=(byte)packed;packed >>= 8;}
            w.Write(info);
            using (var comments = new MemoryStream()) using (var c = new BinaryWriter(comments)) {
                c.Write(0); c.Write(tags.Length);
                foreach (var tag in tags) { var b=Encoding.UTF8.GetBytes(tag);c.Write(b.Length);c.Write(b); }
                var block=comments.ToArray();w.Write(new byte[] {132,(byte)(block.Length>>16),(byte)(block.Length>>8),(byte)block.Length});w.Write(block);
            }
            return s.ToArray();
        }
    }
    static FlacMetadata Load(byte[] bytes) {
        string p=Path.GetTempFileName();
        try {File.WriteAllBytes(p,bytes);return FlacMetadata.Load(p);} finally {File.Delete(p);}
    }
    static void Reject(byte[] bytes) {
        try {Load(bytes);} catch (InvalidDataException) {return;} catch (IOException) {return;} catch (DecoderFallbackException) {return;}
        throw new Exception("Malformed FLAC accepted.");
    }
    public static int Main() {
        var good=Fixture(new[] {"TITLE=A=B", "ARTIST=Test", "ALBUM=Unicode — EP", "TRACKNUMBER=1"});
        var m=Load(good);
        if(m.Rate!=44100 || m.Bits!=24 || m.Channels!=2 || m.Samples!=88200 || m.Get("lengthms")!="2000" || m.Get("title")!="A=B") throw new Exception("Valid FLAC parsed incorrectly.");
        Reject(new byte[0]);
        var bad=(byte[])good.Clone();bad[0]=0;Reject(bad);
        bad=new byte[good.Length-1];Array.Copy(good,bad,bad.Length);Reject(bad);
        Reject(Fixture(new[]{"missing equals"}));
        bad=(byte[])good.Clone();bad[4]=127;Reject(bad);
        bad=(byte[])good.Clone();for(int i=22;i<26;++i)bad[i]=0; // zero sample count, keeping rate/channels
        bad[21]&=240;Reject(bad);
        bad=(byte[])good.Clone();bad[46]=255;bad[47]=255;bad[48]=255;bad[49]=127;Reject(bad);
        Console.WriteLine("FLAC_METADATA_TESTS_PASSED (8 cases)");return 0;
    }
}

