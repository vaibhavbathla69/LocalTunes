"""Conservative visual-only fast path; unknown or core changes run all checks."""
import subprocess, os, json, urllib.request
try:
    changed = subprocess.check_output(['git','diff','--name-only','HEAD^','HEAD'],text=True).splitlines()
    visual = bool(changed)
    for path in changed:
        if path == 'project.yml':
            diff = subprocess.check_output(['git','diff','HEAD^','HEAD','--',path],text=True)
            lines = [line for line in diff.splitlines() if line.startswith(('+','-')) and not line.startswith(('+++','---'))]
            visual &= all('MARKETING_VERSION:' in line or 'CURRENT_PROJECT_VERSION:' in line for line in lines)
        elif not (path.startswith(('LocalTunes/Views/','LocalTunes/Resources/Assets.xcassets/','branding/')) or path == 'README.md'):
            visual = False
except subprocess.CalledProcessError:
    visual = False
# Do not let a visual commit hide unverified core changes in its parent.
if visual:
    try:
        parent = subprocess.check_output(['git','rev-parse','HEAD^'],text=True).strip()
        repo = os.environ['GITHUB_REPOSITORY']
        request = urllib.request.Request(f'https://api.github.com/repos/{repo}/actions/runs?head_sha={parent}&status=success', headers={'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN'], 'Accept': 'application/vnd.github+json'})
        with urllib.request.urlopen(request, timeout=20) as response:
            visual = any(run['name'] == 'Build iPhone IPA' and run['conclusion'] == 'success' for run in json.load(response)['workflow_runs'])
    except (KeyError, OSError, ValueError):
        visual = False
print('audio=' + ('false' if visual else 'true'))
