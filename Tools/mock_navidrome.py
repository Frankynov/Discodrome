#!/usr/bin/env python3
"""A small stand-in for a Navidrome server, for developing and testing Discodrome.

    python3 Tools/make_fixture_library.py /tmp/discodrome-fixture
    python3 Tools/mock_navidrome.py /tmp/discodrome-fixture [--port 4533] [--throttle-kbs 1500]

Speaks enough of the (Open)Subsonic API for everything Discodrome does. Sign in with the
username "demo" and the password "demo" — this is a local test fixture, not a real account.
"""
import hashlib, json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
PORT = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 4533
# Limit song downloads to this many kilobytes per second, to watch progress in the app.
THROTTLE = int(sys.argv[sys.argv.index("--throttle-kbs") + 1]) if "--throttle-kbs" in sys.argv else 0
LIBRARY = json.load(open(os.path.join(ROOT, "library.json")))
SONGS = {s["id"]: s for s in LIBRARY["songs"]}
USER, PASSWORD = "demo", "demo"

def public(song):
    return {k: v for k, v in song.items() if not k.startswith("_")}

def envelope(payload=None, error=None):
    body = {"status": "failed" if error else "ok", "version": "1.16.1", "type": "navidrome",
            "serverVersion": "0.58.0 (mock)", "openSubsonic": True}
    if error:
        body["error"] = {"code": error[0], "message": error[1]}
    body.update(payload or {})
    return {"subsonic-response": body}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))

    def send_json(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_file(self, path, content_type):
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(path, "rb") as f:
            while chunk := f.read(1 << 16):
                self.wfile.write(chunk)
                if THROTTLE and content_type.startswith("audio/"):
                    time.sleep(len(chunk) / (THROTTLE * 1024))

    def do_GET(self):
        url = urlparse(self.path)
        params = {k: v for k, v in parse_qs(url.query, keep_blank_values=True).items()}
        one = lambda k, d=None: params.get(k, [d])[0]
        name = url.path.rsplit("/", 1)[-1].removesuffix(".view")

        salt, token = one("s", ""), one("t", "")
        if one("u") != USER or hashlib.md5((PASSWORD + salt).encode()).hexdigest() != token:
            return self.send_json(envelope(error=(40, "Wrong username or password")))

        albums = LIBRARY["albums"]
        if name == "ping":
            return self.send_json(envelope())
        if name == "getOpenSubsonicExtensions":
            return self.send_json(envelope({"openSubsonicExtensions": [
                {"name": "songLyrics", "versions": [1]}, {"name": "transcodeOffset", "versions": [1]}]}))
        if name == "getAlbumList2":
            size, offset = int(one("size", "10")), int(one("offset", "0"))
            ordered = sorted(albums, key=lambda a: a["created"], reverse=True) if one("type") == "newest" else sorted(albums, key=lambda a: a["name"].lower())
            return self.send_json(envelope({"albumList2": {"album": ordered[offset:offset + size]}}))
        if name == "getAlbum":
            album = next((a for a in albums if a["id"] == one("id")), None)
            if not album:
                return self.send_json(envelope(error=(70, "Album not found")))
            songs = [public(s) for s in LIBRARY["songs"] if s["albumId"] == album["id"]]
            return self.send_json(envelope({"album": {**album, "song": songs}}))
        if name == "getArtists":
            index = {}
            for artist_id, artist in LIBRARY["artists"].items():
                count = sum(1 for a in albums if a["artistId"] == artist_id)
                key = artist.removeprefix("The ")[0].upper()
                index.setdefault(key, []).append({"id": artist_id, "name": artist, "albumCount": count, "coverArt": f"ar-{artist_id}"})
            return self.send_json(envelope({"artists": {"ignoredArticles": "The", "index": [
                {"name": k, "artist": v} for k, v in sorted(index.items())]}}))
        if name == "getArtist":
            artist_id = one("id")
            return self.send_json(envelope({"artist": {"id": artist_id, "name": LIBRARY["artists"].get(artist_id, "?"),
                                                       "album": [a for a in albums if a["artistId"] == artist_id]}}))
        if name == "getSong":
            song = SONGS.get(one("id"))
            return self.send_json(envelope({"song": public(song)}) if song else envelope(error=(70, "Song not found")))
        if name == "search3":
            query = one("query", "").strip('"').lower()
            count, offset = int(one("songCount", "20")), int(one("songOffset", "0"))
            songs = [s for s in LIBRARY["songs"] if not query or query in (s["title"] + s["artist"] + s["album"]).lower()]
            found_albums = [a for a in albums if query and query in (a["name"] + a["artist"]).lower()]
            return self.send_json(envelope({"searchResult3": {
                "song": [public(s) for s in songs[offset:offset + count]],
                "album": found_albums[:int(one("albumCount", "20"))], "artist": []}}))
        if name == "getPlaylists":
            return self.send_json(envelope({"playlists": {"playlist": [
                {"id": p["id"], "name": p["name"], "comment": p.get("comment"), "owner": USER, "public": True,
                 "songCount": len(p["songs"]), "duration": sum(SONGS[i]["duration"] for i in p["songs"]),
                 "coverArt": SONGS[p["songs"][0]]["coverArt"]} for p in LIBRARY["playlists"]]}}))
        if name == "getPlaylist":
            p = next((p for p in LIBRARY["playlists"] if p["id"] == one("id")), None)
            if not p:
                return self.send_json(envelope(error=(70, "Playlist not found")))
            return self.send_json(envelope({"playlist": {"id": p["id"], "name": p["name"], "comment": p.get("comment"),
                "songCount": len(p["songs"]), "duration": sum(SONGS[i]["duration"] for i in p["songs"]),
                "entry": [public(SONGS[i]) for i in p["songs"]]}}))
        if name in ("updatePlaylist", "createPlaylist", "scrobble"):
            if name == "updatePlaylist":
                p = next((p for p in LIBRARY["playlists"] if p["id"] == one("playlistId")), None)
                if p:
                    p["songs"] += [i for i in params.get("songIdToAdd", []) if i in SONGS]
            return self.send_json(envelope())
        if name == "getLyricsBySongId":
            song = SONGS.get(one("id"))
            lines = song.get("_lyrics") if song else None
            lyrics = [{"lang": "eng", "synced": True, "offset": 0, "displayArtist": song["artist"], "displayTitle": song["title"],
                       "line": [{"start": int(t * 1000), "value": v} for t, v in lines]}] if lines else []
            return self.send_json(envelope({"lyricsList": {"structuredLyrics": lyrics}}))
        if name == "getLyrics":
            return self.send_json(envelope({"lyrics": {}}))
        if name in ("stream", "download"):
            song = SONGS.get(one("id"))
            if not song:
                return self.send_json(envelope(error=(70, "Song not found")))
            time.sleep(0.05)
            return self.send_file(os.path.join(ROOT, song["_file"]), song["contentType"])
        if name == "getCoverArt":
            cover = one("id", "")
            album_id = cover.removeprefix("al-")
            if cover.startswith("ar-"):
                album_id = next((a["id"] for a in albums if a["artistId"] == cover[3:]), "")
            path = os.path.join(ROOT, "covers", f"{album_id}.png")
            if os.path.exists(path):
                return self.send_file(path, "image/png")
            self.send_response(404)
            return self.end_headers()
        self.send_json(envelope(error=(0, f"{name} is not implemented by the mock")))

if __name__ == "__main__":
    print(f"Mock Navidrome on http://127.0.0.1:{PORT} — user demo / password demo" + (f", songs at {THROTTLE} KB/s" if THROTTLE else ""))
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
