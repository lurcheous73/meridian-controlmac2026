// Verify only the newly created album, and remove unrelated lookup enrichment
// when the Core matched a different release. Never address an existing album.
using System;
using System.Linq;
using System.Threading;
using Sooloos.Broker;
using Sooloos.Msg.Music;

internal static class ImportVerification {
    public static IMessage Request(Connection connection, IMessage request) {
        IMessage response = null;
        var done = new ManualResetEvent(false);
        connection.Message.SendRequest(request, delegate(IMessage m, bool final) { response = m; if (final) done.Set(); });
        if (!done.WaitOne(15000)) throw new TimeoutException("Core verification request timed out.");
        return response;
    }
    static void Edit(Connection c, IMessage request) {
        var response = Request(c, request);
        if (!(response is Sooloos.Msg.Common.SuccessResponse)) throw new InvalidOperationException("Metadata correction failed: " + response);
    }
    public static void Verify(Connection c, Sooid id, string source, bool removeUnrelatedLookup) {
        var tags = FlacMetadata.Load(source);
        var a = Request(c, new GetAlbumRequest { AlbumId = id }) as Album;
        if (a == null || a.AlbumId != id || a.AlbumName != tags.Get("ALBUM") || a.ArtistName != tags.Get("ARTIST") ||
            a.Tracks.Count != 1 || a.Tracks[0].TrackName != tags.Get("TITLE") ||
            a.Tracks[0].FileInfo.FileSize != new System.IO.FileInfo(source).Length)
            throw new InvalidOperationException("Imported album does not match the approved source.");
        if (removeUnrelatedLookup) {
            Edit(c, new AlbumEditLabelsRequest { AlbumIds = new[] {id}, RemoveLabels = a.Labels,
                AddLabels = tags.Get("LABEL").Length == 0 ? new string[0] : new[] {tags.Get("LABEL")} });
            Edit(c, new AlbumEditStylesRequest { AlbumOrGroupIds = new[] {id}, RemoveStyles = a.Styles.Select(s => s.Style).ToArray(),
                AddStyles = tags.Get("GENRE").Length == 0 ? new string[0] : new[] {tags.Get("GENRE")} });
            Edit(c, new AlbumEditCreditsRequest { AlbumOrGroupIds = new[] {id}, RemoveCredits = a.Credits,
                AddCredits = tags.Get("COMPOSER").Length == 0 ? new Credit[0] : new[] {new Credit { Role = "composer", Name = tags.Get("COMPOSER") }} });
            Edit(c, new AlbumEditMoodsRequest { AlbumOrGroupIds = new[] {id}, RemoveMoods = a.Moods,
                AddMoods = tags.Get("MOOD").Length == 0 ? new string[0] : new[] {tags.Get("MOOD")} });
            Edit(c, new AlbumEditReviewRequest { AlbumIds = new[] {id}, Review = "" });
        }
        a = Request(c, new GetAlbumRequest { AlbumId = id }) as Album;
        if (a == null || a.AlbumName != tags.Get("ALBUM") || a.ArtistName != tags.Get("ARTIST") ||
            a.Tracks.Count != 1 || a.Tracks[0].TrackName != tags.Get("TITLE")) throw new InvalidOperationException("Final metadata verification failed.");
        if (System.IO.File.Exists(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(source), "cover.jpg")) && !a.HasRealCover)
            throw new InvalidOperationException("Imported cover missing.");
        if (removeUnrelatedLookup && ((tags.Get("LABEL").Length == 0 && a.Labels.Count != 0) ||
            (tags.Get("GENRE").Length == 0 && a.Styles.Count != 0) || (tags.Get("COMPOSER").Length == 0 && a.Credits.Count != 0)))
            throw new InvalidOperationException("Unrelated lookup metadata remains.");
        Console.WriteLine("VERIFIED LIBRARY ENTRY: " + a.ArtistName + " / " + a.AlbumName + " / " + a.Tracks[0].TrackName);
        Console.WriteLine("Album ID: " + id + "; track ID: " + a.Tracks[0].TrackId);
        Console.WriteLine("Cover: " + a.CoverUrl);
    }
}
