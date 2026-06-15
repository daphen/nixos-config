"""Replace the template's top-level starship format with the sandbox
variant: two-row layout (cloud + langs + duration on top, path + prompt
char on bottom), no git info.

The proart prompt is two rows + lightning + git. The sandbox prompt
shares the same modules and palette but uses a cloud icon and drops the
git modules, since sandbox shells are project-local and the path alone
is enough orientation.
"""
import re
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

new_format = '''format = """
[](fg:prompt)\\
[   ](bg:prompt fg:fg_muted)\\
${env_var.SANDBOX_LABEL}\\
$nodejs\\
$golang\\
$rust\\
$fill\\
$cmd_duration\\
[](fg:prompt)\\
$line_break\\
$directory\\
$character"""
'''

# Strip any pre-existing top-level `format = """..."""` (the template
# may carry the proart-flavored version). TOML rejects duplicate keys.
content = re.sub(
    r'^format = """.*?"""\n?',
    '',
    content,
    count=1,
    flags=re.MULTILINE | re.DOTALL,
)

# Insert ours before the first [section] header so it stays top-level.
content = re.sub(r'^(\[)', new_format + '\n' + r'\1', content, count=1, flags=re.MULTILINE)

# Sandbox is single-project: `~`-rooted path > repo-root truncation.
content = re.sub(
    r'^(\[directory\]\n)',
    r'\1truncate_to_repo = false\n',
    content,
    count=1,
    flags=re.MULTILINE,
)

with open(path, 'w') as f:
    f.write(content)
