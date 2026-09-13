#!/usr/bin/env python3
"""Builds a small, made-up music library for developing Discodrome without a real server.

    python3 Tools/make_fixture_library.py OUTPUT_DIR

Every artist, album and lyric here is invented. The audio is short tone melodies, encoded with
macOS's afconvert as FLAC (16/44.1, 24/48, 24/96, 24/192), ALAC and AAC so the app meets the same
mix of formats a real library has. Tracks of an album continue each other's melody, so a gap at
a track change is audible. Serve the result with Tools/mock_navidrome.py.
"""
import hashlib, json, math, os, struct, subprocess, sys, zlib
from datetime import datetime, timedelta, timezone

ALBUMS = [
    ("Glass Rivers", "Northbound", 2021, "Indie", "flac", 96000, 24,
     ["Tide", "Harbour Lights", "Undertow", "Lanterns", "Glasswork", "North Star"], (0.16, 0.42, 0.62)),
    ("Marisol Vey", "Paper Lanterns", 2019, "Singer-Songwriter", "flac", 44100, 16,
     ["Small Hours", "Paper Lanterns", "Orchard", "The Long Way Home", "Fieldnotes", "Linen", "Candlewax"], (0.86, 0.55, 0.30)),
    ("The Quiet Orbit", "Satellite Hymns", 2023, "Electronic", "aac", 44100, 16,
     ["Launch Window", "Perigee", "Signal Lost", "Satellite Hymn", "Re-entry", "Afterburn"], (0.20, 0.18, 0.45)),
    ("Hanna Okafor", "Salt & Ember", 2020, "Soul", "flac", 48000, 24,
     ["Ember", "Salt Water", "Honey, Slowly", "Kindling", "Morning Coal"], (0.72, 0.24, 0.20)),
    ("Lumen Park", "Night Transit", 2022, "Synthpop", "alac", 44100, 16,
     ["Last Train", "Neon Platform", "Transit", "Signal Box", "Night Bus", "Terminal"], (0.55, 0.20, 0.60)),
    ("Ensemble Aurelia", "Winter Études", 2018, "Classical", "flac", 192000, 24,
     ["Étude No. 1: Frost", "Étude No. 2: Still Water", "Étude No. 3: Snowfall", "Étude No. 4: Thaw"], (0.62, 0.70, 0.78)),
    ("Tomas Brandt", "Low Tide Radio", 2017, "Folk", "aac", 44100, 16,
     ["Driftwood", "Low Tide Radio", "Gulls", "Weatherman", "Shoreline"], (0.35, 0.50, 0.40)),
    ("Velvet Static", "Afterglow", 2024, "Shoegaze", "flac", 44100, 16,
     ["Afterglow", "Haze", "Sleepwalker", "Static Bloom", "Cathode", "Fade Out"], (0.85, 0.40, 0.55)),
]

LYRICS = {
    ("Glass Rivers", "Tide"): [
        (0.0, "The water keeps the time tonight"), (4.0, "It counts the stones along the shore"),
        (8.5, "I follow every silver line"), (13.0, "Back to where we were before"),
        (18.0, ""), (19.5, "And the tide comes in"), (23.0, "And the tide goes out"),
        (27.0, "Carry me somewhere I've never been"),
    ],
    ("Marisol Vey", "Small Hours"): [
        (0.5, "In the small hours the kettle sings"), (5.0, "The radio hums of other things"),
        (10.0, "I write your name on the window glass"), (15.0, "And watch the morning let it pass"),
    ],
}

NOTE_PERIODS = [100, 89, 79, 75, 67, 59, 53, 50]  # samples per period at 44.1 kHz ≈ 441–882 Hz

def write_wav(path, rate, bits, seconds, seed):
    """A melody of whole-period notes, so every note starts and ends on a zero crossing."""
    scale = rate / 44100
    frames_per_note = int(rate * 0.25)
    amplitude = 0.22 * (2 ** (bits - 1) - 1)
    data = bytearray()
    note = seed
    total = int(rate * seconds)
    while len(data) // (2 * bits // 8) < total:
        period = max(8, int(round(NOTE_PERIODS[note % len(NOTE_PERIODS)] * scale)))
        cycle = bytearray()
        for i in range(period):
            value = int(amplitude * math.sin(2 * math.pi * i / period))
            sample = value.to_bytes(bits // 8, "little", signed=True)
            cycle += sample + sample
        data += cycle * max(1, frames_per_note // period)
        note = (note * 5 + 3) % 11
    with open(path, "wb") as f:
        block = 2 * bits // 8
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * block, block, bits))
        f.write(b"data" + struct.pack("<I", len(data)) + data)
    return len(data) / block / rate

def write_png(path, base, size=500):
    r0, g0, b0 = base
    rows = bytearray()
    cx, cy = size * 0.62, size * 0.38
    for y in range(size):
        rows.append(0)
        for x in range(size):
            t = (x + y) / (2 * size)
            d = math.hypot(x - cx, y - cy) / size
            ring = 0.10 if abs(d - 0.28) < 0.012 or abs(d - 0.18) < 0.006 else 0.0
            glow = max(0.0, 0.35 - d) * 0.9
            r = min(1, r0 * (1.15 - t * 0.7) + glow + ring)
            g = min(1, g0 * (1.15 - t * 0.7) + glow * 0.8 + ring)
            b = min(1, b0 * (1.15 - t * 0.7) + glow * 0.6 + ring)
            rows += bytes((int(r * 255), int(g * 255), int(b * 255)))
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

def ident(*parts):
    return hashlib.md5("|".join(parts).encode()).hexdigest()[:16]

def main():
    out = sys.argv[1]
    os.makedirs(os.path.join(out, "files"), exist_ok=True)
    os.makedirs(os.path.join(out, "covers"), exist_ok=True)
    library = {"artists": {}, "albums": [], "songs": [], "playlists": []}
    created = datetime(2025, 3, 1, tzinfo=timezone.utc)

    for index, (artist, album, year, genre, codec, rate, bits, titles, color) in enumerate(ALBUMS):
        artist_id, album_id = ident("artist", artist), ident("album", artist, album)
        library["artists"][artist_id] = artist
        write_png(os.path.join(out, "covers", f"{album_id}.png"), color)
        songs = []
        for number, title in enumerate(titles, start=1):
            song_id = ident("song", artist, album, title)
            suffix = {"flac": "flac", "aac": "m4a", "alac": "m4a"}[codec]
            wav = os.path.join(out, "files", f"{song_id}.wav")
            dest = os.path.join(out, "files", f"{song_id}.{suffix}")
            seconds = write_wav(wav, rate, bits, 22 + (number * 7) % 17, seed=index * 3 + number)
            args = {"flac": ["-f", "flac", "-d", "flac"], "aac": ["-f", "m4af", "-d", "aac", "-b", "256000"], "alac": ["-f", "m4af", "-d", "alac"]}[codec]
            subprocess.run(["afconvert", *args, wav, dest], check=True)
            os.remove(wav)
            size = os.path.getsize(dest)
            lossless = codec != "aac"
            lyric = LYRICS.get((artist, title))
            songs.append({
                "id": song_id, "parent": album_id, "isDir": False, "title": title, "album": album, "artist": artist,
                "track": number, "discNumber": 1, "year": year, "genre": genre, "coverArt": f"al-{album_id}",
                "size": size, "contentType": {"flac": "audio/flac", "aac": "audio/mp4", "alac": "audio/mp4"}[codec],
                "suffix": suffix, "duration": int(round(seconds)), "bitRate": int(size * 8 / seconds / 1000),
                "bitDepth": bits if lossless else 0, "samplingRate": rate, "channelCount": 2,
                "path": f"{artist}/{album}/{number:02d} - {title}.{suffix}", "albumId": album_id, "artistId": artist_id,
                "type": "music", "mediaType": "song", "displayAlbumArtist": artist, "playCount": (number * 3 + index) % 9,
                "created": (created + timedelta(days=index * 23)).strftime("%Y-%m-%dT%H:%M:%S.%f000Z"),
                "_file": f"files/{song_id}.{suffix}", "_lyrics": lyric,
            })
        library["songs"] += songs
        library["albums"].append({
            "id": album_id, "name": album, "artist": artist, "artistId": artist_id, "coverArt": f"al-{album_id}",
            "songCount": len(songs), "duration": sum(s["duration"] for s in songs), "year": year, "genre": genre,
            "created": (created + timedelta(days=index * 23)).strftime("%Y-%m-%dT%H:%M:%SZ"), "playCount": index * 4,
        })
        print(f"  {artist} — {album}: {len(songs)} songs ({codec} {bits}/{rate})")

    by_title = {s["title"]: s["id"] for s in library["songs"]}
    library["playlists"] = [
        {"id": "pl-late-night", "name": "Late Night Drive", "comment": "Headlights and synths",
         "songs": [by_title[t] for t in ["Last Train", "Perigee", "Neon Platform", "Haze", "Signal Lost", "Night Bus"]]},
        {"id": "pl-sunday", "name": "Sunday Morning",
         "songs": [by_title[t] for t in ["Small Hours", "Driftwood", "Tide", "Orchard", "Honey, Slowly"]]},
    ]
    with open(os.path.join(out, "library.json"), "w") as f:
        json.dump(library, f, indent=1)
    print(f"wrote {len(library['songs'])} songs to {out}")

if __name__ == "__main__":
    main()
