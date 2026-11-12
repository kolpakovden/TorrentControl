"""Fetch the public RuTracker Atom feed of forum 252 and publish a validated snapshot.

GitHub creates only part of the scheduled runs (measured 2026-10-24..11-12: about 4 of 48 a day,
gaps up to 11 hours), so every workflow run is a chance to refresh: refresh-feed.yml calls this on
each slot, cache-metadata.yml calls it with --if-older-than as a backup trigger.

Guarantees kept here:
- the snapshot is published only after strict checks of the source, its own <updated> time and
  every entry, so an old document is never published as fresh;
- fetched_at never goes backwards and `sequence` grows by one per published snapshot;
- failures are recorded in data/feed-status.json with fixed codes (no URLs, bodies or tokens);
- the GitHub token is sent only to api.github.com, never to the feed server.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

SOURCE = 'https://feed.rutracker.cc/atom/f/252.atom'
FEED_ID = 'tag:rto.feed,2000:/f/252'
NS = {'a': 'http://www.w3.org/2005/Atom'}
SNAPSHOT_PATH = 'data/forum-252.json'
STATUS_PATH = 'data/feed-status.json'
MAX_BYTES = 2_000_000
# Observed lag between the feed's own <updated> and the download: at most 10 minutes.
MAX_SOURCE_LAG = dt.timedelta(hours=2)
MAX_FUTURE = dt.timedelta(minutes=5)
USER_AGENT = 'TorrentControl-feed-monitor/1.8'


class FeedError(Exception):
    """Failure with a fixed, loggable code."""


def utcnow():
    return dt.datetime.now(dt.timezone.utc)


def parse_time(text):
    value = dt.datetime.fromisoformat(str(text).replace('Z', '+00:00'))
    if value.tzinfo is None:
        raise ValueError('time without offset')
    return value


def validate_feed(raw, fetched_at):
    """Return (xml_text, source_updated, entries) or raise FeedError."""
    if len(raw) > MAX_BYTES:
        raise FeedError('UpstreamInvalid:TooLarge')
    try:
        text = raw.decode('utf-8-sig')
    except UnicodeDecodeError:
        raise FeedError('UpstreamInvalid:Encoding') from None
    upper = text.upper()
    if '<!DOCTYPE' in upper or '<!ENTITY' in upper:
        raise FeedError('UpstreamInvalid:Dtd')
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        raise FeedError('UpstreamInvalid:Xml') from None
    if root.findtext('a:id', namespaces=NS) != FEED_ID:
        raise FeedError('UpstreamInvalid:WrongForum')
    try:
        source_updated = parse_time(root.findtext('a:updated', default='', namespaces=NS))
    except ValueError:
        raise FeedError('UpstreamInvalid:Updated') from None
    if source_updated > fetched_at + MAX_FUTURE:
        raise FeedError('UpstreamInvalid:FutureDate')
    if source_updated < fetched_at - MAX_SOURCE_LAG:
        raise FeedError('UpstreamStale')
    entries = []
    for node in root.findall('a:entry', NS):
        match = re.search(r'/t/(\d+)$', node.findtext('a:id', default='', namespaces=NS))
        title = node.findtext('a:title', default='', namespaces=NS)
        if not match or not title.strip():
            raise FeedError('UpstreamInvalid:Entry')
        try:
            updated = parse_time(node.findtext('a:updated', default='', namespaces=NS))
        except ValueError:
            raise FeedError('UpstreamInvalid:EntryUpdated') from None
        links = sorted(link.get('href', '') for link in node.findall('a:link', NS) if link.get('rel') == 'enclosure')
        entries.append({'topic': match[1], 'title': title, 'updated': updated, 'links': links})
    if not entries:
        raise FeedError('UpstreamInvalid:Empty')
    return text, source_updated, entries


def content_digest(entries):
    """Digest of the entries only; the feed's own <updated> changes on every download."""
    canonical = [[e['topic'], e['title'], e['updated'].isoformat(), e['links']] for e in entries]
    return hashlib.sha256(json.dumps(canonical, ensure_ascii=False).encode('utf-8')).hexdigest()


def snapshot_time(snapshot):
    try:
        return parse_time(snapshot['fetched_at'])
    except (KeyError, TypeError, ValueError):
        return None


def coverage(previous, entries, fetched_at):
    """The source lists only the newest 50 entries: report whether this snapshot overlaps the previous one."""
    previous_at = snapshot_time(previous) if previous else None
    if previous_at is None:
        return {'coverage': 'first'}
    oldest = min(e['updated'] for e in entries)
    return {
        'coverage': 'contiguous' if oldest <= previous_at else 'possible_gap',
        'previous_fetched_at': previous_at.isoformat(),
        'gap_hours': round((fetched_at - previous_at).total_seconds() / 3600, 2),
        'oldest_entry_updated': oldest.isoformat(),
    }


def next_sequence(previous):
    try:
        return int(previous.get('sequence', 0)) + 1 if previous else 1
    except (TypeError, ValueError):
        return 1


def build_snapshot(previous, text, source_updated, entries, fetched_at, digest, trigger, run_id):
    snapshot = {
        # Fields read by TorrentControl 1.7 clients stay unchanged.
        'schema': 1, 'forum': 252, 'source': SOURCE, 'fetched_at': fetched_at.isoformat(),
        'entry_count': len(entries), 'xml': text,
        # 1.8 diagnostics.
        'sequence': next_sequence(previous), 'source_updated': source_updated.isoformat(),
        'content_sha256': digest, 'trigger': trigger, 'run_id': run_id,
    }
    snapshot.update(coverage(previous, entries, fetched_at))
    return snapshot


class GitHub:
    """Minimal contents API client; the token is sent only to api.github.com."""

    def __init__(self, repo, token, opener=None):
        self.api = 'https://api.github.com/repos/' + repo + '/contents/'
        self.raw = 'https://raw.githubusercontent.com/' + repo + '/main/'
        self.headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
                        'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': USER_AGENT}
        self.opener = opener or urllib.request.urlopen

    def get(self, path):
        try:
            with self.opener(urllib.request.Request(self.api + path + '?ref=main', headers=self.headers), timeout=30) as r:
                resource = json.load(r)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None, None
            raise FeedError('GitHubAPI=%d' % error.code) from None
        if resource.get('encoding') == 'base64' and resource.get('content'):
            body = base64.b64decode(resource['content'])
        else:   # files over 1 MB come without inline content
            with self.opener(urllib.request.Request(self.raw + path, headers={'User-Agent': USER_AGENT}), timeout=30) as r:
                body = r.read(6_000_001)
        return json.loads(body), resource['sha']

    def put(self, path, obj, sha, message):
        payload = {'message': message, 'branch': 'main',
                   'content': base64.b64encode((json.dumps(obj, ensure_ascii=False, indent=2) + '\n').encode('utf-8')).decode('ascii')}
        if sha:
            payload['sha'] = sha
        request = urllib.request.Request(self.api + path, data=json.dumps(payload).encode('utf-8'),
                                         headers=dict(self.headers, **{'Content-Type': 'application/json'}), method='PUT')
        try:
            with self.opener(request, timeout=30) as r:
                json.load(r)
            return 'ok'
        except urllib.error.HTTPError as error:
            if error.code in (409, 422):   # the file changed since it was read
                return 'conflict'
            raise FeedError('GitHubAPI=%d' % error.code) from None


def fetch_source(opener=None):
    opener = opener or urllib.request.urlopen
    request = urllib.request.Request(SOURCE, headers={'User-Agent': USER_AGENT})
    with opener(request, timeout=35) as response:
        if response.status != 200:
            raise FeedError('UpstreamHTTP=%d' % response.status)
        return response.read(MAX_BYTES + 1)


def error_code(error):
    if isinstance(error, FeedError):
        return str(error)
    if isinstance(error, urllib.error.HTTPError):
        return 'UpstreamHTTP=%d' % error.code
    if isinstance(error, (urllib.error.URLError, TimeoutError, OSError)):
        return 'UpstreamNetwork=' + type(error).__name__
    return 'Unexpected=' + type(error).__name__


def fetch_validated(fetch, now, attempts=3, sleep=time.sleep):
    last = None
    for attempt in range(attempts):
        try:
            raw = fetch()
            fetched_at = now()
            return (fetched_at,) + validate_feed(raw, fetched_at)
        except Exception as error:   # noqa: BLE001 - every failure is retried, then reported by code
            last = error
            print('Fetch attempt', attempt + 1, 'failed:', error_code(error))
            if attempt + 1 < attempts:
                sleep(5)
    raise last


def publish(github, snapshot, previous, sha, message):
    """Publish unless a newer snapshot is already there. Returns 'published' or 'superseded'."""
    mine = snapshot_time(snapshot)
    for _ in range(3):
        current_time = snapshot_time(previous) if previous else None
        if current_time is not None and current_time >= mine:
            return 'superseded'
        if github.put(SNAPSHOT_PATH, snapshot, sha, message) == 'ok':
            return 'published'
        previous, sha = github.get(SNAPSHOT_PATH)
        snapshot['sequence'] = next_sequence(previous)
    raise FeedError('GitHubConflict')


def record_status(github, now, error, trigger, run_id, snapshot_at=None):
    """Failure: write the code. Success after a failure: clear it. Never fatal."""
    try:
        status, sha = github.get(STATUS_PATH)
        if error is None and not (status and status.get('last_error')):
            return
        failures = 0
        if error is not None:
            failures = 1
            if status and status.get('last_error'):
                try:
                    failures = int(status.get('consecutive_failures', 0)) + 1
                except (TypeError, ValueError):
                    failures = 1
        new = {'schema': 1, 'last_attempt_at': now.isoformat(), 'last_error': error or '',
               'consecutive_failures': failures, 'trigger': trigger, 'run_id': run_id}
        if error is None:
            new['last_success_at'] = (snapshot_at or now).isoformat()
        elif status and status.get('last_success_at'):
            new['last_success_at'] = status['last_success_at']
        github.put(STATUS_PATH, new, sha, 'Record feed refresh ' + ('failure ' + error if error else 'recovery'))
    except Exception as status_error:   # noqa: BLE001 - diagnostics must not hide the real result
        print('Could not record feed status:', error_code(status_error))


def run(argv, github, fetch, now=utcnow, env=None, sleep=time.sleep):
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser()
    parser.add_argument('--caller', default='refresh-feed')
    parser.add_argument('--if-older-than', type=float, default=None, metavar='MINUTES',
                        help='backup mode: do nothing while the published snapshot is younger')
    parser.add_argument('--min-publish-interval', type=float, default=25, metavar='MINUTES',
                        help='an unchanged feed is republished only after this age')
    args = parser.parse_args(argv)
    trigger = args.caller + ':' + env.get('GITHUB_EVENT_NAME', 'manual')
    run_id = env.get('GITHUB_RUN_ID', '')
    try:
        previous, sha = github.get(SNAPSHOT_PATH)
    except Exception as error:   # noqa: BLE001
        print('FAILED:', error_code(error))
        return 1
    previous_at = snapshot_time(previous) if previous else None
    if args.if_older_than is not None and previous_at is not None:
        age = now() - previous_at
        if age < dt.timedelta(minutes=args.if_older_than):
            print('Skip: published snapshot is %.0f min old (limit %.0f).' % (age.total_seconds() / 60, args.if_older_than))
            return 0
    try:
        fetched_at, text, source_updated, entries = fetch_validated(fetch, now, sleep=sleep)
    except Exception as error:   # noqa: BLE001
        code = error_code(error)
        record_status(github, now(), code, trigger, run_id)
        print('FAILED:', code, '- the previous snapshot stays published unchanged.')
        return 1
    digest = content_digest(entries)
    if previous_at is not None and previous.get('content_sha256') == digest and \
            fetched_at - previous_at < dt.timedelta(minutes=args.min_publish_interval):
        print('Unchanged feed; published snapshot is fresh enough.')
        return 0
    snapshot = build_snapshot(previous, text, source_updated, entries, fetched_at, digest, trigger, run_id)
    try:
        result = publish(github, snapshot, previous, sha, 'Refresh public film feed snapshot')
    except Exception as error:   # noqa: BLE001
        code = error_code(error)
        record_status(github, now(), code, trigger, run_id)
        print('FAILED:', code)
        return 1
    print(result.capitalize() + ':', len(entries), 'entries; fetched_at', snapshot['fetched_at'],
          '; sequence', snapshot['sequence'], '; coverage', snapshot['coverage'], '; trigger', trigger)
    if result == 'published':
        record_status(github, fetched_at, None, trigger, run_id, fetched_at)
    return 0


def main():
    github = GitHub(os.environ['GITHUB_REPOSITORY'], os.environ['GH_TOKEN'])
    return run(sys.argv[1:], github=github, fetch=fetch_source)


if __name__ == '__main__':
    sys.exit(main())
