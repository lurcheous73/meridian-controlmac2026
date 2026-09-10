using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;

internal static class IPNPConfigTool {
    const int Port = 9001;
    static readonly IPAddress Group = IPAddress.Parse("239.255.255.249");
    static readonly Guid C15Config = Guid.Parse("8160A503-3AA9-457E-A6F8-36E5BBD57A24");
    static readonly Guid BrokerDevice = Guid.Parse("98F10667-64D4-424F-9EA8-E0B654673C3C");

    sealed class DeviceInfo {
        public IPEndPoint Endpoint;
        public byte[] Serial;
        public Guid DeviceId;
        public string Model = "";
        public Dictionary<string,string> Values = new Dictionary<string,string>();
    }

    static ushort U16(byte[] b, int o) { return (ushort)(b[o] | (b[o + 1] << 8)); }
    static void W16(Stream s, int v) { s.WriteByte((byte)(v & 255)); s.WriteByte((byte)((v >> 8) & 255)); }
    static byte[] GuidBytes(Guid g) { return g.ToByteArray(); }
    static Guid ReadGuid(byte[] b, int o) { var x = new byte[16]; Buffer.BlockCopy(b,o,x,0,16); return new Guid(x); }
    static byte[] SerialBytes(string hex) {
        hex = (hex ?? "").Replace(":", "").Replace("-", "").Trim();
        if (hex.Length > 32 || (hex.Length & 1) != 0) throw new ArgumentException("Invalid Meridian serial.");
        var r = new byte[16]; for (int i=0;i<hex.Length/2;i++) r[i] = Convert.ToByte(hex.Substring(i*2,2),16); return r;
    }
    static string SerialHex(byte[] b) { return BitConverter.ToString(b.Take(6).ToArray()).Replace("-", "").ToLowerInvariant(); }
    static Dictionary<string,string> ReadPairs(byte[] b, int start) {
        var d = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase); int o=start; if (o+2>b.Length) return d;
        int n=U16(b,o); o+=2;
        for(int i=0;i<n && o<b.Length;i++) {
            int nl=b[o++]; if(o+nl+2>b.Length) break; string k=Encoding.UTF8.GetString(b,o,nl); o+=nl;
            int vl=U16(b,o); o+=2; if(o+vl>b.Length) break; string v=Encoding.UTF8.GetString(b,o,vl); o+=vl; d[k]=v;
        }
        return d;
    }
    static IEnumerable<Tuple<ushort,int,int>> Items(byte[] b) {
        int o=88; if(b.Length<88) yield break; int count=U16(b,6);
        for(int i=0;i<count && o+4<=b.Length;i++) { int len=U16(b,o); ushort type=U16(b,o+2); if(len<4 || o+len>b.Length) yield break; yield return Tuple.Create(type,o+4,len-4); o+=len; }
    }
    static IPAddress LocalAddress(string host) {
        using(var s=new Socket(AddressFamily.InterNetwork,SocketType.Dgram,ProtocolType.Udp)) { s.Connect(host,9); return ((IPEndPoint)s.LocalEndPoint).Address; }
    }
    static UdpClient Open(string host) {
        var u=new UdpClient(); u.Client.SetSocketOption(SocketOptionLevel.Socket,SocketOptionName.ReuseAddress,true); u.ExclusiveAddressUse=false;
        u.Client.Bind(new IPEndPoint(IPAddress.Any,Port));
        var local=LocalAddress(host); u.JoinMulticastGroup(Group,local); u.Client.ReceiveTimeout=750; return u;
    }
    static DeviceInfo Discover(string host, string serial, int seconds=6) {
        byte[] want=string.IsNullOrEmpty(serial)?null:SerialBytes(serial); var until=DateTime.UtcNow.AddSeconds(seconds);
        using(var u=Open(host)) while(DateTime.UtcNow<until) {
            try { IPEndPoint ep=null; var b=u.Receive(ref ep); if(ep.Address.ToString()!=host || b.Length<88 || Encoding.ASCII.GetString(b,0,4)!="IPNP") continue;
                var srcSerial=new byte[16]; Buffer.BlockCopy(b,24,srcSerial,0,16); if(want!=null && !srcSerial.SequenceEqual(want)) continue;
                Guid src=ReadGuid(b,56); foreach(var it in Items(b)) if(it.Item1==3) { var p=ReadPairs(b,it.Item2); string ct; if(p.TryGetValue("configuration_type",out ct) && Guid.Parse(ct)==C15Config) {
                    string model; p.TryGetValue("model",out model); return new DeviceInfo{Endpoint=ep,Serial=srcSerial,DeviceId=src,Model=model??"ControlFifteen",Values=p};
                }}
            } catch(SocketException e) { if(e.SocketErrorCode!=SocketError.TimedOut) throw; }
        }
        throw new TimeoutException("No ControlFifteen configuration endpoint was discovered on the local network.");
    }
    static byte[] QueryItem(params string[] names) {
        using(var p=new MemoryStream()) { W16(p,names.Length); foreach(var n in names){var x=Encoding.UTF8.GetBytes(n); p.WriteByte((byte)x.Length); p.Write(x,0,x.Length);} return Item(2,p.ToArray()); }
    }
    static byte[] CommandItem(string command, IDictionary<string,string> pars) {
        using(var p=new MemoryStream()) { var c=Encoding.UTF8.GetBytes(command); p.WriteByte((byte)c.Length); p.Write(c,0,c.Length); W16(p,pars.Count);
            foreach(var kv in pars){var k=Encoding.UTF8.GetBytes(kv.Key); var v=Encoding.UTF8.GetBytes(kv.Value??""); p.WriteByte((byte)k.Length); p.Write(k,0,k.Length); W16(p,v.Length); p.Write(v,0,v.Length);} return Item(4,p.ToArray()); }
    }
    static byte[] Item(int type, byte[] payload) { using(var s=new MemoryStream()){W16(s,payload.Length+4);W16(s,type);s.Write(payload,0,payload.Length);return s.ToArray();} }
    static byte[] Packet(Guid tx, byte[] srcSerial, byte[] dstSerial, Guid srcDev, Guid dstDev, byte flags, params byte[][] items) {
        using(var s=new MemoryStream()){var sig=Encoding.ASCII.GetBytes("IPNP");s.Write(sig,0,4);s.WriteByte(1);s.WriteByte(flags);W16(s,items.Length);
            foreach(var x in new[]{GuidBytes(tx),srcSerial,dstSerial,GuidBytes(srcDev),GuidBytes(dstDev)})s.Write(x,0,16); foreach(var x in items)s.Write(x,0,x.Length); return s.ToArray(); }
    }
    static Dictionary<string,string> Exchange(string host, DeviceInfo d, byte[] item, int timeoutMs=4000) {
        var tx=Guid.NewGuid(); var srcSerial=Guid.NewGuid().ToByteArray(); var srcDev=Guid.NewGuid(); var packet=Packet(tx,srcSerial,d.Serial,srcDev,d.DeviceId,2,item);
        using(var u=Open(host)){u.Send(packet,packet.Length,new IPEndPoint(Group,Port)); var until=DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while(DateTime.UtcNow<until){try{IPEndPoint ep=null;var b=u.Receive(ref ep);if(ep.Address.ToString()!=host||b.Length<88||Encoding.ASCII.GetString(b,0,4)!="IPNP"||ReadGuid(b,8)!=tx)continue;
                foreach(var it in Items(b)) if(it.Item1==3||it.Item1==5) return ReadPairs(b,it.Item2); return new Dictionary<string,string>();
            }catch(SocketException e){if(e.SocketErrorCode!=SocketError.TimedOut)throw;}}
        }
        throw new TimeoutException("The Meridian device did not acknowledge the configuration request.");
    }
    static IPAddress IPv4(string s, string name) { IPAddress a; if(!IPAddress.TryParse(s,out a)||a.AddressFamily!=AddressFamily.InterNetwork) throw new ArgumentException(name+" is not a valid IPv4 address."); if(s=="0.0.0.0"||s=="255.255.255.255") throw new ArgumentException(name+" cannot be "+s+"."); return a; }
    static uint V4(IPAddress a){var b=a.GetAddressBytes();return ((uint)b[0]<<24)|((uint)b[1]<<16)|((uint)b[2]<<8)|b[3];}
    static void ValidateStatic(string ip,string mask,string gw,string dns){var a=IPv4(ip,"IP address");var m=IPv4(mask,"Netmask");var g=IPv4(gw,"Gateway");IPv4(dns,"DNS");uint mv=V4(m);uint inv=~mv;if((inv&(inv+1))!=0)throw new ArgumentException("Netmask is not contiguous.");if((V4(a)&mv)!=(V4(g)&mv))throw new ArgumentException("IP address and gateway are not on the same subnet.");}
    static void Status(string host,string serial){var d=Discover(host,serial);var p=Exchange(host,d,QueryItem("ip","dns","dhcp","gateway","netmask","runbroker","runnas"));
        Console.WriteLine("CMIPNP\t"+d.Endpoint.Address+"\t"+SerialHex(d.Serial)+"\t"+d.DeviceId+"\t"+d.Model);
        foreach(var k in new[]{"dhcp","ip","netmask","gateway","dns","runbroker","runnas"}){string v;p.TryGetValue(k,out v);Console.WriteLine("CMNET\t"+k+"\t"+(v??""));}}
    static void Apply(string host,string serial,string[] args){var d=Discover(host,serial);string cmd;var p=new Dictionary<string,string>();
        if(args.Length==4&&args[3].Equals("dhcp",StringComparison.OrdinalIgnoreCase))cmd="set_dhcp";
        else if(args.Length==8&&args[3].Equals("static",StringComparison.OrdinalIgnoreCase)){ValidateStatic(args[4],args[5],args[6],args[7]);cmd="set_static_ip";p["ip"]=args[4];p["netmask"]=args[5];p["gateway"]=args[6];p["dns"]=args[7];}
        else throw new ArgumentException("Use apply <host> <serial> dhcp OR apply <host> <serial> static <ip> <netmask> <gateway> <dns>.");
        var r=Exchange(host,d,CommandItem(cmd,p),6000);Console.WriteLine("CMAPPLIED\t"+cmd);foreach(var kv in r)Console.WriteLine("CMRESULT\t"+kv.Key+"\t"+kv.Value);
    }
    static DeviceInfo Broker(string host) { return new DeviceInfo { Endpoint = new IPEndPoint(IPAddress.Parse(host), Port), Serial = new byte[16], DeviceId = BrokerDevice, Model = "Broker" }; }
    static void RegistrationStatus(string host) {
        var r=Exchange(host,Broker(host),QueryItem("user_registration"),5000);
        foreach(var k in new[]{"is_registered","fname","lname","email","phone","street1","street2","city","state","zip","country"}) { string v; r.TryGetValue(k,out v); Console.WriteLine("CMREG\t"+k+"\t"+(v??"")); }
    }
    static void RegistrationApply(string host,string[] args) {
        if(args.Length!=13) throw new ArgumentException("registration-apply requires 10 registration fields.");
        string[] keys={"fname","lname","email","phone","street1","street2","city","state","zip","country"}; var p=new Dictionary<string,string>();
        for(int i=0;i<keys.Length;i++) p[keys[i]]=args[i+3]??"";
        var r=Exchange(host,Broker(host),CommandItem("register_user",p),7000); Console.WriteLine("CMREGOK\tregister_user"); foreach(var kv in r) Console.WriteLine("CMRESULT\t"+kv.Key+"\t"+kv.Value);
    }
    static void RegistrationClear(string host) { var r=Exchange(host,Broker(host),CommandItem("clear_registration",new Dictionary<string,string>()),5000); Console.WriteLine("CMREGOK\tclear_registration"); }
    public static int Main(string[] args){try{if(args.Length<2)return 2;string mode=args[0].ToLowerInvariant();
        if(mode=="status"&&args.Length==3)Status(args[1],args[2]);
        else if(mode=="apply"&&args.Length>=4)Apply(args[1],args[2],args);
        else if(mode=="registration-status"&&args.Length==2)RegistrationStatus(args[1]);
        else if(mode=="registration-apply")RegistrationApply(args[1],args);
        else if(mode=="registration-clear"&&args.Length==2)RegistrationClear(args[1]);
        else return 2; return 0;}catch(Exception e){Console.Error.WriteLine("CMERROR\t"+e.Message);return 1;}}
}
