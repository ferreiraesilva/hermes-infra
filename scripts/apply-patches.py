#!/usr/bin/env python3
"""Apply unified diffs with fuzzy line-matching for version mismatches."""
import sys
import re
from pathlib import Path


def apply_patch(patch_file: str, working_dir: str) -> bool:
    """
    Apply a unified diff patch with fuzzy matching for line-number offsets.
    Returns True if all hunks applied successfully.
    """
    patch_path = Path(patch_file)
    if not patch_path.exists():
        print(f"❌ Patch not found: {patch_file}", file=sys.stderr)
        return False

    work_path = Path(working_dir)
    if not work_path.is_dir():
        print(f"❌ Working directory not found: {working_dir}", file=sys.stderr)
        return False

    patch_content = patch_path.read_text()

    # Parse unified diff format
    lines = patch_content.split('\n')
    i = 0
    all_ok = True

    while i < len(lines):
        # Look for hunk header: @@ -start,count +start,count @@
        if not lines[i].startswith('@@'):
            i += 1
            continue

        match = re.match(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', lines[i])
        if not match:
            i += 1
            continue

        old_start = int(match.group(1)) - 1  # Convert to 0-indexed
        old_count = int(match.group(2)) if match.group(2) else 1
        new_start = int(match.group(3)) - 1
        new_count = int(match.group(4)) if match.group(4) else 1

        # Parse the file path from earlier in the patch
        file_path_match = None
        for j in range(max(0, i - 50), i):
            if lines[j].startswith('--- ') or lines[j].startswith('+++ '):
                path_line = lines[j].split('\t')[0]  # Handle tabs in path
                path_line = path_line[4:] if path_line.startswith('+++ ') else path_line[4:]
                if path_line and not path_line.startswith('/dev/null'):
                    file_path_match = path_line
                    break

        if not file_path_match:
            i += 1
            continue

        file_to_patch = work_path / file_path_match
        if not file_to_patch.exists():
            print(f"⚠️  Skipping: {file_path_match} (not found)", file=sys.stderr)
            i += 1
            continue

        file_content = file_to_patch.read_text()
        file_lines = file_content.split('\n')

        # Extract hunk context and changes
        hunk_lines = []
        i += 1
        while i < len(lines) and not lines[i].startswith('@@'):
            if i < len(lines) and len(lines[i]) > 0:
                hunk_lines.append(lines[i])
            elif i < len(lines):
                hunk_lines.append('')  # Empty line
            i += 1

        # Split hunk into context, deletions, additions
        context_before = []
        deletions = []
        additions = []
        context_after = []

        for hunk_line in hunk_lines:
            if hunk_line.startswith(' '):
                if not deletions and not additions:
                    context_before.append(hunk_line[1:])
                else:
                    context_after.append(hunk_line[1:])
            elif hunk_line.startswith('-'):
                deletions.append(hunk_line[1:])
            elif hunk_line.startswith('+'):
                additions.append(hunk_line[1:])

        # Try to find and replace in file with fuzzy matching
        found = False
        for start_offset in range(len(file_lines)):
            # Check if context_before matches starting at start_offset
            before_match = True
            for j, ctx_line in enumerate(context_before):
                if start_offset + j >= len(file_lines):
                    before_match = False
                    break
                if file_lines[start_offset + j] != ctx_line:
                    before_match = False
                    break

            if not before_match:
                continue

            # Check if deletions match after context_before
            del_start = start_offset + len(context_before)
            del_match = True
            for j, del_line in enumerate(deletions):
                if del_start + j >= len(file_lines):
                    del_match = False
                    break
                if file_lines[del_start + j] != del_line:
                    del_match = False
                    break

            if not del_match:
                continue

            # Check if context_after matches after deletions
            after_start = del_start + len(deletions)
            after_match = True
            for j, ctx_line in enumerate(context_after):
                if after_start + j >= len(file_lines):
                    after_match = False
                    break
                if file_lines[after_start + j] != ctx_line:
                    after_match = False
                    break

            if not after_match:
                continue

            # Hunk matches! Apply the replacement
            new_lines = (
                file_lines[:start_offset + len(context_before)]
                + additions
                + file_lines[after_start:]
            )
            file_to_patch.write_text('\n'.join(new_lines) + '\n' if new_lines else '')
            print(f"✅ Applied hunk to {file_path_match} (offset: {start_offset - old_start})", file=sys.stderr)
            found = True
            break

        if not found:
            print(f"❌ Could not find hunk context in {file_path_match}", file=sys.stderr)
            all_ok = False

    return all_ok


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: apply-patches.py <patch-file> <working-dir>", file=sys.stderr)
        sys.exit(1)

    success = apply_patch(sys.argv[1], sys.argv[2])
    sys.exit(0 if success else 1)
