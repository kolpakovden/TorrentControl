"""Tests for scripts/refresh_feed.py and the feed age rule of scripts/cache_metadata.py.

No network: GitHub and the feed source are replaced by in-memory fakes.
"""
import copy
import datetime as dt
import json
import os
import sys
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scripts'))
import refresh_feed as rf  # noqa: E402
import cache_metadata as cm  # noqa: E402

UTC = dt.timezone.utc
NOW = dt.datetime(2026, 11, 12, 12, 0, tzinfo=UTC)


def entry(topic, updated, info_hash='A' * 40, title='Film WEB-DLRip Dub'):
    return {'topic': str(topic), 'updated': updated, 'hash': info_hash, 'title': title}


def atom(updated, entries, feed_id='tag:rto.feed,2000:/f/252'):
    parts = ['<?xml version="1.0" encoding="utf-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom">',
             '<title>Фильмы</title><id>%s</id><updated>%s</updated>' % (feed_id, updated.isoformat())]
    for e in entries:
        parts.append('<entry><title>%s</title><id>tag:rto.feed,2000:/t/%s</id><updated>%s</updated>'
                     '<link rel="enclosure" href="magnet:?xt=urn:btih:%s&amp;tr=x"/></entry>'
                     % (e['title'], e['topic'], e['updated'].isoformat(), e['hash']))
    parts.append('</feed>')
    return ''.join(parts).encode('utf-8')


def feed(generated, count=5, base=None, oldest_age_hours=300, newest_age_hours=1, lag_seconds=60):
    # Entry times are relative to `base` (same base = same content); the document time to `generated`.
    base = base or generated
    step = (oldest_age_hours - newest_age_hours) / max(1, count - 1)
    entries = [entry(1000 + i, base - dt.timedelta(hours=newest_age_hours + i * step), '%040X' % (i + 1)) for i in range(count)]
    return atom(generated - dt.timedelta(seconds=lag_seconds), entries)


class FakeGitHub:
    def __init__(self, files=None):
        self.files = {}
        self.counter = 0
        self.puts = []
        self.conflicts = 0
        self.on_conflict = None
        for path, obj in (files or {}).items():
            self.store(path, obj)

    def store(self, path, obj):
        self.counter += 1
        self.files[path] = (json.loads(json.dumps(obj)), 'sha%d' % self.counter)

    def get(self, path):
        if path not in self.files:
            return None, None
        obj, sha = self.files[path]
        return copy.deepcopy(obj), sha

    def put(self, path, obj, sha, message):
        if self.conflicts:
            self.conflicts -= 1
            if self.on_conflict:
                self.on_conflict(self)
            return 'conflict'
        current = self.files.get(path)
        if (current[1] if current else None) != sha:
            return 'conflict'
        self.store(path, obj)
        self.puts.append((path, message))
        return 'ok'


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


def run(github, raw=None, args=(), now=NOW, error=None, env=None):
    calls = []

    def fetch():
        calls.append(1)
        if error is not None:
            raise error
        return raw

    environment = {'GITHUB_EVENT_NAME': 'schedule', 'GITHUB_RUN_ID': '42'}
    environment.update(env or {})
    code = rf.run(list(args), github=github, fetch=fetch, now=Clock(now), env=environment)
    return code, len(calls)


def snapshot(github):
    return github.get(rf.SNAPSHOT_PATH)[0]


class NoNetwork(unittest.TestCase):
    def setUp(self):
        def blocked(*args, **kwargs):
            raise AssertionError('network access in tests')
        self._urlopen = urllib.request.urlopen
        urllib.request.urlopen = blocked

    def tearDown(self):
        urllib.request.urlopen = self._urlopen


class ValidateFeed(NoNetwork):
    def test_valid_feed(self):
        text, source_updated, entries = rf.validate_feed(feed(NOW), NOW)
        self.assertEqual(len(entries), 5)
        self.assertEqual(source_updated, NOW - dt.timedelta(seconds=60))
        self.assertIn('tag:rto.feed,2000:/f/252', text)

    def assertCode(self, raw, code, fetched_at=NOW):
        with self.assertRaises(rf.FeedError) as ctx:
            rf.validate_feed(raw, fetched_at)
        self.assertEqual(str(ctx.exception), code)

    def test_rejections(self):
        self.assertCode(b'<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "b">]><feed/>', 'UpstreamInvalid:Dtd')
        self.assertCode(b'<feed', 'UpstreamInvalid:Xml')
        self.assertCode(b'\xff\xfe', 'UpstreamInvalid:Encoding')
        self.assertCode(b'x' * 2_000_001, 'UpstreamInvalid:TooLarge')
        self.assertCode(atom(NOW, [entry(1, NOW)], feed_id='tag:rto.feed,2000:/f/1'), 'UpstreamInvalid:WrongForum')
        self.assertCode(atom(NOW, []), 'UpstreamInvalid:Empty')
        self.assertCode(atom(NOW, [entry('abc', NOW)]), 'UpstreamInvalid:Entry')
        self.assertCode(atom(NOW, [entry(1, NOW, title='')]), 'UpstreamInvalid:Entry')

    def test_old_source_is_never_published_as_fresh(self):
        # The Atom document says when it was generated; a cached copy older than 2 hours is rejected.
        self.assertCode(feed(NOW, lag_seconds=3 * 3600), 'UpstreamStale')
        self.assertCode(feed(NOW, lag_seconds=-15 * 60), 'UpstreamInvalid:FutureDate')
        rf.validate_feed(feed(NOW, lag_seconds=110 * 60), NOW)


class Publish(NoNetwork):
    def test_first_snapshot_is_compatible_with_clients(self):
        github = FakeGitHub()
        code, fetches = run(github, feed(NOW))
        self.assertEqual((code, fetches), (0, 1))
        s = snapshot(github)
        for key, value in {'schema': 1, 'forum': 252, 'source': rf.SOURCE, 'entry_count': 5, 'sequence': 1,
                           'coverage': 'first', 'trigger': 'refresh-feed:schedule', 'run_id': '42'}.items():
            self.assertEqual(s[key], value, key)
        self.assertEqual(dt.datetime.fromisoformat(s['fetched_at']), NOW)
        self.assertLessEqual(NOW - dt.datetime.fromisoformat(s['source_updated']), dt.timedelta(hours=2))
        self.assertIn('<entry>', s['xml'])
        self.assertEqual(len(s['content_sha256']), 64)

    def test_unchanged_and_fresh_is_not_republished(self):
        github = FakeGitHub()
        run(github, feed(NOW))
        code, _ = run(github, feed(NOW + dt.timedelta(minutes=10), base=NOW), now=NOW + dt.timedelta(minutes=10),
                      args=['--min-publish-interval', '25'])
        self.assertEqual(code, 0)
        self.assertEqual(len(github.puts), 1)

    def test_unchanged_but_ageing_snapshot_is_refreshed(self):
        github = FakeGitHub()
        run(github, feed(NOW))
        later = NOW + dt.timedelta(minutes=30)
        run(github, feed(later, base=NOW), now=later)
        s = snapshot(github)
        self.assertEqual(s['sequence'], 2)
        self.assertEqual(dt.datetime.fromisoformat(s['fetched_at']), later)

    def test_changed_content_is_published_even_if_fresh(self):
        github = FakeGitHub()
        run(github, feed(NOW))
        later = NOW + dt.timedelta(minutes=5)
        run(github, feed(later, count=6), now=later)
        self.assertEqual(snapshot(github)['sequence'], 2)
        self.assertEqual(snapshot(github)['entry_count'], 6)

    def test_backup_trigger_skips_fresh_snapshot_without_fetching(self):
        github = FakeGitHub()
        run(github, feed(NOW))
        later = NOW + dt.timedelta(minutes=20)
        code, fetches = run(github, feed(later, base=NOW), now=later, args=['--caller', 'cache-metadata', '--if-older-than', '40'])
        self.assertEqual((code, fetches), (0, 0))
        much_later = NOW + dt.timedelta(hours=3)
        code, fetches = run(github, feed(much_later, base=NOW), now=much_later, args=['--caller', 'cache-metadata', '--if-older-than', '40'])
        self.assertEqual((code, fetches), (0, 1))
        self.assertEqual(snapshot(github)['trigger'], 'cache-metadata:schedule')

    def test_gap_and_coverage_are_recorded(self):
        github = FakeGitHub()
        run(github, feed(NOW))
        after_gap = NOW + dt.timedelta(hours=11)
        run(github, feed(after_gap, count=8), now=after_gap)
        s = snapshot(github)
        self.assertEqual((s['coverage'], s['gap_hours']), ('contiguous', 11.0))
        self.assertEqual(dt.datetime.fromisoformat(s['previous_fetched_at']), NOW)
        # Longer than the feed window: topics updated in between may have left the 50-entry feed.
        after_long_gap = after_gap + dt.timedelta(days=20)
        run(github, feed(after_long_gap, oldest_age_hours=48), now=after_long_gap)
        self.assertEqual(snapshot(github)['coverage'], 'possible_gap')

    def test_never_replaces_a_newer_snapshot(self):
        github = FakeGitHub()
        run(github, feed(NOW))
        earlier = NOW - dt.timedelta(minutes=30)   # runner clock behind the published snapshot
        code, _ = run(github, feed(earlier, count=7), now=earlier)
        self.assertEqual(code, 0)
        self.assertEqual(dt.datetime.fromisoformat(snapshot(github)['fetched_at']), NOW)

    def test_conflict_with_newer_publication_is_superseded(self):
        github = FakeGitHub()
        run(github, feed(NOW))
        later = NOW + dt.timedelta(hours=1)

        def other_run_publishes(gh):
            s = snapshot(gh)
            s['fetched_at'] = (later + dt.timedelta(minutes=1)).isoformat()
            s['sequence'] = 7
            gh.store(rf.SNAPSHOT_PATH, s)
        github.conflicts, github.on_conflict = 1, other_run_publishes
        code, _ = run(github, feed(later, count=6), now=later)
        self.assertEqual(code, 0)
        self.assertEqual(snapshot(github)['sequence'], 7)

    def test_conflict_with_older_publication_is_retried(self):
        github = FakeGitHub()
        run(github, feed(NOW))
        later = NOW + dt.timedelta(hours=1)
        github.conflicts = 1
        code, _ = run(github, feed(later, count=6), now=later)
        self.assertEqual(code, 0)
        self.assertEqual(snapshot(github)['sequence'], 2)
        self.assertEqual(dt.datetime.fromisoformat(snapshot(github)['fetched_at']), later)


class Failures(NoNetwork):
    def test_failure_is_recorded_and_recovery_clears_it(self):
        github = FakeGitHub()
        run(github, feed(NOW))
        error = urllib.error.HTTPError(rf.SOURCE, 503, 'unavailable', {}, None)
        later = NOW + dt.timedelta(hours=1)
        code, fetches = run(github, error=error, now=later)
        self.assertEqual(code, 1)
        self.assertEqual(fetches, 3)   # retried before giving up
        status = github.get(rf.STATUS_PATH)[0]
        self.assertEqual((status['schema'], status['last_error'], status['consecutive_failures']), (1, 'UpstreamHTTP=503', 1))
        self.assertEqual(dt.datetime.fromisoformat(status['last_attempt_at']), later)
        self.assertEqual(dt.datetime.fromisoformat(snapshot(github)['fetched_at']), NOW)   # old snapshot untouched
        run(github, error=urllib.error.URLError('down'), now=later + dt.timedelta(hours=1))
        status = github.get(rf.STATUS_PATH)[0]
        self.assertEqual((status['last_error'], status['consecutive_failures']), ('UpstreamNetwork=URLError', 2))
        recovered = later + dt.timedelta(hours=2)
        self.assertEqual(run(github, feed(recovered), now=recovered)[0], 0)
        status = github.get(rf.STATUS_PATH)[0]
        self.assertEqual((status['last_error'], status['consecutive_failures']), ('', 0))
        self.assertEqual(dt.datetime.fromisoformat(status['last_success_at']), recovered)

    def test_stale_source_is_a_failure_not_a_fresh_snapshot(self):
        github = FakeGitHub()
        code, _ = run(github, feed(NOW, lag_seconds=4 * 3600))
        self.assertEqual(code, 1)
        self.assertIsNone(snapshot(github))
        self.assertEqual(github.get(rf.STATUS_PATH)[0]['last_error'], 'UpstreamStale')

    def test_error_codes_never_contain_urls_or_bodies(self):
        github = FakeGitHub()
        run(github, error=ValueError('https://secret.example/?token=abc body'))
        self.assertEqual(github.get(rf.STATUS_PATH)[0]['last_error'], 'Unexpected=ValueError')


class CacheFeedAge(NoNetwork):
    def test_cache_job_keeps_working_on_a_stale_but_genuine_feed(self):
        # The metadata cache only needs the hash list; a feed outage must not stop it (it used to fail).
        self.assertGreater(cm.feed_age_hours({'fetched_at': (NOW - dt.timedelta(hours=9)).isoformat()}, NOW), 6)
        with self.assertRaises(ValueError):
            cm.feed_age_hours({'fetched_at': (NOW - dt.timedelta(days=15)).isoformat()}, NOW)
        with self.assertRaises(ValueError):
            cm.feed_age_hours({'fetched_at': (NOW + dt.timedelta(minutes=10)).isoformat()}, NOW)


if __name__ == '__main__':
    unittest.main()
