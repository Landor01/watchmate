#!/usr/bin/env python3
"""Download a curated TMDB library and artwork for offline simulator captures."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import shutil
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=Path('ScreenshotFixtures'))
    args = parser.parse_args()
    with (args.app / 'Info.plist').open('rb') as source:
        token = plistlib.load(source)['TMDBReadAccessToken']
    if not token or token.startswith('$('):
        parser.error('Build the app with a configured TMDB token first.')
    args.output.mkdir(parents=True, exist_ok=True)

    def get(path):
        request = urllib.request.Request(
            'https://api.themoviedb.org/3/' + path,
            headers={'Authorization': 'Bearer ' + token})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def artwork(path):
        if not path:
            return None
        filename = path.lstrip('/')
        destination = args.output / filename
        if not destination.exists():
            with urllib.request.urlopen('https://image.tmdb.org/t/p/w780' + path, timeout=30) as response:
                destination.write_bytes(response.read())
        return 'fixture:' + filename

    snapshot = {'fetchedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'source': 'https://www.themoviedb.org', 'shows': []}
    calendar_dates = []
    for index, (tmdb_id, season) in enumerate([(95396, 1), (125988, 1), (95480, 6),
                                              (66732, 1), (136315, 1), (119051, 1)]):
        details = get(f'tv/{tmdb_id}?language=en-GB')
        episodes = get(f'tv/{tmdb_id}/season/{season}?language=en-GB')['episodes']
        country = get(f'tv/{tmdb_id}/watch/providers')['results'].get('GB', {})
        providers = {p['provider_id']: {'id': p['provider_id'], 'name': p['provider_name']}
                     for kind in ['flatrate', 'free', 'ads'] for p in country.get(kind, [])}
        show = {'id': -(index + 1), 'tmdbID': tmdb_id, 'title': details['name'],
                'overview': details['overview'], 'posterPath': artwork(details['poster_path']),
                'providers': list(providers.values()), 'watchURL': country.get('link'), 'episodes': []}
        for episode in episodes:
            show['episodes'].append({
                'number': episode['episode_number'], 'season': episode['season_number'],
                'title': episode['name'], 'overview': episode['overview'],
                'airDate': episode['air_date'], 'runtime': episode['runtime'],
                'artwork': artwork(episode['still_path']),
                'watched': episode['episode_number'] <= 3 + index % 3})
        upcoming = details.get('next_episode_to_air')
        if upcoming and upcoming['season_number'] == season and upcoming.get('air_date'):
            calendar_dates.append(upcoming['air_date'])
        snapshot['shows'].append(show)
        print(f"Prepared {details['name']} — {len(episodes)} episodes", flush=True)
    snapshot['calendarDate'] = min(calendar_dates) if calendar_dates else max(
        e['airDate'] for show in snapshot['shows'] for e in show['episodes'] if e['airDate'])
    (args.output / 'library.json').write_text(json.dumps(snapshot, indent=2) + '\n')
    project = Path(__file__).resolve().parent.parent / 'WatchMate'
    shutil.copyfile(args.output / 'library.json', project / 'Support' / 'DemoLibrary.json')
    assets = project / 'Assets.xcassets' / 'DemoArtwork'
    assets.mkdir(parents=True, exist_ok=True)
    (assets / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}))
    paths = {show['posterPath'] for show in snapshot['shows']}
    paths.update(e['artwork'] for show in snapshot['shows'] for e in show['episodes'] if e['artwork'])
    for path in paths:
        source = args.output / path.removeprefix('fixture:')
        target = assets / ('demo-' + source.stem + '.imageset')
        target.mkdir(exist_ok=True)
        shutil.copyfile(source, target / source.name)
        (target / 'Contents.json').write_text(json.dumps({
            'images': [{'filename': source.name, 'idiom': 'universal'}],
            'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    print('Updated bundled demo library. Rebuild WatchMate before capturing screenshots.')


if __name__ == '__main__':
    main()
