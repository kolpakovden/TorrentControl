"""Fetch public metadata only; never movie payloads or account credentials."""
import base64
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


def eligible(title):
    return (re.search(r'(?i)\b(WEB[- .]?DL(?:Rip)?|BDRip)\b', title)
            and re.search(r'(?i)\b(Dub|MVO|DVO)\b|дубляж|многоголос', title)
            and not re.search(r'(?i)\b(CAM(?:Rip)?|HDCAM|HDTS|TS|TC)\b', title))


def decode_metadata(raw, expected):
    if len(raw) > 4_000_000:
        raise ValueError('metadata too large')
    pos = 0
    span = None

    def read(depth=0):
        nonlocal pos, span
        if depth > 32 or pos >= len(raw):
            raise ValueError('bounds')
        c = raw[pos:pos+1]
        if c == b'i':
            end = raw.index(b'e', pos+1)
            value = int(raw[pos+1:end]); pos = end+1
            return value
        if c in (b'l', b'd'):
            pos += 1
            value = [] if c == b'l' else {}
            while raw[pos:pos+1] != b'e':
                if c == b'l':
                    value.append(read(depth+1))
                else:
                    key = read(depth+1); begin = pos
                    if not isinstance(key, bytes) or key in value:
                        raise ValueError('dictionary')
                    value[key] = read(depth+1)
                    if depth == 0 and key == b'info':
                        span = (begin, pos)
            pos += 1
            return value
        end = raw.index(b':', pos)
        length = int(raw[pos:end]); pos = end+1
        if length < 0 or pos+length > len(raw):
            raise ValueError('string bounds')
        value = raw[pos:pos+length]; pos += length
        return value

    torrent = read()
    if pos != len(raw) or not span or hashlib.sha1(raw[slice(*span)]).hexdigest().upper() != expected:
        raise ValueError('infohash mismatch')
    info = torrent[b'info']
    sizes = [f[b'length'] for f in info[b'files']] if b'files' in info else [info[b'length']]
    if not sizes or any(type(x) is not int or x < 0 for x in sizes):
        raise ValueError('sizes')
    return sum(sizes)


def main():
    repo = os.environ['GITHUB_REPOSITORY']
    headers = {'Authorization': 'Bearer '+os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json', 'User-Agent': 'TorrentControl/1.7'}
    api = 'https://api.github.com/repos/'+repo+'/contents/'

    def get(path):
        try:
            with urllib.request.urlopen(urllib.request.Request(api+path+'?ref=main', headers=headers), timeout=30) as r:
                resource = json.load(r)
            if resource.get('encoding') == 'base64':
                decoded = base64.b64decode(resource['content'])
            else:
                with urllib.request.urlopen('https://raw.githubusercontent.com/'+repo+'/main/'+path, timeout=30) as r:
                    decoded = r.read(6_000_001)
                if len(decoded) > 6_000_000: raise ValueError('cache too large')
            return json.loads(decoded), resource['sha']
        except urllib.error.HTTPError as e:
            if e.code == 404: return None, None
            raise

    feed, _ = get('data/forum-252.json')
    age = dt.datetime.now(dt.timezone.utc)-dt.datetime.fromisoformat(feed['fetched_at'])
    if age.total_seconds() > 21600 or age.total_seconds() < -300:
        raise ValueError('feed stale')
    ns = {'a': 'http://www.w3.org/2005/Atom'}
    root = ET.fromstring(feed['xml'])
    if root.findtext('a:id', namespaces=ns) != 'tag:rto.feed,2000:/f/252':
        raise ValueError('forum')
    attempted = 0
    for entry in root.findall('a:entry', ns):
        title = entry.findtext('a:title', default='', namespaces=ns)
        if not eligible(title): continue
        infohash = None
        for link in entry.findall('a:link', ns):
            match = re.search(r'urn:btih:([0-9a-fA-F]{40})(?:&|$)', link.get('href', ''))
            if link.get('rel') == 'enclosure' and match:
                infohash = match[1].upper(); break
        if not infohash: continue
        path = 'data/metadata/'+infohash+'.json'
        saved, sha = get(path)
        if saved:
            if saved.get('status') == 'success': continue
            last = dt.datetime.fromisoformat(saved['fetched_at'])
            if (dt.datetime.now(dt.timezone.utc)-last).total_seconds() < 3600: continue
        attempted += 1
        result = {'schema':1, 'hash':infohash, 'status':'unavailable', 'fetched_at':dt.datetime.now(dt.timezone.utc).isoformat()}
        with tempfile.TemporaryDirectory() as folder:
            # Use only the known public tracker, never arbitrary URLs from the feed.
            magnet = 'magnet:?xt=urn:btih:'+infohash+'&tr=http%3A%2F%2Fbt.t-ru.org%2Fann%3Fmagnet'
            env = {k:v for k,v in os.environ.items() if k not in ('GH_TOKEN', 'GITHUB_TOKEN')}
            args = ['aria2c','--no-conf','--bt-metadata-only=true','--bt-save-metadata=true','--enable-dht=true','--enable-dht6=false','--bt-enable-lpd=false','--seed-time=0','--stop=120','--dir='+folder,'--dht-file-path='+folder+'/dht.dat',magnet]
            try:
                subprocess.run(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=140)
                files = list(pathlib.Path(folder).glob('*.torrent'))
                if len(files) == 1:
                    raw = files[0].read_bytes()
                    size = decode_metadata(raw, infohash)
                    result.update(status='success', total_bytes=size, torrent_base64=base64.b64encode(raw).decode('ascii'))
            except (subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
                result['status'] = 'unavailable'
        payload = {'message':'Cache public torrent metadata '+infohash, 'branch':'main', 'content':base64.b64encode((json.dumps(result)+'\n').encode()).decode()}
        if sha: payload['sha'] = sha
        req = urllib.request.Request(api+path, data=json.dumps(payload).encode(), headers={**headers,'Content-Type':'application/json'}, method='PUT')
        with urllib.request.urlopen(req, timeout=30) as r: json.load(r)
        print(infohash, result['status'])
        if attempted >= 3: break
    print('Metadata attempts:', attempted)


if __name__ == '__main__':
    main()
