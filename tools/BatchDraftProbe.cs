using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Threading;
using System.Collections.Generic;
using Sooloos.Broker;
using Sooloos.Msg.Import;
using Sooloos.Msg.AuxDevice;

internal static class BatchDraftProbe {
    public static int Main(string[] args) {
        if (args.Length < 4 || args[0] != "--create-draft") {
            Console.Error.WriteLine("Usage: BatchDraftProbe --create-draft CORE_HOST FILE..."); return 2;
        }
        string host = args[1]; var files = args.Skip(2).Select(Path.GetFullPath).ToArray();
        var metadata = files.Select(FlacMetadata.Load).ToArray();
        string album = metadata[0].Get("ALBUM"), artist = metadata[0].Get("ARTIST");
        if (album.Length == 0 || artist.Length == 0) throw new InvalidDataException("Album/artist tags required.");
        if (metadata.Any(m => m.Get("ALBUM") != album || m.Get("ARTIST") != artist))
            throw new InvalidDataException("Files do not belong to one tagged album.");
        var encoded = files.Select(f => Convert.ToBase64String(Encoding.UTF8.GetBytes(f))).ToArray();
        BrokerProbe.Initialize(); var connection = new Connection(host); var device = new Sooid(24, Guid.NewGuid());
        var completed = new ManualResetEvent(false); Guid project = Guid.Empty; bool owned = false, grouped = false;
        int connected = 0, registered = 0;
        connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus status) {
            if (status.ToString() != "Connected" || Interlocked.Exchange(ref connected, 1) != 0) return;
            connection.Message.SendRequest(new AuxDeviceConnectRequest {
                Info = new AuxDeviceInfo { DeviceId = device, Description = "ControlMac2026 batch draft test",
                    Capabilities = new[] { Capabilities.Import }, ConfigurationType = ConfigurationType.Static },
                PingSeconds = 20
            }, delegate(IMessage response, bool final) {
                if (!(response is AuxDeviceConnectResponse) || Interlocked.Exchange(ref registered, 1) != 0) return;
                var infos = new List<MusicFileInfo>();
                for (int i = 0; i < files.Length; ++i) {
                    var fi = new System.IO.FileInfo(files[i]);
                    infos.Add(new MusicFileInfo {
                        FileInfo = new Sooloos.Msg.Import.FileInfo { MediaPath = encoded[i], OriginalPath = files[i], FileSize = fi.Length, IsDirectory = false },
                        ExtractedTags = metadata[i].Tags, CoverUrls = new string[0]
                    });
                }
                connection.Message.SendRequest(new CreateLooseFilesMusicProjectRequest {
                    ImportDeviceId = device,
                    CreateOptions = new[] { CreateOption.AutoSkipDuplicates, CreateOption.PreferUserMetadata, CreateOption.Private },
                    MusicFiles = infos
                }, delegate(IMessage message, bool last) {
                    Console.WriteLine("CREATE " + message.GetType().Name + " " + message);
                    var created = message as ProjectCreatedResponse;
                    if (created != null) {
                        project = created.ProjectId; owned = !created.ProjectAlreadyExists;
                        Console.WriteLine("DRAFT " + project + " new=" + owned);
                    }
                    if (message is ProjectCreationCompletedResponse && owned) {
                        connection.Message.SendRequest(new LooseMusicFilesMakeAlbumRequest {
                            ProjectId = project, MediaPaths = encoded,
                            CreateOptions = new[] { CreateOption.AutoSkipDuplicates, CreateOption.PreferUserMetadata, CreateOption.Private }
                        }, delegate(IMessage grouping, bool end) {
                            Console.WriteLine("GROUP " + grouping.GetType().Name + " " + grouping);
                            grouped = grouping is Sooloos.Msg.Common.SuccessResponse;
                            if (end) completed.Set();
                        });
                    }
                });
            });
        };
        Timer ping = null;
        try {
            connection.Connect();
            ping = new Timer(delegate(object state) {
                if (registered != 0) connection.Message.SendRequest(new AuxDevicePingRequest { DeviceId = device });
            }, null, 5000, 5000);
            if (!completed.WaitOne(30000)) Console.Error.WriteLine("Batch draft did not finish within 30 seconds.");
            Console.WriteLine("RESULT album=" + artist + " / " + album + " files=" + files.Length + " grouped=" + grouped);
            return completed.WaitOne(0) && owned && grouped ? 0 : 1;
        } finally {
            if (ping != null) ping.Dispose();
            if (owned && project != Guid.Empty) {
                var removed = new ManualResetEvent(false);
                connection.Message.SendRequest(new ImportProjectRemoveRequest { ProjectId = project },
                    delegate(IMessage m, bool final) {
                        Console.WriteLine("REMOVE " + m.GetType().Name + " " + m);
                        if (final) removed.Set();
                    });
                if (!removed.WaitOne(5000)) Console.Error.WriteLine("Draft cleanup unconfirmed for " + project);
            }
            connection.Disconnect();
        }
    }
}
